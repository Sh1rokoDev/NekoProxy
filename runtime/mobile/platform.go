//go:build android || linux || darwin || windows

package mobile

import (
	"context"
	"encoding/json"
	"net/netip"
	"sync"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/control"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	"github.com/sagernet/sing/common/x/list"
)

// Protector is implemented by the Android VpnService so outbound sockets can
// bypass the VPN interface and avoid routing loops.
type Protector interface {
	Protect(fd int32) bool
}

// OwnerFinder resolves a local socket to its Android package names. It is
// implemented by the VpnService host and returns a JSON object with the
// process id, user id and packageNames array.
type OwnerFinder interface {
	FindOwner(protocol int32, sourceAddress string, sourcePort int32, destinationAddress string, destinationPort int32) (string, error)
}

type androidPlatform struct {
	protector Protector
	finder    OwnerFinder
	monitor   interfaceMonitor

	mu      sync.Mutex
	tunFD   int
	tunName string
	address []netip.Addr
}

var _ adapter.PlatformInterface = (*androidPlatform)(nil)

func (p *androidPlatform) Initialize(networkManager adapter.NetworkManager) error { return nil }

func (p *androidPlatform) UsePlatformAutoDetectInterfaceControl() bool { return p.protector != nil }

func (p *androidPlatform) AutoDetectInterfaceControl(fd int) error {
	if p.protector == nil {
		return nil
	}
	if !p.protector.Protect(int32(fd)) {
		return E.New("VpnService.protect failed for fd ", fd)
	}
	return nil
}

func (p *androidPlatform) UsePlatformInterface() bool { return true }

func (p *androidPlatform) OpenInterface(options *tun.Options, platformOptions option.TunPlatformOptions) (tun.Tun, error) {
	if len(options.IncludeUID) > 0 || len(options.ExcludeUID) > 0 {
		return nil, E.New("platform: Android per-app UID rules are managed by VpnService")
	}
	if len(options.IncludeAndroidUser) > 0 {
		return nil, E.New("platform: android_user is not supported")
	}
	p.mu.Lock()
	fd := p.tunFD
	p.mu.Unlock()
	if fd == 0 {
		return nil, E.New("platform: no TUN file descriptor was provided by VpnService")
	}
	dupFD, err := dupFd(fd)
	if err != nil {
		return nil, E.Cause(err, "duplicate TUN file descriptor")
	}
	options.FileDescriptor = dupFD
	if options.Name == "" {
		options.Name = "tun0"
	}
	p.mu.Lock()
	p.tunName = options.Name
	p.address = p.address[:0]
	for _, prefix := range options.Inet4Address {
		p.address = append(p.address, prefix.Addr())
	}
	for _, prefix := range options.Inet6Address {
		p.address = append(p.address, prefix.Addr())
	}
	p.mu.Unlock()
	return tun.New(*options)
}

func (p *androidPlatform) ProcessPlatformOptions(options option.TunPlatformOptions) error {
	return nil
}

func (p *androidPlatform) UsePlatformDefaultInterfaceMonitor() bool { return true }

func (p *androidPlatform) CreateDefaultInterfaceMonitor(logger logger.Logger) tun.DefaultInterfaceMonitor {
	return &p.monitor
}

func (p *androidPlatform) UsePlatformNetworkInterfaces() bool { return false }

func (p *androidPlatform) NetworkInterfaces() ([]adapter.NetworkInterface, error) { return nil, nil }

func (p *androidPlatform) UnderNetworkExtension() bool { return false }

func (p *androidPlatform) NetworkExtensionIncludeAllNetworks() bool { return false }

func (p *androidPlatform) ClearDNSCache() {}

func (p *androidPlatform) RequestPermissionForWIFIState() error { return nil }

func (p *androidPlatform) ReadWIFIState(ctx context.Context) adapter.WIFIState {
	return adapter.WIFIState{}
}

func (p *androidPlatform) UsePlatformConnectionOwnerFinder() bool { return p.finder != nil }

func (p *androidPlatform) FindConnectionOwner(request *adapter.FindConnectionOwnerRequest) (*adapter.ConnectionOwner, error) {
	if p.finder == nil {
		return nil, E.New("connection owner lookup is unavailable")
	}
	raw, err := p.finder.FindOwner(
		request.IpProtocol,
		request.SourceAddress,
		request.SourcePort,
		request.DestinationAddress,
		request.DestinationPort,
	)
	if err != nil {
		return nil, err
	}
	if raw == "" {
		return nil, E.New("connection owner not found")
	}
	var payload struct {
		ProcessID    int      `json:"processId"`
		UserID       int      `json:"userId"`
		ProcessPath  string   `json:"processPath"`
		PackageNames []string `json:"packageNames"`
	}
	if err = json.Unmarshal([]byte(raw), &payload); err != nil {
		return nil, E.Cause(err, "decode connection owner")
	}
	if payload.ProcessID == 0 && len(payload.PackageNames) == 0 {
		return nil, E.New("connection owner not found")
	}
	return &adapter.ConnectionOwner{
		ProcessID:           uint32(payload.ProcessID),
		UserId:              int32(payload.UserID),
		ProcessPath:         payload.ProcessPath,
		AndroidPackageNames: payload.PackageNames,
	}, nil
}

func (p *androidPlatform) UsePlatformWIFIMonitor() bool { return false }

func (p *androidPlatform) UsePlatformNotification() bool { return false }

func (p *androidPlatform) SendNotification(notification *adapter.Notification) error { return nil }

func (p *androidPlatform) CancelNotification(identifier string, typeID int32) error { return nil }

func (p *androidPlatform) MyInterfaceAddress() []netip.Addr {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]netip.Addr(nil), p.address...)
}

func (p *androidPlatform) UsePlatformNeighborResolver() bool { return false }

func (p *androidPlatform) StartNeighborMonitor(listener adapter.NeighborUpdateListener) error {
	return nil
}

func (p *androidPlatform) CloseNeighborMonitor(listener adapter.NeighborUpdateListener) error {
	return nil
}

func (p *androidPlatform) UsePlatformShell() bool { return false }

func (p *androidPlatform) CheckPlatformShell() error { return E.New("shell is not available") }

func (p *androidPlatform) OpenShellSession(user *adapter.PlatformUser, command string, env []string, term string, rows int32, cols int32) (adapter.ShellSession, error) {
	return nil, E.New("shell is not available")
}

func (p *androidPlatform) LookupUser(username string) (*adapter.PlatformUser, error) {
	return nil, E.New("user lookup is not available")
}

func (p *androidPlatform) LookupSFTPServer() (string, error) {
	return "", E.New("sftp is not available")
}

func (p *androidPlatform) ReadSystemSSHHostKey() ([]byte, error) {
	return nil, E.New("ssh host key is not available")
}

func (p *androidPlatform) TailscaleHostname() string { return "" }

func (p *androidPlatform) UsePlatformBridge() bool { return false }

func (p *androidPlatform) CreateBridge(options adapter.BridgeOptions) (adapter.BridgeSession, error) {
	return nil, E.New("bridge is not available")
}

type interfaceMonitor struct {
	mu        sync.Mutex
	current   *control.Interface
	callbacks list.List[tun.DefaultInterfaceUpdateCallback]
}

var _ tun.DefaultInterfaceMonitor = (*interfaceMonitor)(nil)

func (m *interfaceMonitor) Start() error { return nil }

func (m *interfaceMonitor) Close() error { return nil }

func (m *interfaceMonitor) DefaultInterface() *control.Interface {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.current
}

func (m *interfaceMonitor) OverrideAndroidVPN() bool { return false }

func (m *interfaceMonitor) AndroidVPNEnabled() bool { return false }

func (m *interfaceMonitor) RegisterCallback(callback tun.DefaultInterfaceUpdateCallback) *list.Element[tun.DefaultInterfaceUpdateCallback] {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.callbacks.PushBack(callback)
}

func (m *interfaceMonitor) UnregisterCallback(element *list.Element[tun.DefaultInterfaceUpdateCallback]) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.callbacks.Remove(element)
}

func (m *interfaceMonitor) update(iface *control.Interface) {
	m.mu.Lock()
	m.current = iface
	callbacks := m.callbacks.Array()
	m.mu.Unlock()
	// Callbacks may read DefaultInterface and must run outside the lock.
	for _, callback := range callbacks {
		callback(iface, 0)
	}
}

func (m *interfaceMonitor) RegisterMyInterface(interfaceName string) {}

func (m *interfaceMonitor) MyInterfaces() []string { return nil }
