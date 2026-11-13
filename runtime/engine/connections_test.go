package engine

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
)

func TestConnectionsReportMatchedRuleIndex(t *testing.T) {
	core := New()
	if err := core.Start([]byte(`{
		"log": {"disabled": true},
		"outbounds": [{"type": "direct", "tag": "direct"}],
		"route": {"rules": [
			{"domain": ["example.com"], "action": "route", "outbound": "direct"},
			{"domain": ["example.com"], "action": "route", "outbound": "direct"}
		]}
	}`)); err != nil {
		t.Fatal(err)
	}
	defer core.Close()
	outbound, ok := core.instance.Outbound().Outbound("direct")
	if !ok {
		t.Fatal("direct outbound not found")
	}
	rules := core.instance.Router().Rules()
	for index, rule := range append(append([]adapter.Rule(nil), rules...), nil) {
		conn, peer := net.Pipe()
		tracked := core.traffic.RoutedConnection(context.Background(), conn, adapter.InboundContext{
			OutboundChain: []adapter.Outbound{outbound},
		}, rule, outbound)
		connections := core.Connections()
		_ = tracked.Close()
		_ = peer.Close()
		if len(connections) != 1 {
			t.Fatalf("expected one connection, got %d", len(connections))
		}
		data, err := json.Marshal(connections[0])
		if err != nil {
			t.Fatal(err)
		}
		var decoded ConnectionInfo
		if err := json.Unmarshal(data, &decoded); err != nil {
			t.Fatal(err)
		}
		if rule == nil {
			if decoded.RuleIndex != nil {
				t.Fatalf("unexpected rule index for unmatched connection: %s", data)
			}
		} else if decoded.RuleIndex == nil || *decoded.RuleIndex != index {
			t.Fatalf("expected rule index %d: %s", index, data)
		}
	}
}

func TestCloseConnectionTargetsOnlyRequestedTracker(t *testing.T) {
	core := New()
	if err := core.Start([]byte(`{
		"log": {"disabled": true},
		"outbounds": [{"type": "direct", "tag": "direct"}]
	}`)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	outbound, ok := core.instance.Outbound().Outbound("direct")
	if !ok {
		t.Fatal("direct outbound not found")
	}
	track := func() net.Conn {
		conn, peer := net.Pipe()
		tracked := core.traffic.RoutedConnection(context.Background(), conn, adapter.InboundContext{
			OutboundChain: []adapter.Outbound{outbound},
		}, nil, outbound)
		t.Cleanup(func() { _ = peer.Close(); _ = tracked.Close() })
		return peer
	}
	peer := track()
	id := core.Connections()[0].ID
	track()
	server := Server{engine: core}
	request := Request{Cmd: "closeConnection", ConnectionID: id}
	if err := peer.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if response := server.execute(context.Background(), request); !response.OK {
		t.Fatal(response.Error)
	}
	if _, err := peer.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("expected the target socket to close, got %v", err)
	}
	if connections := core.Connections(); len(connections) != 1 || connections[0].ID == id {
		t.Fatalf("expected only the other connection to remain, got %+v", connections)
	}
	if response := server.execute(context.Background(), request); !response.OK {
		t.Fatalf("closing an expired connection should succeed: %s", response.Error)
	}
}
