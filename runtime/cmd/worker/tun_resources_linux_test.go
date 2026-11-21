package main

import (
	"strings"
	"testing"

	"github.com/sagernet/netlink/nl"
	"golang.org/x/sys/unix"
)

const managedTunJSON = `{
	"inbounds": [{"type":"tun","interface_name":"nekoproxy0",
		"address":["172.19.0.1/30","fdfe:dcba:9876::1/126"],
		"dns_mode":"hijack","iproute2_table_index":20771,
		"iproute2_rule_index":19771,"auto_route":true,"strict_route":true}],
	"route":{"auto_detect_interface":true}
}`

func TestReadManagedTun(t *testing.T) {
	spec, err := readManagedTun([]byte(managedTunJSON))
	if err != nil {
		t.Fatal(err)
	}
	if !spec.AutoRoute || !spec.StrictRoute || !spec.IPv6 {
		t.Fatalf("unexpected TUN options: %+v", spec)
	}
	for _, change := range []struct{ name, old, new string }{
		{"different route table", "20771", "254"},
		{"unexpected interface", "nekoproxy0", "eth0"},
		{"disable route loop protection", "auto_detect_interface\":true", "auto_detect_interface\":false"},
		{"redirect", "\"auto_route\":true", "\"auto_route\":true,\"auto_redirect\":true"},
		{"network namespace", "\"auto_route\":true", "\"auto_route\":true,\"netns\":\"other\""},
	} {
		t.Run(change.name, func(t *testing.T) {
			config := strings.Replace(managedTunJSON, change.old, change.new, 1)
			if _, err := readManagedTun([]byte(config)); err == nil {
				t.Fatal("expected managed TUN validation to reject the config")
			}
		})
	}
}

func TestParseNewKernelDestinationPortMask(t *testing.T) {
	header := nl.NewRtMsg()
	header.Family = unix.AF_INET
	header.Type = unix.FR_ACT_TO_TBL
	header.Table = unix.RT_TABLE_MAIN
	for _, tc := range []struct {
		mask      uint16
		supported bool
	}{{0xffff, true}, {0xff00, false}} {
		value := make([]byte, 2)
		nl.NativeEndian().PutUint16(value, tc.mask)
		message := append(header.Serialize(), nl.NewRtAttr(fibDestinationPortMask, value).Serialize()...)
		if _, supported, err := parseTunRule(message); err != nil || supported != tc.supported {
			t.Fatalf("mask %#x: supported = %v, error = %v", tc.mask, supported, err)
		}
	}
}
