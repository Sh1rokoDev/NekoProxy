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

	M "github.com/sagernet/sing/common/metadata"
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
	  "endpoints":[{"type":"wireguard","tag":"peer","system":false,"listen_port":%d,
	    "address":["10.67.0.1/24"],"private_key":%q,"peers":[{"public_key":%q,"allowed_ips":["10.67.0.2/32"]}]}]}`,
		port, serverKey, clientPublic))
	client := start(fmt.Sprintf(`{"log":{"disabled":true},
	  "dns":{"servers":[{"type":"neko-wireguard-dns","tag":"dns","servers":["10.67.0.3"],"detour":"direct"}]},
	  "outbounds":[{"type":"direct","tag":"physical"},{"type":"neko-wireguard-route","tag":"direct","endpoint":"wg","physical":"physical","allowed_ips":["10.67.0.0/24"],"resolver":"dns"},
	    {"type":"http","tag":"proxy","server":"10.67.0.1","server_port":%d,"detour":"direct"}],
	  "endpoints":[{"type":"wireguard","tag":"wg","system":false,"address":["10.67.0.2/24"],"private_key":%q,
	    "peers":[{"address":"127.0.0.1","port":%d,"public_key":%q,"allowed_ips":["10.67.0.0/24"]}]}],
	  "route":{"final":"direct","default_domain_resolver":{"server":"dns"}}}`,
		servicePort, clientKey, port, serverPublic))
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
	get("proxy", "192.0.2.1:80", "via proxy")
	if err := peer.Close(); err != nil {
		t.Fatal(err)
	}
	get("direct", httpServer.Listener.Addr().String(), "via peer")
	outbound, _ := client.instance.Outbound().Outbound("direct")
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	conn, err := outbound.DialContext(ctx, "tcp", M.SocksaddrFrom(netip.MustParseAddr("10.67.0.1"), uint16(servicePort)))
	if err == nil {
		conn.Close()
		t.Fatal("covered destination unexpectedly connected after the WireGuard peer stopped")
	}
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
