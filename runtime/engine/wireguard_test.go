//go:build with_wireguard && with_gvisor

package engine

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/sagernet/gvisor/pkg/buffer"
	"github.com/sagernet/gvisor/pkg/tcpip"
	"github.com/sagernet/gvisor/pkg/tcpip/adapters/gonet"
	"github.com/sagernet/gvisor/pkg/tcpip/link/channel"
	"github.com/sagernet/gvisor/pkg/tcpip/network/ipv4"
	"github.com/sagernet/gvisor/pkg/tcpip/network/ipv6"
	"github.com/sagernet/gvisor/pkg/tcpip/stack"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-tun"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

func TestWireGuardRouteThroughRealPeer(t *testing.T) {
	keys := func() (string, string) {
		private, err := ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		return base64.StdEncoding.EncodeToString(private.Bytes()), base64.StdEncoding.EncodeToString(private.PublicKey().Bytes())
	}
	serverKey, serverPublic := keys()
	clientKey, clientPublic := keys()
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	port := socket.LocalAddr().(*net.UDPAddr).Port
	if err := socket.Close(); err != nil {
		t.Fatal(err)
	}
	start := func(options string) *Engine {
		t.Helper()
		engine := New()
		if err := engine.Start([]byte(options)); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = engine.Close() })
		return engine
	}
	httpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodConnect {
			conn, rw, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Error(err)
				return
			}
			defer conn.Close()
			_, _ = rw.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
			_ = rw.Flush()
			if _, err := http.ReadRequest(rw.Reader); err != nil {
				t.Error(err)
				return
			}
			_, _ = rw.WriteString("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nvia proxy")
			_ = rw.Flush()
			return
		}
		_, _ = io.WriteString(w, "via peer")
	}))
	defer httpServer.Close()
	_, serverPort, _ := net.SplitHostPort(httpServer.Listener.Addr().String())
	servicePort, _ := strconv.Atoi(serverPort)
	peer := start(fmt.Sprintf(`{"log":{"disabled":true},"outbounds":[{"type":"direct","tag":"direct"}],
	  "dns":{"servers":[{"type":"hosts","tag":"fixture","predefined":{"wireguard.test":["10.67.0.1"]}}]},
	  "route":{"rules":[{"inbound":["peer"],"port":53,"action":"hijack-dns"}],"final":"direct"},
	  "endpoints":[{"type":"wireguard","tag":"peer","system":false,"listen_port":%d,
	    "address":["10.67.0.1/24","fd67::1/64"],"private_key":%q,"peers":[{"public_key":%q,"allowed_ips":["10.67.0.2/32","fd67::2/128"]}]}]}`,
		port, serverKey, clientPublic))
	client := start(fmt.Sprintf(`{"log":{"disabled":true},
	  "dns":{"servers":[{"type":"neko-wireguard-dns","tag":"dns","servers":["10.67.0.3"],"detour":"direct"}]},
	  "outbounds":[{"type":"direct","tag":"physical"},{"type":"neko-wireguard-route","tag":"direct","endpoint":"wg","physical":"physical","allowed_ips":["10.67.0.0/24","fd67::/64"],"resolver":"dns"},
	    {"type":"http","tag":"proxy","server":"10.67.0.1","server_port":%d,"detour":"direct"},
	    {"type":"http","tag":"proxy-unmatched","server":"127.0.0.1","server_port":%d,"detour":"direct"}],
	  "endpoints":[{"type":"wireguard","tag":"wg","system":false,"address":["10.67.0.2/24","fd67::2/64"],"private_key":%q,
	    "peers":[{"address":"127.0.0.1","port":%d,"public_key":%q,"allowed_ips":["10.67.0.0/24","fd67::/64"]}]}],
	  "route":{"final":"direct","default_domain_resolver":{"server":"dns"},"rules":[
	    {"inbound":["wg"],"action":"reject"},
	    {"port":53,"action":"hijack-dns"},
	    {"inbound":["tun-in"],"ip_cidr":["10.67.0.0/24","fd67::/64"],"action":"route","outbound":"wg"}]}}`,
		servicePort, servicePort, clientKey, port, serverPublic))
	get := func(tag, destination, want string) {
		t.Helper()
		outbound, ok := client.instance.Outbound().Outbound(tag)
		if !ok {
			t.Fatalf("missing outbound %s", tag)
		}
		httpClient := http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
			DisableKeepAlives: true,
			DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
				return outbound.DialContext(ctx, network, M.ParseSocksaddr(address))
			},
		}}
		response, err := httpClient.Get("http://" + destination)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		if body, err := io.ReadAll(response.Body); err != nil || string(body) != want {
			t.Fatalf("outbound %s: response %q, err %v", tag, body, err)
		}
	}
	get("direct", "10.67.0.1:"+serverPort, "via peer")
	get("direct", "wireguard.test:"+serverPort, "via peer")
	get("proxy", "192.0.2.1:80", "via proxy")
	t.Run("TLS over IPv4 packets", func(t *testing.T) {
		testWireGuardHTTPSFromTun(t, client.instance.Router(), "127.0.0.1:0", "172.19.0.1/30", "10.67.0.1", ipv4.ProtocolNumber)
	})
	t.Run("TLS over IPv6 packets", func(t *testing.T) {
		testWireGuardHTTPSFromTun(t, client.instance.Router(), "[::1]:0", "fdfe:dcba:9876::1/126", "fd67::1", ipv6.ProtocolNumber)
	})
	if err := peer.Close(); err != nil {
		t.Fatal(err)
	}
	get("direct", httpServer.Listener.Addr().String(), "via peer")
	get("proxy-unmatched", "192.0.2.1:80", "via proxy")
	outbound, _ := client.instance.Outbound().Outbound("direct")
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	conn, err := outbound.DialContext(ctx, "tcp", M.SocksaddrFrom(netip.MustParseAddr("10.67.0.1"), uint16(servicePort)))
	if err == nil {
		conn.Close()
		t.Fatal("covered destination unexpectedly connected after the WireGuard peer stopped")
	}
}

// Feed packets from a separate client TCP stack through the same dispatcher
// used by the Windows system TUN, without requiring a driver or elevation.
func testWireGuardHTTPSFromTun(t *testing.T, router adapter.Router, loopback, source, destination string, protocol tcpip.NetworkProtocolNumber) {
	t.Helper()
	payload := strings.Repeat("HTTPS over WireGuard\n", 4096)
	listener, err := net.Listen("tcp", loopback)
	if err != nil {
		t.Fatal(err)
	}
	server := &httptest.Server{Listener: listener, Config: &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if body, err := io.ReadAll(r.Body); err != nil || string(body) != payload {
			http.Error(w, "bad request body", http.StatusBadRequest)
			return
		}
		_, _ = io.WriteString(w, payload)
	})}}
	server.StartTLS()
	defer server.Close()
	port := uint16(server.Listener.Addr().(*net.TCPAddr).Port)
	link := channel.New(256, 1408, "")
	ipStack, err := tun.NewGVisorStackWithOptions(link, stack.NICOptions{}, false)
	if err != nil {
		t.Fatal(err)
	}
	defer ipStack.Close()
	prefix := netip.MustParsePrefix(source)
	if err := ipStack.AddProtocolAddress(tun.DefaultNIC, tcpip.ProtocolAddress{
		Protocol:          protocol,
		AddressWithPrefix: tcpip.AddressWithPrefix{Address: tun.AddressFromAddr(prefix.Addr()), PrefixLen: prefix.Bits()},
	}, stack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	dispatcher := tun.NewForwardDispatcher(tunTCPHandler{router: router}, tunTCPWriteback{link, protocol}, log.NewNOPFactory().Logger(), 0, 0)
	defer dispatcher.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	readDone := make(chan struct{})
	defer func() {
		cancel()
		<-readDone
	}()
	go func() {
		defer close(readDone)
		for {
			packet := link.ReadContext(ctx)
			if packet == nil {
				return
			}
			view := packet.ToView()
			packet.DecRef()
			forwarded := dispatcher.Dispatch(view.AsSlice())
			dispatcher.Flush()
			view.Release()
			if !forwarded {
				t.Error("TUN packet did not take the WireGuard packet path")
				cancel()
				return
			}
		}
	}()
	transport := server.Client().Transport.(*http.Transport).Clone()
	defer transport.CloseIdleConnections()
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		return gonet.DialContextTCP(ctx, ipStack, tcpip.FullAddress{
			NIC: tun.DefaultNIC, Addr: tun.AddressFromAddr(netip.MustParseAddr(destination)), Port: port,
		}, protocol)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, server.URL, strings.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	response, err := (&http.Client{Transport: transport}).Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if body, err := io.ReadAll(response.Body); err != nil || response.StatusCode != http.StatusOK || string(body) != payload {
		t.Fatalf("HTTPS through WireGuard: HTTP %d, %d bytes, err %v", response.StatusCode, len(body), err)
	}
}

type tunTCPHandler struct {
	tun.Handler
	router adapter.Router
}

func (h tunTCPHandler) JudgeFlow(_ uint8, source, destination netip.AddrPort, firstPacket []byte) tun.FlowVerdict {
	result := h.router.PreMatch(adapter.InboundContext{
		Inbound: "tun-in", InboundType: "tun", Network: N.NetworkTCP,
		Source: M.SocksaddrFromNetIP(source), Destination: M.SocksaddrFromNetIP(destination),
	}, firstPacket)
	if port, ok := result.Outbound.(tun.Port); result.Action == adapter.PreMatchFlow && ok {
		return tun.FlowVerdict{Action: tun.ActionFlow, Port: port}
	}
	return tun.FlowVerdict{Action: tun.ActionAccept}
}

type tunTCPWriteback struct {
	link     *channel.Endpoint
	protocol tcpip.NetworkProtocolNumber
}

func (tunTCPWriteback) ReturnHeadroom() int { return 0 }

func (w tunTCPWriteback) WriteReturnPackets(packets [][]byte) error {
	for _, data := range packets {
		packet := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(data)})
		w.link.InjectInbound(w.protocol, packet)
		packet.DecRef()
	}
	return nil
}

func TestWireGuardRouteRejectsUncoveredWhenProtected(t *testing.T) {
	var options wireGuardRouteOptions
	if err := json.Unmarshal([]byte(`{"allowed_ips":["0.0.0.0/0"],"protect_windows":true}`), &options); err != nil {
		t.Fatal(err)
	}
	route := &wireGuardRoute{options: options}
	_, err := route.target(route.covered(netip.MustParseAddr("2001:db8::1")))
	if err == nil || !strings.Contains(err.Error(), "outside WireGuard") {
		t.Fatalf("uncovered protected destination: %v", err)
	}
}
