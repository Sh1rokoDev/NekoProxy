package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"unsafe"

	"github.com/tailscale/wf"
	"golang.org/x/sys/windows"
)

type wireGuardFirewall struct {
	session *wf.Session
	layer   wf.SublayerID
}

func installWireGuardProtection(policy *wireGuardProtection) (*wireGuardFirewall, error) {
	session, err := wf.New(&wf.Options{Name: "NekoProxy WireGuard", Dynamic: true})
	if err != nil {
		return nil, err
	}
	firewall := &wireGuardFirewall{session: session}
	if err = firewall.install(policy); err != nil {
		return nil, errors.Join(err, session.Close())
	}
	return firewall, nil
}

type firewallLayer struct {
	id      wf.LayerID
	ipv6    bool
	inbound bool
}

var wireGuardLayers = []firewallLayer{
	{wf.LayerALEAuthConnectV4, false, false}, {wf.LayerALEAuthRecvAcceptV4, false, true},
	{wf.LayerALEAuthConnectV6, true, false}, {wf.LayerALEAuthRecvAcceptV6, true, true},
}

func equal(field wf.FieldID, value any) *wf.Match {
	return &wf.Match{Field: field, Op: wf.MatchTypeEqual, Value: value}
}

func (f *wireGuardFirewall) rule(layer wf.LayerID, name string, weight uint64, action wf.Action, conditions ...*wf.Match) error {
	guid, err := windows.GenerateGUID()
	if err != nil {
		return err
	}
	return f.session.AddRule(&wf.Rule{ID: wf.RuleID(guid), Name: "NekoProxy " + name,
		Layer: layer, Sublayer: f.layer, Weight: weight, Action: action, Conditions: conditions})
}

func (f *wireGuardFirewall) install(policy *wireGuardProtection) error {
	guid, err := windows.GenerateGUID()
	if err != nil {
		return err
	}
	f.layer = wf.SublayerID(guid)
	if err = f.session.AddSublayer(&wf.Sublayer{ID: f.layer, Name: "NekoProxy WireGuard", Weight: 65535}); err != nil {
		return err
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	app, err := wf.AppID(executable)
	if err != nil {
		return err
	}
	for _, layer := range wireGuardLayers {
		if layer.ipv6 == policy.endpoint.Addr().Is6() {
			if err = f.rule(layer.id, "WireGuard transport", 100, wf.ActionPermit,
				equal(wf.FieldALEAppID, app), equal(wf.FieldIPProtocol, uint8(17)),
				equal(wf.FieldIPRemoteAddress, policy.endpoint.Addr()), equal(wf.FieldIPRemotePort, policy.endpoint.Port())); err != nil {
				return err
			}
		}
		if err = f.rule(layer.id, "loopback", 90, wf.ActionPermit, &wf.Match{Field: wf.FieldFlags, Op: wf.MatchTypeFlagsAllSet, Value: uint32(1)}); err != nil {
			return err
		}
		localPort, remotePort := uint16(68), uint16(67)
		if layer.ipv6 {
			localPort, remotePort = 546, 547
		}
		if err = f.rule(layer.id, "DHCP", 80, wf.ActionPermit, equal(wf.FieldIPProtocol, uint8(17)),
			equal(wf.FieldIPLocalPort, localPort), equal(wf.FieldIPRemotePort, remotePort)); err != nil {
			return err
		}
		if layer.ipv6 {
			// At the ALE layers ICMP type and code use the local and remote port fields.
			for _, kind := range []uint16{133, 134, 135, 136} {
				if err = f.rule(layer.id, "NDP", 80, wf.ActionPermit, equal(wf.FieldIPProtocol, uint8(58)),
					equal(wf.FieldIPLocalPort, kind), equal(wf.FieldIPRemotePort, uint16(0))); err != nil {
					return err
				}
			}
		}
		if err = f.rule(layer.id, "block traffic outside tunnel", 1, wf.ActionBlock); err != nil {
			return err
		}
	}
	return nil
}

func (f *wireGuardFirewall) allowTun(policy *wireGuardProtection) error {
	iface, err := net.InterfaceByName(policy.tun)
	if err != nil {
		return err
	}
	var luid uint64
	convert := windows.NewLazySystemDLL("iphlpapi.dll").NewProc("ConvertInterfaceIndexToLuid")
	result, _, _ := convert.Call(uintptr(iface.Index), uintptr(unsafe.Pointer(&luid)))
	if result != 0 {
		return fmt.Errorf("resolve tunnel LUID: %w", windows.Errno(result))
	}
	if luid == 0 {
		return errors.New("invalid tunnel interface LUID")
	}
	for _, layer := range wireGuardLayers {
		ifaceMatch := equal(wf.FieldIPLocalInterface, luid)
		if !layer.inbound {
			for _, address := range policy.dns {
				if address.Is6() != layer.ipv6 || !address.IsValid() {
					continue
				}
				if err = f.rule(layer.id, "virtual DNS", 65, wf.ActionPermit, ifaceMatch,
					equal(wf.FieldIPRemotePort, uint16(53)), equal(wf.FieldIPRemoteAddress, address)); err != nil {
					return err
				}
			}
			for _, protocol := range []uint8{6, 17} {
				if err = f.rule(layer.id, "restrict DNS to virtual resolver", 60, wf.ActionBlock, ifaceMatch,
					equal(wf.FieldIPProtocol, protocol), equal(wf.FieldIPRemotePort, uint16(53))); err != nil {
					return err
				}
			}
		}
		if err = f.rule(layer.id, "TUN traffic", 50, wf.ActionPermit, ifaceMatch); err != nil {
			return err
		}
	}
	return nil
}

func (f *wireGuardFirewall) close() error { return f.session.Close() }
