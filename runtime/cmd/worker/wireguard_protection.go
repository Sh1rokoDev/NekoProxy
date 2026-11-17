package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"time"
)

type wireGuardProtection struct {
	tun      string
	endpoint netip.AddrPort
	dns      []netip.Addr
}

// Resolve managed WireGuard peers before TUN changes the system resolver.
// A protected session pins its firewall exception to the same address.
func prepareWireGuardProtection(config []byte) ([]byte, *wireGuardProtection, error) {
	var configMap map[string]json.RawMessage
	if err := json.Unmarshal(config, &configMap); err != nil {
		// Let the engine handle malformed configurations.
		return config, nil, nil
	}
	var outbounds []struct {
		Type     string `json:"type"`
		Endpoint string `json:"endpoint"`
		Protect  bool   `json:"protect_windows"`
	}
	_ = json.Unmarshal(configMap["outbounds"], &outbounds)
	var tag string
	var protected bool
	for _, outbound := range outbounds {
		if outbound.Type == "neko-wireguard-route" {
			tag = outbound.Endpoint
			protected = outbound.Protect
			break
		}
	}
	if tag == "" {
		return config, nil, nil
	}
	var endpoints []map[string]json.RawMessage
	var inbounds []struct {
		Type      string         `json:"type"`
		Name      string         `json:"interface_name"`
		Address   []netip.Prefix `json:"address"`
		AutoRoute bool           `json:"auto_route"`
	}
	if json.Unmarshal(configMap["endpoints"], &endpoints) != nil {
		return nil, nil, errors.New("WireGuard protection: invalid tunnel configuration")
	}
	var policy *wireGuardProtection
	if protected {
		policy = new(wireGuardProtection)
		if err := json.Unmarshal(configMap["inbounds"], &inbounds); err != nil {
			return nil, nil, errors.New("WireGuard protection: invalid tunnel configuration")
		}
	}
	for _, inbound := range inbounds {
		if inbound.Type == "tun" && inbound.AutoRoute && inbound.Name != "" {
			policy.tun = inbound.Name
			// sing-box assigns the next host address as the virtual DNS target.
			for _, prefix := range inbound.Address {
				policy.dns = append(policy.dns, prefix.Addr().Next())
			}
			break
		}
	}
	if policy != nil && policy.tun == "" {
		return nil, nil, errors.New("WireGuard protection requires TUN auto-route")
	}
	for _, endpoint := range endpoints {
		var name string
		_ = json.Unmarshal(endpoint["tag"], &name)
		if name != tag {
			continue
		}
		var peers []map[string]json.RawMessage
		if json.Unmarshal(endpoint["peers"], &peers) != nil || len(peers) == 0 || (protected && len(peers) != 1) {
			return nil, nil, errors.New("WireGuard protection requires one peer")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		for _, peer := range peers {
			var host string
			var port uint16
			var allowed []netip.Prefix
			_ = json.Unmarshal(peer["address"], &host)
			_ = json.Unmarshal(peer["port"], &port)
			_ = json.Unmarshal(peer["allowed_ips"], &allowed)
			hasDefault := false
			for _, prefix := range allowed {
				hasDefault = hasDefault || prefix.Bits() == 0
			}
			if host == "" || port == 0 || (protected && !hasDefault) {
				return nil, nil, errors.New("WireGuard protection requires a peer address and a /0 route")
			}
			address, err := netip.ParseAddr(host)
			if err != nil {
				addresses, lookupErr := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
				if lookupErr != nil || len(addresses) == 0 {
					return nil, nil, errors.New("could not resolve the WireGuard peer before enabling protection")
				}
				address = addresses[0].Unmap()
			}
			if policy != nil {
				policy.endpoint = netip.AddrPortFrom(address.Unmap(), port)
			}
			peer["address"], _ = json.Marshal(address.String())
		}
		delete(endpoint, "domain_resolver")
		endpoint["peers"], _ = json.Marshal(peers)
		configMap["endpoints"], _ = json.Marshal(endpoints)
		encoded, err := json.Marshal(configMap)
		return encoded, policy, err
	}
	return nil, nil, errors.New("WireGuard protection: endpoint is missing")
}
