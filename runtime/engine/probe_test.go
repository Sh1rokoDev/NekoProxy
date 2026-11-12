package engine

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func localDial(t *testing.T, rawURL string) func(context.Context) (net.Conn, error) {
	t.Helper()
	target, err := probeTarget(rawURL)
	if err != nil {
		t.Fatalf("probeTarget(%q): %v", rawURL, err)
	}
	return func(ctx context.Context) (net.Conn, error) {
		var dialer net.Dialer
		return dialer.DialContext(ctx, "tcp", target.String())
	}
}

func TestProbeDelayMeasuresHeaders(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(200 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	probe, err := probeDelay(context.Background(), server.URL, localDial(t, server.URL))
	if err != nil {
		t.Fatalf("probeDelay: %v", err)
	}
	if probe.delay < 150 || probe.delay > 1500 {
		t.Fatalf("delay = %dms, want roughly the 200ms header wait", probe.delay)
	}
}

func TestProbeDelayIgnoresSlowBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		time.Sleep(400 * time.Millisecond)
		_, _ = w.Write([]byte("late body"))
	}))
	defer server.Close()

	probe, err := probeDelay(context.Background(), server.URL, localDial(t, server.URL))
	if err != nil {
		t.Fatalf("probeDelay: %v", err)
	}
	if probe.delay > 250 {
		t.Fatalf("delay = %dms, body transfer must not count as latency", probe.delay)
	}
}

func TestProbeDelayRejectsBadStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer server.Close()

	if _, err := probeDelay(context.Background(), server.URL, localDial(t, server.URL)); err == nil {
		t.Fatal("probeDelay accepted HTTP 502")
	}
}

func TestProbeTargetDefaultsPorts(t *testing.T) {
	cases := map[string]string{
		"http://example.com/probe":  "example.com:80",
		"https://example.com/probe": "example.com:443",
		"http://example.com:8080/":  "example.com:8080",
	}
	for raw, want := range cases {
		target, err := probeTarget(raw)
		if err != nil {
			t.Fatalf("probeTarget(%q): %v", raw, err)
		}
		if target.String() != want {
			t.Fatalf("probeTarget(%q) = %q, want %q", raw, target.String(), want)
		}
	}
	if _, err := probeTarget("not a url"); err == nil {
		t.Fatal("probeTarget accepted an invalid URL")
	}
}
