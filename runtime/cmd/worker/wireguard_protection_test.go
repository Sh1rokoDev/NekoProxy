package main

import (
	"net/netip"
	"testing"
)

func TestPrepareWireGuardProtection(t *testing.T) {
	config := []byte(`{
		"inbounds":[{"type":"tun","interface_name":"NekoProxy","auto_route":true,"address":["172.19.0.1/30"]}],
		"outbounds":[{"type":"neko-wireguard-route","endpoint":"wg","protect_windows":true}],
		"endpoints":[{"type":"wireguard","tag":"wg","system":false,"peers":[{"address":"192.0.2.1","port":53,"allowed_ips":["0.0.0.0/0"]}]}]
	}`)
	_, policy, err := prepareWireGuardProtection(config)
	if err != nil || policy == nil {
		t.Fatalf("expected protection policy: %v", err)
	}
	if policy.endpoint != netip.MustParseAddrPort("192.0.2.1:53") ||
		policy.tun != "NekoProxy" || len(policy.dns) != 1 ||
		policy.dns[0] != netip.MustParseAddr("172.19.0.2") {
		t.Fatalf("incorrect policy: %+v", policy)
	}
}

func TestProtectionFailsWithoutTun(t *testing.T) {
	config := []byte(`{"inbounds":[],"outbounds":[{"type":"neko-wireguard-route","endpoint":"wg","protect_windows":true}],"endpoints":[]}`)
	if _, policy, err := prepareWireGuardProtection(config); policy != nil || err == nil {
		t.Fatalf("expected failure without TUN: %+v, %v", policy, err)
	}
}
