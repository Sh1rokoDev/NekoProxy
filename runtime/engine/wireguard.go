package engine

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"time"

	mdns "github.com/miekg/dns"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/dialer"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/dns/transport"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/bufio"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service"
)

const wireGuardRouteType = "neko-wireguard-route"
const wireGuardDNSType = "neko-wireguard-dns"

func registerWireGuard(ctx context.Context) context.Context {
	ctx = include.Context(ctx)
	outbound.Register(service.FromContext[adapter.OutboundRegistry](ctx).(*outbound.Registry), wireGuardRouteType, newWireGuardRoute)
	dns.RegisterTransport(service.FromContext[adapter.DNSTransportRegistry](ctx).(*dns.TransportRegistry), wireGuardDNSType, newWireGuardDNS)
	return ctx
}

type wireGuardRouteOptions struct {
	Endpoint       string         `json:"endpoint"`
	Physical       string         `json:"physical"`
	Allowed        []netip.Prefix `json:"allowed_ips"`
	Resolver       string         `json:"resolver"`
	ProtectWindows bool           `json:"protect_windows,omitempty"`
	BlockUncovered bool           `json:"block_uncovered,omitempty"`
}

type wireGuardRoute struct {
	outbound.Adapter
	ctx     context.Context
	options wireGuardRouteOptions
}

func newWireGuardRoute(ctx context.Context, _ adapter.Router, _ log.ContextLogger, tag string, options wireGuardRouteOptions) (adapter.Outbound, error) {
	if options.Endpoint == "" || options.Physical == "" || len(options.Allowed) == 0 {
		return nil, errors.New("invalid WireGuard route options")
	}
	return &wireGuardRoute{outbound.NewAdapter(wireGuardRouteType, tag, []string{N.NetworkTCP, N.NetworkUDP}, []string{options.Endpoint, options.Physical}), ctx, options}, nil
}

func (r *wireGuardRoute) addresses(ctx context.Context, dest M.Socksaddr) ([]netip.Addr, error) {
	if dest.IsIP() {
		return []netip.Addr{dest.Addr}, nil
	}
	if !dest.IsDomain() {
		return nil, errors.New("missing WireGuard route destination")
	}
	resolver, ok := service.FromContext[adapter.DNSTransportManager](r.ctx).Transport(r.options.Resolver)
	if !ok {
		return nil, errors.New("WireGuard route DNS is unavailable")
	}
	return service.FromContext[adapter.DNSRouter](r.ctx).Lookup(ctx, dest.Fqdn, adapter.DNSQueryOptions{Transport: resolver})
}

func (r *wireGuardRoute) covered(address netip.Addr) bool {
	for _, prefix := range r.options.Allowed {
		if prefix.Contains(address.Unmap()) {
			return true
		}
	}
	return false
}

func (r *wireGuardRoute) target(covered bool) (adapter.Outbound, error) {
	tag := r.options.Endpoint
	if !covered {
		if r.options.ProtectWindows || r.options.BlockUncovered {
			return nil, errors.New("destination is outside WireGuard AllowedIPs")
		}
		tag = r.options.Physical
	}
	result, ok := service.FromContext[adapter.OutboundManager](r.ctx).Outbound(tag)
	if !ok {
		return nil, errors.New("WireGuard route outbound is unavailable")
	}
	return result, nil
}

func (r *wireGuardRoute) DialContext(ctx context.Context, network string, dest M.Socksaddr) (net.Conn, error) {
	addresses, err := r.addresses(ctx, dest)
	if err != nil {
		return nil, err
	}
	if len(addresses) == 0 {
		return nil, errors.New("WireGuard destination has no addresses")
	}
	covered := r.covered(addresses[0])
	target, err := r.target(covered)
	if err != nil {
		return nil, err
	}
	for _, address := range addresses {
		if r.covered(address) != covered {
			continue
		}
		var conn net.Conn
		conn, err = target.DialContext(ctx, network, M.SocksaddrFrom(address, dest.Port))
		if err == nil {
			return conn, nil
		}
		if ctx.Err() != nil {
			break
		}
	}
	return nil, err
}

func (r *wireGuardRoute) ListenPacketWithDestination(ctx context.Context, dest M.Socksaddr) (net.PacketConn, netip.Addr, error) {
	addresses, err := r.addresses(ctx, dest)
	if err != nil {
		return nil, netip.Addr{}, err
	}
	if len(addresses) == 0 {
		return nil, netip.Addr{}, errors.New("WireGuard destination has no addresses")
	}
	address := addresses[0]
	covered := r.covered(address)
	target, err := r.target(covered)
	if err != nil {
		return nil, netip.Addr{}, err
	}
	conn, err := target.ListenPacket(ctx, M.SocksaddrFrom(address, dest.Port))
	if err != nil {
		return nil, netip.Addr{}, err
	}
	return &wireGuardPacketConn{PacketConn: conn, route: r, covered: covered}, address, nil
}

// A UDP socket may be used with more than one destination. Do not let a
// packet cross the routing boundary chosen for that socket.
type wireGuardPacketConn struct {
	net.PacketConn
	route   *wireGuardRoute
	covered bool
}

func (c *wireGuardPacketConn) WriteTo(p []byte, destination net.Addr) (int, error) {
	target := M.SocksaddrFromNet(destination)
	if !target.IsIP() || c.route.covered(target.Addr) != c.covered {
		return 0, errors.New("UDP destination is outside the selected WireGuard route")
	}
	return c.PacketConn.WriteTo(p, destination)
}

func (r *wireGuardRoute) ListenPacket(ctx context.Context, dest M.Socksaddr) (net.PacketConn, error) {
	conn, address, err := r.ListenPacketWithDestination(ctx, dest)
	if err != nil {
		return nil, err
	}
	resolved := M.SocksaddrFrom(address, dest.Port)
	if resolved == dest {
		return conn, nil
	}
	return bufio.NewNATPacketConn(bufio.NewPacketConn(conn), resolved, dest), nil
}

type wireGuardDNSOptions struct {
	option.DialerOptions
	Servers []netip.Addr `json:"servers"`
	Search  []string     `json:"search_domains,omitempty"`
}

type wireGuardDNS struct {
	dns.TransportAdapter
	servers []netip.Addr
	search  []string
	udp     []*transport.UDPTransport
	tcp     []*transport.TCPTransport
}

func newWireGuardDNS(ctx context.Context, logger log.ContextLogger, tag string, options wireGuardDNSOptions) (adapter.DNSTransport, error) {
	if len(options.Servers) == 0 {
		return nil, errors.New("WireGuard DNS requires a server")
	}
	d, err := dialer.New(ctx, options.DialerOptions, false)
	if err != nil {
		return nil, err
	}
	t := &wireGuardDNS{TransportAdapter: dns.NewTransportAdapter(wireGuardDNSType, tag, nil), servers: options.Servers, search: options.Search}
	for _, server := range options.Servers {
		address := M.SocksaddrFrom(server, 53)
		t.udp = append(t.udp, transport.NewUDPRaw(logger, t.TransportAdapter, d, address))
		t.tcp = append(t.tcp, transport.NewTCPRaw(t.TransportAdapter, d, address))
	}
	return t, nil
}

func (t *wireGuardDNS) ServerAddresses() []netip.Addr { return t.servers }
func (t *wireGuardDNS) SearchDomains() []string       { return t.search }
func (t *wireGuardDNS) Start(stage adapter.StartStage, scope *adapter.Scope) error {
	for i, udp := range t.udp {
		if err := udp.Start(stage, scope); err != nil {
			return err
		}
		if err := t.tcp[i].Start(stage, scope); err != nil {
			return err
		}
	}
	return nil
}
func (t *wireGuardDNS) Reset() {
	for i, udp := range t.udp {
		udp.Reset()
		t.tcp[i].Reset()
	}
}
func (t *wireGuardDNS) Exchange(ctx context.Context, message *mdns.Msg) (*mdns.Msg, error) {
	var last error
	for i, udp := range t.udp {
		attempt, cancel := context.WithTimeout(ctx, 2*time.Second)
		response, err := udp.Exchange(attempt, message)
		if err == nil && response.Truncated {
			response, err = t.tcp[i].Exchange(attempt, message)
		}
		cancel()
		if err == nil && (response.Rcode == mdns.RcodeSuccess || response.Rcode == mdns.RcodeNameError) {
			return response, nil
		}
		if err == nil {
			err = errors.New("WireGuard DNS server returned an error")
		}
		last = err
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	return nil, last
}
func (t *wireGuardDNS) ExchangeAsync(ctx context.Context, message *mdns.Msg, callback func(*mdns.Msg, error)) {
	go func() { callback(t.Exchange(ctx, message)) }()
}
