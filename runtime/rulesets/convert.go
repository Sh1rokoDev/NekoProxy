package rulesets

import (
	"fmt"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/sagernet/sing-box/common/srs"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	"google.golang.org/protobuf/encoding/protowire"
)

const MaxDatabaseSize = 64 << 20

var categoryName = regexp.MustCompile(`^[a-z0-9_!][a-z0-9_!.-]{0,126}$`)

var (
	listFields      = map[protowire.Number]protowire.Type{1: protowire.BytesType}
	categoryFields  = map[protowire.Number]protowire.Type{1: protowire.BytesType, 2: protowire.BytesType}
	cidrFields      = map[protowire.Number]protowire.Type{1: protowire.BytesType, 2: protowire.VarintType}
	domainFields    = map[protowire.Number]protowire.Type{1: protowire.VarintType, 2: protowire.BytesType, 3: protowire.BytesType}
	attributeFields = map[protowire.Number]protowire.Type{1: protowire.BytesType}
)

// Convert reads the official v2fly release database and writes one sing-box
// binary rule-set per category and per GeoSite category/attribute pair.
func Convert(kind, input, output string) error {
	if kind != "geosite" && kind != "geoip" {
		return fmt.Errorf("unknown database kind %q", kind)
	}
	file, err := os.Open(input)
	if err != nil {
		return err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, MaxDatabaseSize+1))
	if err != nil {
		return err
	}
	if len(data) > MaxDatabaseSize {
		return fmt.Errorf("%s database exceeds 64 MiB", kind)
	}

	written := make(map[string]bool)
	err = visitFields(data, listFields, func(field protoField) error {
		var name string
		var entries [][]byte
		err := visitFields(field.bytes, categoryFields, func(field protoField) error {
			switch field.number {
			case 1:
				name = strings.ToLower(string(field.bytes))
			case 2:
				entries = append(entries, field.bytes)
			}
			return nil
		})
		if err != nil {
			return err
		}
		if !categoryName.MatchString(name) || written[name] {
			return fmt.Errorf("invalid or duplicate %s category %q", kind, name)
		}

		write := func(suffix string, rule option.DefaultHeadlessRule) error {
			if !rule.IsValid() {
				return fmt.Errorf("empty category %s-%s", kind, suffix)
			}
			return writeSRS(filepath.Join(output, kind+"-"+suffix+".srs"), rule)
		}
		if kind == "geosite" {
			err = writeSite(name, entries, write)
		} else {
			var rule option.DefaultHeadlessRule
			for _, entry := range entries {
				prefix, err := decodePrefix(entry)
				if err != nil {
					return fmt.Errorf("%s-%s: %w", kind, name, err)
				}
				rule.IPCIDR = append(rule.IPCIDR, prefix.String())
			}
			err = write(name, rule)
		}
		if err != nil {
			return fmt.Errorf("%s-%s: %w", kind, name, err)
		}
		written[name] = true
		return nil
	})
	if err != nil {
		return err
	}
	if !written["cn"] || (kind == "geosite" && !written["category-ads-all"]) {
		return fmt.Errorf("%s database is missing default routing categories", kind)
	}
	return nil
}

// Field numbers follow v2ray-core/app/router/routercommon/common.proto and
// geoip/plugin/v2ray/geoip.proto. Unknown fields are skipped for compatibility.
type protoField struct {
	number protowire.Number
	bytes  []byte
	value  uint64
}

func visitFields(data []byte, schema map[protowire.Number]protowire.Type, visit func(protoField) error) error {
	for len(data) > 0 {
		number, kind, tagLen := protowire.ConsumeTag(data)
		if tagLen < 0 {
			return protowire.ParseError(tagLen)
		}
		data = data[tagLen:]
		expected, known := schema[number]
		if known && kind != expected {
			return fmt.Errorf("invalid protobuf type for field %d", number)
		}
		field := protoField{number: number}
		var length int
		switch kind {
		case protowire.BytesType:
			field.bytes, length = protowire.ConsumeBytes(data)
		case protowire.VarintType:
			field.value, length = protowire.ConsumeVarint(data)
		default:
			// Neither official schema uses groups.
			if kind != protowire.Fixed32Type && kind != protowire.Fixed64Type {
				return fmt.Errorf("unsupported protobuf wire type %d", kind)
			}
			length = protowire.ConsumeFieldValue(number, kind, data)
		}
		if length < 0 {
			return protowire.ParseError(length)
		}
		if known {
			if err := visit(field); err != nil {
				return err
			}
		}
		data = data[length:]
	}
	return nil
}

func decodePrefix(data []byte) (netip.Prefix, error) {
	var ip []byte
	var length uint64
	err := visitFields(data, cidrFields, func(field protoField) error {
		switch field.number {
		case 1:
			ip = field.bytes
		case 2:
			length = field.value
		}
		return nil
	})
	if err != nil {
		return netip.Prefix{}, err
	}
	address, ok := netip.AddrFromSlice(ip)
	if !ok || length > uint64(address.BitLen()) {
		return netip.Prefix{}, fmt.Errorf("invalid CIDR")
	}
	return netip.PrefixFrom(address, int(length)).Masked(), nil
}

func writeSite(name string, entries [][]byte, write func(string, option.DefaultHeadlessRule) error) error {
	var all option.DefaultHeadlessRule
	filtered := make(map[string]*option.DefaultHeadlessRule)
	for _, entry := range entries {
		var kind uint64
		var value string
		var attributes []string
		err := visitFields(entry, domainFields, func(field protoField) error {
			switch field.number {
			case 1:
				kind = field.value
			case 2:
				value = string(field.bytes)
			case 3:
				return visitFields(field.bytes, attributeFields, func(field protoField) error {
					attr := strings.ToLower(string(field.bytes))
					if !categoryName.MatchString(attr) {
						return fmt.Errorf("invalid GeoSite attribute %q", attr)
					}
					attributes = append(attributes, attr)
					return nil
				})
			}
			return nil
		})
		if err != nil {
			return err
		}
		if value == "" || !utf8.ValidString(value) || kind > 3 {
			return fmt.Errorf("invalid domain entry")
		}
		if kind == 1 {
			if _, err := regexp.Compile(value); err != nil {
				return err
			}
		}
		addDomain(&all, kind, value)
		for _, attr := range attributes {
			if filtered[attr] == nil {
				filtered[attr] = new(option.DefaultHeadlessRule)
			}
			addDomain(filtered[attr], kind, value)
		}
	}
	if err := write(name, all); err != nil {
		return err
	}
	for attr, rule := range filtered {
		if err := write(name+"@"+attr, *rule); err != nil {
			return err
		}
	}
	return nil
}

func addDomain(rule *option.DefaultHeadlessRule, kind uint64, value string) {
	switch kind {
	case 0: // Plain
		rule.DomainKeyword = append(rule.DomainKeyword, value)
	case 1: // Regex
		rule.DomainRegex = append(rule.DomainRegex, value)
	case 2: // RootDomain matches the root itself and its subdomains.
		rule.DomainSuffix = append(rule.DomainSuffix, value)
	case 3: // Full
		rule.Domain = append(rule.Domain, value)
	}
}

func writeSRS(path string, rule option.DefaultHeadlessRule) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	ruleSet := option.PlainRuleSet{
		Rules: []option.HeadlessRule{{Type: C.RuleTypeDefault, DefaultOptions: rule}},
	}
	if err := srs.Write(file, ruleSet, C.RuleSetVersionCurrent); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}
