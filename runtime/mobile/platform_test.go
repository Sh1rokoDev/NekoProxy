package mobile

import (
	"testing"

	"github.com/sagernet/sing-box/adapter"
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
