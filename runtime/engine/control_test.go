package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestControlReturnsCompletedProbeWhileAnotherIsPending(t *testing.T) {
	started := make(chan struct{}, 1)
	release, unblock := context.WithCancel(context.Background())
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/slow" {
			select {
			case started <- struct{}{}:
			default:
			}
			select {
			case <-release.Done():
			case <-r.Context().Done():
			}
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()
	defer unblock()
	core := New()
	defer core.Close()
	if err := core.Start([]byte(`{
		"log": {"disabled": true},
		"outbounds": [{"type": "direct", "tag": "direct"}]
	}`)); err != nil {
		t.Fatal(err)
	}
	control, err := NewServer(core, "test-token", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()
	go control.Serve()
	connection, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", control.Port()))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	encoder := json.NewEncoder(connection)
	decoder := json.NewDecoder(connection)
	read := func() Response {
		t.Helper()
		var response Response
		if err := decoder.Decode(&response); err != nil {
			t.Fatal(err)
		}
		if !response.OK {
			t.Fatalf("control error: %s", response.Error)
		}
		return response
	}
	if err := encoder.Encode(map[string]string{"token": "test-token"}); err != nil {
		t.Fatal(err)
	}
	read()
	if err := encoder.Encode(Request{ID: 1, Cmd: "test", Tags: []string{"direct"}, URL: target.URL + "/slow"}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("slow probe did not start")
	}
	for _, request := range []Request{
		{ID: 2, Cmd: "test", Tags: []string{"direct"}, URL: target.URL + "/fast"},
		{ID: 3, Cmd: "ping"},
	} {
		if err := encoder.Encode(request); err != nil {
			t.Fatal(err)
		}
	}
	seen := make(map[int64]bool)
	for range 2 {
		response := read()
		if response.ID != 2 && response.ID != 3 {
			t.Fatalf("received response %d while slow probe was blocked", response.ID)
		}
		if response.ID == 2 {
			data := response.Data.(map[string]any)["direct"].(map[string]any)
			if _, ok := data["delay"]; !ok {
				t.Fatalf("fast probe failed: %v", data)
			}
		}
		seen[response.ID] = true
	}
	if len(seen) != 2 {
		t.Fatalf("missing fast probe or heartbeat response: %v", seen)
	}
	unblock()
	if response := read(); response.ID != 1 {
		t.Fatalf("last response = %d, want slow probe", response.ID)
	}
}
