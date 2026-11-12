package engine

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"sync"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/trafficcontrol"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/group"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/service"
)

var ErrNotRunning = errors.New("runtime is not running")

const (
	defaultTestURL   = "http://www.gstatic.com/generate_204"
	probeTimeout     = 2 * time.Second
	probeTLSTimeout  = 2 * time.Second
	probeConcurrency = 32
)

// Probes are separate short-lived connections and sing-box keeps no client
// session cache, so HTTPS probes pay a full handshake on every test. Sharing
// one cache lets repeated probes resume the session like Clash and NekoBox do.
var probeSessionCache = tls.NewLRUClientSessionCache(128)

var probeSlots = make(chan struct{}, probeConcurrency)

type GroupInfo struct {
	Kind     string   `json:"kind"`
	Selected string   `json:"selected"`
	All      []string `json:"all"`
}

type Status struct {
	Running     bool                 `json:"running"`
	StartedAt   int64                `json:"startedAt"`
	UptimeMS    int64                `json:"uptimeMs"`
	Error       string               `json:"error,omitempty"`
	Groups      map[string]GroupInfo `json:"groups"`
	InboundPort int                  `json:"inboundPort"`
}

type Traffic struct {
	Uploaded    int64 `json:"uploaded"`
	Downloaded  int64 `json:"downloaded"`
	Connections int   `json:"connections"`
	UptimeMS    int64 `json:"uptimeMs"`
}

type ConnectionInfo struct {
	ID          string `json:"id"`
	Network     string `json:"network"`
	Source      string `json:"source"`
	Destination string `json:"destination"`
	Domain      string `json:"domain,omitempty"`
	Outbound    string `json:"outbound"`
	Rule        string `json:"rule,omitempty"`
	Uploaded    int64  `json:"uploaded"`
	Downloaded  int64  `json:"downloaded"`
	CreatedAt   int64  `json:"createdAt"`
}

type Engine struct {
	mu          sync.RWMutex
	instance    *box.Box
	cancel      context.CancelFunc
	scope       *adapter.Scope
	traffic     *trafficcontrol.Manager
	startedAt   time.Time
	lastError   string
	inboundPort int
	serverByTag map[string]string
	ctx         context.Context
}

func New() *Engine {
	return &Engine{}
}

func (e *Engine) Start(configData []byte) error {
	return e.StartWithPlatform(configData, nil)
}

func (e *Engine) StartWithPlatform(configData []byte, platform adapter.PlatformInterface) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.instance != nil {
		return errors.New("runtime is already running")
	}

	ctx, cancel := context.WithCancel(context.Background())
	ctx = include.Context(ctx)
	ctx = service.ContextWithPtr(ctx, urltest.NewHistoryStorage())
	if platform != nil {
		service.MustRegister[adapter.PlatformInterface](ctx, platform)
	}
	var options option.Options
	if err := options.UnmarshalJSONContext(ctx, configData); err != nil {
		cancel()
		return fmt.Errorf("decode configuration: %w", err)
	}
	serverByTag := parseServerTags(configData)

	instance, err := box.New(box.Options{
		Options: options,
		Context: ctx,
	})
	if err != nil {
		cancel()
		return fmt.Errorf("create box: %w", err)
	}

	manager := trafficcontrol.NewManager()
	scope := adapter.NewScope(ctx, instance.LogFactory().NewLogger("traffic"))
	if err = manager.Start(adapter.StartStateInitialize, scope); err != nil {
		_ = instance.Close()
		cancel()
		return fmt.Errorf("start traffic manager: %w", err)
	}
	instance.Router().AppendTracker(manager)
	scope.Add(func() error {
		manager.Clear()
		return nil
	})

	if err = instance.Start(); err != nil {
		_ = scope.Close()
		_ = instance.Close()
		cancel()
		return fmt.Errorf("start sing-box: %w", err)
	}

	e.instance = instance
	e.cancel = cancel
	e.scope = scope
	e.traffic = manager
	e.startedAt = time.Now()
	e.lastError = ""
	e.inboundPort = findMixedPort(options.Inbounds)
	e.serverByTag = serverByTag
	e.ctx = ctx
	return nil
}

// parseServerTags remembers each outbound's server endpoint. Probe diagnostics
// need it to tell a slow resolver apart from a slow protocol handshake.
func parseServerTags(configData []byte) map[string]string {
	var raw struct {
		Outbounds []struct {
			Tag        string `json:"tag"`
			Server     string `json:"server"`
			ServerPort int    `json:"server_port"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(configData, &raw); err != nil {
		return nil
	}
	servers := make(map[string]string, len(raw.Outbounds))
	for _, outbound := range raw.Outbounds {
		if outbound.Tag == "" || outbound.Server == "" {
			continue
		}
		servers[outbound.Tag] = net.JoinHostPort(outbound.Server, strconv.Itoa(outbound.ServerPort))
	}
	return servers
}

func findMixedPort(inbounds []option.Inbound) int {
	for _, inbound := range inbounds {
		if inbound.Type != "mixed" {
			continue
		}
		if options, ok := inbound.Options.(*option.HTTPMixedInboundOptions); ok && options.ListenPort > 0 {
			return int(options.ListenPort)
		}
	}
	return 0
}

func (e *Engine) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.closeLocked()
}

func (e *Engine) closeLocked() error {
	if e.instance == nil {
		return nil
	}
	instance := e.instance
	scope := e.scope
	traffic := e.traffic
	e.instance = nil
	e.traffic = nil
	e.scope = nil
	startedAt := e.startedAt
	_ = startedAt
	if e.cancel != nil {
		e.cancel()
		e.cancel = nil
	}
	err := instance.Close()
	if scope != nil {
		err = errors.Join(err, scope.Close())
	}
	if traffic != nil {
		traffic.Clear()
	}
	return err
}

func (e *Engine) Status() Status {
	e.mu.RLock()
	defer e.mu.RUnlock()
	status := Status{
		Running:     e.instance != nil,
		Error:       e.lastError,
		Groups:      map[string]GroupInfo{},
		InboundPort: e.inboundPort,
	}
	if e.instance == nil {
		return status
	}
	status.StartedAt = e.startedAt.UnixMilli()
	status.UptimeMS = time.Since(e.startedAt).Milliseconds()
	for _, tag := range []string{"proxy", "auto"} {
		outbound, loaded := e.instance.Outbound().Outbound(tag)
		if !loaded {
			continue
		}
		switch value := outbound.(type) {
		case *group.Selector:
			selected := ""
			if current := value.Selected(N.NetworkTCP); current != nil {
				selected = current.Tag()
			}
			status.Groups[tag] = GroupInfo{Kind: "selector", Selected: selected, All: value.All()}
		case *group.URLTest:
			selected := ""
			if current := value.Selected(N.NetworkTCP); current != nil {
				selected = current.Tag()
			}
			status.Groups[tag] = GroupInfo{Kind: "urltest", Selected: selected, All: value.All()}
		}
	}
	return status
}

func (e *Engine) Select(tag string) error {
	e.mu.RLock()
	instance := e.instance
	e.mu.RUnlock()
	if instance == nil {
		return ErrNotRunning
	}
	outbound, loaded := instance.Outbound().Outbound("proxy")
	if !loaded {
		return errors.New("manual selection group is not present in this configuration")
	}
	selector, ok := outbound.(*group.Selector)
	if !ok {
		return errors.New("manual selection group is unavailable")
	}
	if !selector.SelectOutbound(tag) {
		return fmt.Errorf("unknown outbound: %s", tag)
	}
	return nil
}

func (e *Engine) Traffic() Traffic {
	e.mu.RLock()
	manager := e.traffic
	startedAt := e.startedAt
	running := e.instance != nil
	e.mu.RUnlock()
	if !running || manager == nil {
		return Traffic{}
	}
	up, down := manager.Total()
	return Traffic{
		Uploaded:    up,
		Downloaded:  down,
		Connections: manager.ConnectionsLen(),
		UptimeMS:    time.Since(startedAt).Milliseconds(),
	}
}

func (e *Engine) Connections() []ConnectionInfo {
	e.mu.RLock()
	manager := e.traffic
	e.mu.RUnlock()
	if manager == nil {
		return nil
	}
	trackers := manager.Connections()
	result := make([]ConnectionInfo, 0, len(trackers))
	for _, tracker := range trackers {
		metadata := tracker.Metadata
		rule := ""
		if tracker.Rule != nil {
			rule = tracker.Rule.String()
		}
		result = append(result, ConnectionInfo{
			ID:          tracker.ID.String(),
			Network:     metadata.Network,
			Source:      metadata.Source.String(),
			Destination: metadata.Destination.String(),
			Domain:      metadata.Domain,
			Outbound:    tracker.Outbound,
			Rule:        rule,
			Uploaded:    tracker.Upload.Load(),
			Downloaded:  tracker.Download.Load(),
			CreatedAt:   tracker.CreatedAt.UnixMilli(),
		})
	}
	return result
}

func (e *Engine) CloseConnections() {
	e.mu.RLock()
	manager := e.traffic
	e.mu.RUnlock()
	if manager != nil {
		manager.CloseAllConnections()
	}
}

func (e *Engine) Test(ctx context.Context, tags []string, testURL string) map[string]any {
	e.mu.RLock()
	instance := e.instance
	servers := e.serverByTag
	e.mu.RUnlock()
	result := make(map[string]any, len(tags))
	if instance == nil {
		for _, tag := range tags {
			result[tag] = map[string]any{"error": "runtime is not running"}
		}
		return result
	}
	if testURL == "" {
		testURL = defaultTestURL
	}
	type outcome struct {
		tag    string
		result probeResult
		dns    dnsInfo
		err    error
	}
	output := make(chan outcome, len(tags))
	for _, tag := range tags {
		tag := tag
		go func() {
			outbound, loaded := instance.Outbound().Outbound(tag)
			if !loaded {
				output <- outcome{tag: tag, err: fmt.Errorf("unknown outbound")}
				return
			}
			select {
			case probeSlots <- struct{}{}:
			case <-ctx.Done():
				output <- outcome{tag: tag, err: ctx.Err()}
				return
			}
			defer func() { <-probeSlots }()
			probeCtx, cancel := context.WithTimeout(ctx, probeTimeout)
			defer cancel()
			// Resolve the proxy server endpoint first: a cold lookup would
			// otherwise be billed to the node's latency, and the resolved
			// addresses are what the probe is about to dial.
			dns := resolveEndpoint(probeCtx, servers[tag])
			probe, err := testOutbound(probeCtx, outbound, testURL)
			output <- outcome{tag: tag, result: probe, dns: dns, err: err}
		}()
	}
	for range tags {
		item := <-output
		server := servers[item.tag]
		if item.err != nil {
			result[item.tag] = map[string]any{
				"error":  shortError(item.err),
				"server": server,
				"dial":   item.result.dial,
				"warm":   item.result.warm,
				"dial2":  item.result.dial2,
				"dns":    item.dns.ms,
				"addrs":  item.dns.addresses,
				"dnsErr": shortError(item.dns.err),
			}
		} else {
			result[item.tag] = map[string]any{
				"delay":  item.result.delay,
				"dial":   item.result.dial,
				"warm":   item.result.warm,
				"dial2":  item.result.dial2,
				"server": server,
				"dns":    item.dns.ms,
				"addrs":  item.dns.addresses,
			}
		}
	}
	return result
}

type dnsInfo struct {
	ms        int64
	addresses []string
	err       error
}

// resolveEndpoint looks up a proxy server hostname through the same resolver
// the outbound dialer will use, so the result is cached before the timed probe.
func resolveEndpoint(ctx context.Context, server string) dnsInfo {
	if ctx == nil || server == "" {
		return dnsInfo{}
	}
	host, _, err := net.SplitHostPort(server)
	if err != nil || host == "" {
		return dnsInfo{err: err}
	}
	if address, parseErr := netip.ParseAddr(host); parseErr == nil {
		return dnsInfo{addresses: []string{address.String()}}
	}
	router := service.FromContext[adapter.DNSRouter](ctx)
	networkManager := service.FromContext[adapter.NetworkManager](ctx)
	transportManager := service.FromContext[adapter.DNSTransportManager](ctx)
	if router == nil || networkManager == nil || transportManager == nil {
		return dnsInfo{err: errors.New("dns router unavailable")}
	}
	options := networkManager.DefaultOptions()
	queryOptions := options.DomainResolveOptions
	if transport, loaded := transportManager.Transport(options.DomainResolver); loaded {
		queryOptions.Transport = transport
	}
	started := time.Now()
	addresses, lookupErr := router.Lookup(ctx, host, queryOptions)
	elapsed := time.Since(started).Milliseconds()
	values := make([]string, 0, len(addresses))
	for _, address := range addresses {
		values = append(values, address.String())
	}
	return dnsInfo{ms: elapsed, addresses: values, err: lookupErr}
}

func testOutbound(ctx context.Context, outbound adapter.Outbound, testURL string) (probeResult, error) {
	target, err := probeTarget(testURL)
	if err != nil {
		return probeResult{}, err
	}
	return probeDelay(ctx, testURL, func(dialCtx context.Context) (net.Conn, error) {
		return outbound.DialContext(dialCtx, N.NetworkTCP, target)
	})
}

func probeTarget(testURL string) (M.Socksaddr, error) {
	parsed, err := url.Parse(testURL)
	if err != nil || parsed.Hostname() == "" {
		return M.Socksaddr{}, errors.New("invalid test URL")
	}
	port := parsed.Port()
	if port == "" {
		if parsed.Scheme == "http" {
			port = "80"
		} else {
			port = "443"
		}
	}
	portNumber, err := strconv.ParseUint(port, 10, 16)
	if err != nil {
		return M.Socksaddr{}, errors.New("invalid test URL port")
	}
	return M.ParseSocksaddrHostPort(parsed.Hostname(), uint16(portNumber)), nil
}

// probeResult splits the measurement so diagnostics can show whether the
// proxy handshake or the request itself dominates.
type probeResult struct {
	delay int64
	dial  int64
	warm  int64
	dial2 int64
}

// probeDelay measures the response latency of a request that reuses an already
// established tunnel. The first request builds the proxy and target
// connections; the second one, sent over the same keep-alive connection, is
// what gets reported. Counting the cold handshake made fast nodes look several
// hundred milliseconds slower than the browsing experience and than Clash.
func probeDelay(ctx context.Context, testURL string, dial func(context.Context) (net.Conn, error)) (probeResult, error) {
	probeCtx, cancelProbe := context.WithTimeout(ctx, probeTimeout)
	defer cancelProbe()
	var dialMS, dial2MS int64
	dialCount := 0
	transport := &http.Transport{
		ForceAttemptHTTP2:   false,
		DisableKeepAlives:   false,
		TLSHandshakeTimeout: probeTLSTimeout,
		DialContext: func(dialCtx context.Context, _, _ string) (net.Conn, error) {
			dialStarted := time.Now()
			conn, err := dial(dialCtx)
			elapsed := time.Since(dialStarted).Milliseconds()
			dialCount++
			if dialCount == 1 {
				dialMS = elapsed
			} else {
				dial2MS = elapsed
			}
			return conn, err
		},
		TLSClientConfig: &tls.Config{
			MinVersion:         tls.VersionTLS12,
			ClientSessionCache: probeSessionCache,
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport: transport,
		Timeout:   probeTimeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 3 {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}
	perform := func() (int64, error) {
		requestCtx, cancelRequest := context.WithTimeout(probeCtx, probeTimeout)
		defer cancelRequest()
		request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, testURL, nil)
		if err != nil {
			return 0, err
		}
		request.Header.Set("User-Agent", "NekoProxy/1.0 (latency test)")
		started := time.Now()
		response, err := client.Do(request)
		if err != nil {
			return 0, err
		}
		elapsed := time.Since(started).Milliseconds()
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64*1024))
		_ = response.Body.Close()
		if response.StatusCode < 200 || response.StatusCode >= 400 {
			return elapsed, fmt.Errorf("HTTP %d", response.StatusCode)
		}
		return elapsed, nil
	}
	warm, err := perform()
	if err != nil {
		return probeResult{dial: dialMS, dial2: dial2MS, warm: warm}, err
	}
	delay, err := perform()
	result := probeResult{delay: delay, dial: dialMS, dial2: dial2MS, warm: warm}
	if err != nil {
		return result, err
	}
	return result, nil
}

// RefreshAuto applies a complete manual probe round before asking the native
// urltest group to select again. A nil delay invalidates a failed candidate.
func (e *Engine) RefreshAuto(delays map[string]*uint16) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	instance := e.instance
	if instance == nil {
		return ErrNotRunning
	}
	outbound, loaded := instance.Outbound().Outbound("auto")
	if !loaded {
		return nil
	}
	group, ok := outbound.(adapter.URLTestGroup)
	if !ok {
		return nil
	}
	history := service.PtrFromContext[urltest.HistoryStorage](e.ctx)
	now := time.Now()
	for _, tag := range group.All() {
		delay, tested := delays[tag]
		if !tested {
			continue
		}
		if delay == nil {
			history.DeleteURLTestHistory(tag)
			continue
		}
		// The native selector uses zero as its "no delay yet" sentinel.
		history.StoreURLTestHistory(tag, &adapter.URLTestHistory{Time: now, Delay: max(1, *delay)})
	}
	group.PerformUpdateCheck()
	return nil
}

func shortError(err error) string {
	if err == nil {
		return ""
	}
	message := err.Error()
	if len(message) > 240 {
		return message[:240] + "..."
	}
	return message
}
