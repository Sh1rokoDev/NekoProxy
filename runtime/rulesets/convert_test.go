package rulesets

import (
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/sagernet/sing-box/common/srs"
	"github.com/sagernet/sing-box/option"
	"google.golang.org/protobuf/encoding/protowire"
)

func TestConvertGeoSite(t *testing.T) {
	attr := bytesField(nil, 1, []byte("ads"))
	exact := varintField(nil, 1, 3)
	exact = bytesField(exact, 2, []byte("exact.example"))
	exact = bytesField(exact, 3, attr)
	root := bytesField(varintField(nil, 1, 2), 2, []byte("root.example"))
	regex := bytesField(varintField(nil, 1, 1), 2, []byte(`^re[0-9]+\.example$`))
	keyword := bytesField(nil, 2, []byte("keyword"))
	data := category(nil, "CN", exact, root, regex, keyword)
	data = category(data, "CATEGORY-ADS-ALL", exact)
	data = category(data, "CUSTOM", root)
	output := convertFixture(t, "geosite", data)

	rule := readRule(t, output, "geosite-cn.srs")
	if !rule.DomainMatcher.Match("exact.example") ||
		rule.DomainMatcher.Match("sub.exact.example") ||
		!rule.DomainMatcher.Match("root.example") ||
		!rule.DomainMatcher.Match("sub.root.example") ||
		rule.DomainMatcher.Match("notroot.example") ||
		!slices.Equal(rule.DomainRegex, []string{`^re[0-9]+\.example$`}) ||
		!slices.Equal(rule.DomainKeyword, []string{"keyword"}) {
		t.Fatalf("GeoSite matching types were not preserved: %+v", rule)
	}
	ads := readRule(t, output, "geosite-cn@ads.srs")
	if !ads.DomainMatcher.Match("exact.example") || ads.DomainMatcher.Match("root.example") {
		t.Fatal("attribute rule must contain only tagged domains")
	}
	readRule(t, output, "geosite-custom.srs")
}

func TestConvertGeoIP(t *testing.T) {
	v4 := varintField(bytesField(nil, 1, netip.MustParseAddr("203.0.113.0").AsSlice()), 2, 24)
	v6 := varintField(bytesField(nil, 1, netip.MustParseAddr("2001:db8::").AsSlice()), 2, 32)
	output := convertFixture(t, "geoip", category(category(nil, "CN", v4), "CUSTOM", v4, v6))

	rule := readRule(t, output, "geoip-custom.srs")
	if !rule.IPSet.Contains(netip.MustParseAddr("203.0.113.25")) ||
		!rule.IPSet.Contains(netip.MustParseAddr("2001:db8::1")) ||
		rule.IPSet.Contains(netip.MustParseAddr("203.0.114.0")) {
		t.Fatal("converted SRS does not preserve IPv4 and IPv6 prefixes")
	}
}

func TestRejectInvalidCIDR(t *testing.T) {
	ip := bytesField(nil, 1, []byte{203, 0, 113, 0})
	for _, invalid := range [][]byte{
		varintField(slices.Clone(ip), 2, 33),
		bytesField(slices.Clone(ip), 2, []byte{24}),
	} {
		if _, err := decodePrefix(invalid); err == nil {
			t.Fatal("invalid CIDR accepted")
		}
	}
}

func convertFixture(t *testing.T, kind string, data []byte) string {
	t.Helper()
	output := t.TempDir()
	input := filepath.Join(output, "source.dat")
	if err := os.WriteFile(input, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := Convert(kind, input, output); err != nil {
		t.Fatal(err)
	}
	return output
}

func readRule(t *testing.T, directory, name string) option.DefaultHeadlessRule {
	t.Helper()
	file, err := os.Open(filepath.Join(directory, name))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	rules, err := srs.Read(file, false)
	if err != nil {
		t.Fatal(err)
	}
	return rules.Options.Rules[0].DefaultOptions
}

func category(data []byte, name string, entries ...[]byte) []byte {
	entry := bytesField(nil, 1, []byte(name))
	for _, item := range entries {
		entry = bytesField(entry, 2, item)
	}
	return bytesField(data, 1, entry)
}

func bytesField(data []byte, number protowire.Number, value []byte) []byte {
	return protowire.AppendBytes(protowire.AppendTag(data, number, protowire.BytesType), value)
}

func varintField(data []byte, number protowire.Number, value uint64) []byte {
	return protowire.AppendVarint(protowire.AppendTag(data, number, protowire.VarintType), value)
}
