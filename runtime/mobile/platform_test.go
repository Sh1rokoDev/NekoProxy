package mobile

import (
	"testing"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing/common/control"
)

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
