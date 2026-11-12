package engine

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestRefreshAutoUsesCompletedRoundDuringNativeProbe(t *testing.T) {
	probing := make(chan struct{}, 1)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case probing <- struct{}{}:
		default:
		}
		select {
		case <-release:
		case <-r.Context().Done():
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	core := New()
	defer core.Close()
	defer close(release)
	config := fmt.Appendf(nil, `{
		"log": {"disabled": true},
		"outbounds": [
			{"type": "direct", "tag": "first"},
			{"type": "direct", "tag": "fastest"},
			{"type": "direct", "tag": "excluded"},
			{"type": "urltest", "tag": "auto", "outbounds": ["first", "fastest"],
			 "url": %q, "interval": "3m", "tolerance": 50}
		],
		"route": {"final": "auto"}
	}`, server.URL)
	if err := core.Start(config); err != nil {
		t.Fatal(err)
	}
	select {
	case <-probing:
	case <-time.After(5 * time.Second):
		t.Fatal("native startup probe did not start")
	}
	selected := func() string { return core.Status().Groups["auto"].Selected }
	if got := selected(); got != "first" {
		t.Fatalf("initial selection = %q, want first", got)
	}

	first, fastest, excluded := uint16(240), uint16(75), uint16(10)
	if err := core.RefreshAuto(map[string]*uint16{
		"first": &first, "fastest": &fastest, "excluded": &excluded,
	}); err != nil {
		t.Fatal(err)
	}
	if got := selected(); got != "fastest" {
		t.Fatalf("selection after completed round = %q, want fastest", got)
	}

	// An improvement within the configured tolerance should not switch routes.
	first = 55
	if err := core.RefreshAuto(map[string]*uint16{"first": &first}); err != nil {
		t.Fatal(err)
	}
	if got := selected(); got != "fastest" {
		t.Fatalf("selection within tolerance = %q, want fastest", got)
	}

	// A failed candidate must not keep its previous successful measurement.
	if err := core.RefreshAuto(map[string]*uint16{"fastest": nil}); err != nil {
		t.Fatal(err)
	}
	if got := selected(); got != "first" {
		t.Fatalf("selection after fastest failed = %q, want first", got)
	}
}
