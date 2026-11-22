package mobile

import (
	"encoding/json"
	"net/netip"
	"slices"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/control"
)

func TestAndroidTunSettingsExcludeLANAndKeepVirtualDNS(t *testing.T) {
	prefix := netip.MustParsePrefix
	options := &tun.Options{
		AutoRoute:                true,
		MTU:                      1500,
		Inet4Address:             []netip.Prefix{prefix("172.19.0.1/30")},
		Inet6Address:             []netip.Prefix{prefix("fdfe:dcba:9876::1/126")},
		Inet4RouteExcludeAddress: []netip.Prefix{prefix("172.16.0.0/12")},
		Inet6RouteExcludeAddress: []netip.Prefix{prefix("fc00::/7")},
	}
	check := func() (routes []netip.Prefix, dns []netip.Addr) {
		t.Helper()
		settings, err := androidTunSettings(options)
		if err != nil {
			t.Fatal(err)
		}
		var plan struct {
			Routes []netip.Prefix
			DNS    []netip.Addr
		}
		if err := json.Unmarshal([]byte(settings), &plan); err != nil {
			t.Fatal(err)
		}
		return plan.Routes, plan.DNS
	}
	routes, dns := check()
	hasRoute := func(address string) bool {
		return slices.ContainsFunc(routes, func(route netip.Prefix) bool {
			return route.Contains(netip.MustParseAddr(address))
		})
	}
	if hasRoute("172.16.1.1") || hasRoute("fc00::1") ||
		!hasRoute("192.0.2.1") || !hasRoute("2001:db8::1") {
		t.Fatalf("unexpected LAN or public route coverage: %v", routes)
	}
	for _, address := range []string{"172.19.0.2", "fdfe:dcba:9876::2"} {
		if !slices.Contains(dns, netip.MustParseAddr(address)) || !hasRoute(address) {
			t.Fatalf("virtual DNS is missing: %s", address)
		}
	}
	options.Inet4RouteExcludeAddress = []netip.Prefix{prefix("0.0.0.0/0")}
	options.Inet6RouteExcludeAddress = []netip.Prefix{prefix("::/0")}
	routes, _ = check()
	if len(routes) != 2 || hasRoute("192.0.2.1") || hasRoute("2001:db8::1") {
		t.Fatalf("an entirely excluded family recovered a default route: %v", routes)
	}
	options.AutoRoute = false
	routes, _ = check()
	if len(routes) != 0 {
		t.Fatalf("auto_route=false installed routes: %v", routes)
	}
}

type fakeOwnerFinder struct {
	result string
	err    error
}

func (f fakeOwnerFinder) FindOwner(int32, string, int32, string, int32) (string, error) {
	return f.result, f.err
}

func TestFindConnectionOwnerDecodesPackages(t *testing.T) {
	platform := &androidPlatform{
		finder: fakeOwnerFinder{
			result: `{"processId":10123,"userId":10123,"processPath":"","packageNames":["com.example.app","com.example.app:remote"]}`,
		},
	}
	owner, err := platform.FindConnectionOwner(&adapter.FindConnectionOwnerRequest{
		IpProtocol:         6,
		SourceAddress:      "10.0.0.2",
		SourcePort:         12345,
		DestinationAddress: "1.1.1.1",
		DestinationPort:    443,
	})
	if err != nil {
		t.Fatal(err)
	}
	if owner.ProcessID != 10123 || owner.UserId != 10123 {
		t.Fatalf("unexpected owner ids: %+v", owner)
	}
	if len(owner.AndroidPackageNames) != 2 || owner.AndroidPackageNames[0] != "com.example.app" {
		t.Fatalf("unexpected packages: %+v", owner.AndroidPackageNames)
	}
}

func TestFindConnectionOwnerRejectsEmptyAndInvalidResults(t *testing.T) {
	for name, finder := range map[string]fakeOwnerFinder{
		"empty":   {result: ""},
		"invalid": {result: "not-json"},
		"missing": {result: `{"processId":0,"packageNames":[]}`},
	} {
		platform := &androidPlatform{finder: finder}
		if _, err := platform.FindConnectionOwner(&adapter.FindConnectionOwnerRequest{}); err == nil {
			t.Fatalf("%s result should fail", name)
		}
	}
}

func TestFindConnectionOwnerWithoutFinder(t *testing.T) {
	platform := &androidPlatform{}
	if platform.UsePlatformConnectionOwnerFinder() {
		t.Fatal("finder should be disabled without a host implementation")
	}
	if _, err := platform.FindConnectionOwner(&adapter.FindConnectionOwnerRequest{}); err == nil {
		t.Fatal("expected an error without a finder")
	}
}

func TestDefaultInterfaceUpdates(t *testing.T) {
	engine := NewEngine(nil, nil)
	engine.UpdateDefaultInterface("wlan0", 3)
	monitor := engine.platform.CreateDefaultInterfaceMonitor(nil)
	if iface := monitor.DefaultInterface(); iface == nil || iface.Name != "wlan0" || iface.Index != 3 {
		t.Fatalf("initial default interface = %+v", iface)
	}

	var updates []*control.Interface
	registration := monitor.RegisterCallback(func(iface *control.Interface, _ int) {
		if current := monitor.DefaultInterface(); iface != current {
			t.Fatalf("callback interface = %+v, current = %+v", iface, current)
		}
		updates = append(updates, iface)
	})
	engine.UpdateDefaultInterface("", 0)
	engine.UpdateDefaultInterface("rmnet0", 5)
	monitor.UnregisterCallback(registration)
	engine.UpdateDefaultInterface("wlan0", 3)
	if len(updates) != 2 || updates[0] != nil || updates[1] == nil || updates[1].Index != 5 {
		t.Fatalf("unexpected updates: %+v", updates)
	}
}
