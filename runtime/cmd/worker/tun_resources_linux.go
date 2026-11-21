package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"reflect"
	"slices"

	"github.com/sagernet/netlink"
	"github.com/sagernet/netlink/nl"
	"golang.org/x/sys/unix"
)

// Shared with CompileTarget.linux. sing-tun owns eleven consecutive priorities.
const (
	tunInterface      = "nekoproxy0"
	tunTable          = 20771
	tunPriority       = 19771
	tunLastPriority   = tunPriority + 10
	tunIPv4           = "172.19.0.1/30"
	tunIPv6           = "fdfe:dcba:9876::1/126"
	tunJournalVersion = 1
	// Linux UAPI FRA_DPORT_MASK. x/sys predates this attribute.
	fibDestinationPortMask = 29
)

type managedTun struct {
	Version     int
	AutoRoute   bool
	StrictRoute bool
	IPv6        bool
	Namespace   uint64
}

func readManagedTun(data []byte) (managedTun, error) {
	var config struct {
		Inbounds  []json.RawMessage
		Endpoints []struct {
			Type   string
			System bool
		}
		Services []json.RawMessage
		Route    struct {
			AutoDetectInterface bool `json:"auto_detect_interface"`
		}
	}
	if err := json.Unmarshal(data, &config); err != nil {
		return managedTun{}, errors.New("Linux TUN 配置无效")
	}
	if !config.Route.AutoDetectInterface {
		return managedTun{}, errors.New("Linux TUN 需要启用 route.auto_detect_interface")
	}
	if len(config.Services) != 0 {
		return managedTun{}, errors.New("Linux TUN 无法同时启用高级配置中的核心服务")
	}
	for _, endpoint := range config.Endpoints {
		if endpoint.Type != "wireguard" || endpoint.System {
			return managedTun{}, errors.New("Linux TUN 只允许使用用户空间 WireGuard 端点")
		}
	}
	spec := managedTun{Version: tunJournalVersion}
	tunCount := 0
	for _, raw := range config.Inbounds {
		var item struct {
			Type         string
			Name         string   `json:"interface_name"`
			Addresses    []string `json:"address"`
			AutoRoute    bool     `json:"auto_route"`
			AutoRedirect bool     `json:"auto_redirect"`
			StrictRoute  bool     `json:"strict_route"`
			DNSMode      string   `json:"dns_mode"`
			Table        int      `json:"iproute2_table_index"`
			Priority     int      `json:"iproute2_rule_index"`
		}
		if err := json.Unmarshal(raw, &item); err != nil {
			return managedTun{}, errors.New("Linux TUN 入站无效")
		}
		if item.Type != "tun" {
			continue
		}
		tunCount++
		if item.Name != tunInterface || item.Table != tunTable || item.Priority != tunPriority ||
			item.AutoRedirect || item.DNSMode != "hijack" ||
			(!slices.Equal(item.Addresses, []string{tunIPv4}) &&
				!slices.Equal(item.Addresses, []string{tunIPv4, tunIPv6})) {
			return managedTun{}, errors.New("Linux TUN 接口、地址、DNS 和路由索引须使用应用生成的值")
		}
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(raw, &fields); err != nil {
			return managedTun{}, errors.New("Linux TUN 入站字段无效")
		}
		for key := range fields {
			switch key {
			case "type", "tag", "interface_name", "address", "mtu", "auto_route", "strict_route", "stack",
				"dns_mode", "route_address", "route_exclude_address", "auto_redirect",
				"iproute2_table_index", "iproute2_rule_index":
			default:
				return managedTun{}, fmt.Errorf("Linux TUN 无法托管字段 %q", key)
			}
		}
		spec.AutoRoute = item.AutoRoute
		spec.StrictRoute = item.StrictRoute
		spec.IPv6 = slices.Contains(item.Addresses, tunIPv6)
	}
	if tunCount != 1 {
		return managedTun{}, errors.New("Linux TUN 需要且仅允许一个 TUN 入站")
	}
	return spec, nil
}

func decodeTunJournal(file *os.File) (managedTun, error) {
	var spec managedTun
	if err := json.NewDecoder(io.LimitReader(file, 4096)).Decode(&spec); err != nil ||
		spec.Version != tunJournalVersion {
		return managedTun{}, errors.New("Linux TUN 恢复记录无效")
	}
	return spec, nil
}

func checkTunInterface() error {
	interfaces, err := net.Interfaces()
	if err != nil {
		return fmt.Errorf("读取系统网络接口：%w", err)
	}
	for _, item := range interfaces {
		if item.Name == tunInterface {
			return fmt.Errorf("接口 %s 已存在", tunInterface)
		}
	}
	return nil
}

func checkTunTable() error {
	routes, err := netlink.RouteListFiltered(netlink.FAMILY_ALL, &netlink.Route{Table: tunTable}, netlink.RT_FILTER_TABLE)
	if err != nil && !errors.Is(err, unix.ENOENT) && !errors.Is(err, unix.ESRCH) {
		return fmt.Errorf("读取 TUN 路由表：%w", err)
	}
	if len(routes) > 0 {
		return fmt.Errorf("路由表 %d 已被占用", tunTable)
	}
	return nil
}

func ensureTunResourcesFree() error {
	if err := checkTunInterface(); err != nil {
		return err
	}
	if _, err := tunRules(managedTun{}, false); err != nil {
		return err
	}
	return checkTunTable()
}

// A reserved priority alone does not establish ownership. Compare the actual
// selector and action to known sing-tun rules before touching anything.
func tunRules(spec managedTun, collect bool) ([]netlink.Rule, error) {
	expected := expectedTunRules(spec)
	request := nl.NewNetlinkRequest(unix.RTM_GETRULE, unix.NLM_F_DUMP)
	request.AddData(nl.NewIfInfomsg(unix.AF_UNSPEC))
	messages, err := request.Execute(unix.NETLINK_ROUTE, unix.RTM_NEWRULE)
	if err != nil {
		return nil, fmt.Errorf("读取系统路由规则：%w", err)
	}

	var matched []netlink.Rule
	var conflict error
	type ruleSlot struct{ family, priority int }
	occupied := make(map[ruleSlot]bool)
	for _, message := range messages {
		rule, supported, err := parseTunRule(message)
		if err != nil {
			return nil, err
		}
		if rule.Table != tunTable &&
			(rule.Priority < tunPriority || rule.Priority > tunLastPriority) {
			continue
		}
		index := slices.IndexFunc(expected, func(candidate netlink.Rule) bool {
			return sameTunRule(candidate, rule)
		})
		if !supported || index == -1 {
			conflict = fmt.Errorf("路由规则优先级 %d 或路由表 %d 与其他程序冲突", rule.Priority, tunTable)
			occupied[ruleSlot{rule.Family, rule.Priority}] = true
			continue
		}
		expected = slices.Delete(expected, index, index+1)
		if collect {
			matched = append(matched, rule)
		}
	}
	// A netlink delete treats omitted selectors as wildcards. Keep every
	// rule in a conflicting slot until it can be rechecked in isolation.
	matched = slices.DeleteFunc(matched, func(rule netlink.Rule) bool {
		return occupied[ruleSlot{rule.Family, rule.Priority}]
	})
	return matched, conflict
}

func deleteTunRule(rule netlink.Rule) error {
	if err := netlink.RuleDel(&rule); err != nil && !errors.Is(err, unix.ENOENT) &&
		!errors.Is(err, unix.ESRCH) {
		return fmt.Errorf("删除 Linux TUN 路由规则 %d：%w", rule.Priority, err)
	}
	return nil
}

func sameTunRule(expected, actual netlink.Rule) bool {
	if expected.Family == unix.AF_INET6 && expected.OifName == tunInterface &&
		expected.Priority == -1 {
		// Without auto_route, sing-tun picks this priority dynamically.
		expected.Priority = actual.Priority
	}
	return reflect.DeepEqual(expected, actual)
}

func expectedTunRules(spec managedTun) []netlink.Rule {
	if spec.Version != tunJournalVersion {
		return nil
	}
	var rules []netlink.Rule
	add := func(family, offset int, kind uint8, set func(*netlink.Rule)) {
		rule := netlink.NewRule()
		rule.Family = family
		rule.Priority = tunPriority + offset
		rule.Type = kind
		if set != nil {
			set(rule)
		}
		rules = append(rules, *rule)
	}
	table := func(rule *netlink.Rule) { rule.Table = tunTable }
	suppressDefault := func(rule *netlink.Rule) {
		table(rule)
		rule.SuppressPrefixlen = 0
	}
	nonDNSMain := func(rule *netlink.Rule) {
		rule.Invert = true
		rule.Table = unix.RT_TABLE_MAIN
		rule.SuppressPrefixlen = 0
		rule.Dport = netlink.NewRulePortRange(53, 53)
	}
	interfaceGoto := func(rule *netlink.Rule) {
		rule.IifName = tunInterface
		rule.Goto = tunLastPriority
	}
	if !spec.AutoRoute {
		if spec.IPv6 {
			add(unix.AF_INET6, 0, unix.FR_ACT_TO_TBL, func(rule *netlink.Rule) {
				rule.Priority = -1
				rule.Table = tunTable
				rule.OifName = tunInterface
			})
		}
		return rules
	}

	v4 := netip.MustParsePrefix(tunIPv4).Masked()
	add(unix.AF_INET, 0, unix.FR_ACT_TO_TBL, func(rule *netlink.Rule) {
		table(rule)
		rule.Dst = v4
	})
	add(unix.AF_INET, 1, unix.FR_ACT_TO_TBL, suppressDefault)
	add(unix.AF_INET, 2, unix.FR_ACT_TO_TBL, nonDNSMain)
	add(unix.AF_INET, 2, unix.FR_ACT_GOTO, interfaceGoto)
	add(unix.AF_INET, 3, unix.FR_ACT_TO_TBL, func(rule *netlink.Rule) {
		table(rule)
		rule.Invert = true
		rule.IifName = "lo"
	})
	for _, prefix := range []netip.Prefix{netip.MustParsePrefix("0.0.0.0/32"), v4} {
		add(unix.AF_INET, 3, unix.FR_ACT_TO_TBL, func(rule *netlink.Rule) {
			table(rule)
			rule.IifName = "lo"
			rule.Src = prefix
		})
	}
	add(unix.AF_INET, 10, unix.FR_ACT_NOP, nil)
	if !spec.IPv6 {
		if spec.StrictRoute {
			add(unix.AF_INET6, 0, unix.FR_ACT_UNREACHABLE, nil)
		}
		return rules
	}

	add(unix.AF_INET6, 0, unix.FR_ACT_TO_TBL, suppressDefault)
	add(unix.AF_INET6, 1, unix.FR_ACT_TO_TBL, nonDNSMain)
	add(unix.AF_INET6, 1, unix.FR_ACT_TO_TBL, func(rule *netlink.Rule) {
		table(rule)
		rule.IifName = "lo"
		rule.Src = netip.MustParsePrefix(tunIPv6).Masked()
	})
	add(unix.AF_INET6, 2, unix.FR_ACT_GOTO, interfaceGoto)
	for _, prefix := range []string{"::/1", "8000::/1"} {
		add(unix.AF_INET6, 2, unix.FR_ACT_GOTO, func(rule *netlink.Rule) {
			rule.Goto = tunLastPriority
			rule.IifName = "lo"
			rule.Src = netip.MustParsePrefix(prefix)
		})
	}
	add(unix.AF_INET6, 3, unix.FR_ACT_TO_TBL, table)
	add(unix.AF_INET6, 10, unix.FR_ACT_NOP, nil)
	return rules
}

func parseTunRule(message []byte) (netlink.Rule, bool, error) {
	rule := netlink.NewRule()
	if len(message) < unix.SizeofRtMsg {
		return *rule, false, errors.New("系统路由规则消息无效")
	}
	header := nl.DeserializeRtMsg(message)
	rule.Family = int(header.Family)
	rule.Type = header.Type
	rule.Tos = uint(header.Tos)
	rule.Invert = header.Flags&netlink.FibRuleInvert != 0
	if header.Table != unix.RT_TABLE_UNSPEC {
		rule.Table = int(header.Table)
	}
	attributes, err := nl.ParseRouteAttr(message[unix.SizeofRtMsg:])
	if err != nil {
		return *rule, false, err
	}
	supported := header.Flags & ^uint32(unix.FIB_RULE_INVERT|unix.FIB_RULE_IIF_DETACHED|unix.FIB_RULE_OIF_DETACHED|unix.FIB_RULE_UNRESOLVED) == 0
	order := nl.NativeEndian()
	for _, attr := range attributes {
		value := attr.Value
		switch attr.Attr.Type {
		case unix.FRA_TABLE, unix.FRA_PRIORITY, unix.FRA_GOTO, unix.FRA_SUPPRESS_PREFIXLEN, unix.FRA_SUPPRESS_IFGROUP:
			if len(value) != 4 {
				return *rule, false, errors.New("系统路由规则数值无效")
			}
			number := int(int32(order.Uint32(value)))
			switch attr.Attr.Type {
			case unix.FRA_TABLE:
				if number != unix.RT_TABLE_UNSPEC {
					rule.Table = number
				}
			case unix.FRA_PRIORITY:
				rule.Priority = number
			case unix.FRA_GOTO:
				rule.Goto = number
			case unix.FRA_SUPPRESS_PREFIXLEN:
				rule.SuppressPrefixlen = number
			case unix.FRA_SUPPRESS_IFGROUP:
				rule.SuppressIfgroup = number
			}
		case unix.FRA_SRC, unix.FRA_DST:
			address, ok := netip.AddrFromSlice(value)
			if !ok {
				return *rule, false, errors.New("系统路由规则地址无效")
			}
			if attr.Attr.Type == unix.FRA_SRC {
				rule.Src = netip.PrefixFrom(address, int(header.Src_len))
			} else {
				rule.Dst = netip.PrefixFrom(address, int(header.Dst_len))
			}
		case unix.FRA_IIFNAME, unix.FRA_OIFNAME:
			if len(value) == 0 || value[len(value)-1] != 0 {
				return *rule, false, errors.New("系统路由规则接口名无效")
			}
			if attr.Attr.Type == unix.FRA_IIFNAME {
				rule.IifName = string(value[:len(value)-1])
			} else {
				rule.OifName = string(value[:len(value)-1])
			}
		case unix.FRA_DPORT_RANGE:
			if len(value) != 4 {
				return *rule, false, errors.New("系统路由规则端口无效")
			}
			rule.Dport = netlink.NewRulePortRange(order.Uint16(value[:2]), order.Uint16(value[2:]))
		case fibDestinationPortMask:
			// Newer kernels dump an explicit all-bits mask for a single port.
			supported = supported && len(value) == 2 && order.Uint16(value) == 0xffff
		case unix.FRA_PROTOCOL:
			// Current sing-tun does not assign an origin protocol tag.
			supported = supported && len(value) == 1 && value[0] == unix.RTPROT_UNSPEC
		case unix.FRA_PAD:
		default:
			supported = false
		}
	}
	return *rule, supported, nil
}
