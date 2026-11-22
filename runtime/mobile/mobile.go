package mobile

import (
	"context"
	"encoding/json"

	"nekoproxy/runtime/engine"
	"nekoproxy/runtime/rulesets"

	"github.com/sagernet/sing/common/control"
)

func ConvertRules(kind, input, output string) error {
	return rulesets.Convert(kind, input, output)
}

func ValidateConfig(config string) error {
	return engine.ValidateConfig([]byte(config))
}

// Engine is the gomobile surface used by the Android VpnService.
type Engine struct {
	inner    *engine.Engine
	platform *androidPlatform
}

func NewEngine(protector Protector, finder OwnerFinder) *Engine {
	return &Engine{
		inner:    engine.New(),
		platform: &androidPlatform{protector: protector, finder: finder},
	}
}

// SetTunOpener registers the VpnService callback before Start.
func (e *Engine) SetTunOpener(opener TunOpener) {
	e.platform.tunOpener = opener
}

func (e *Engine) Start(configJSON string) error {
	return e.inner.StartWithPlatform([]byte(configJSON), e.platform)
}

func (e *Engine) Stop() error {
	return e.inner.Close()
}

// UpdateDefaultInterface reports Android's underlying network, including loss.
func (e *Engine) UpdateDefaultInterface(name string, index int32) {
	var iface *control.Interface
	if name != "" && index > 0 {
		iface = &control.Interface{Name: name, Index: int(index)}
	}
	e.platform.monitor.update(iface)
}

func (e *Engine) StatusJSON() string {
	return marshal(e.inner.Status())
}

func (e *Engine) TrafficJSON() string {
	return marshal(e.inner.Traffic())
}

func (e *Engine) ConnectionsJSON() string {
	return marshal(e.inner.Connections())
}

func (e *Engine) Select(tag string) error {
	return e.inner.Select(tag)
}

func (e *Engine) RefreshAuto(delaysJSON string) error {
	var delays map[string]*uint16
	if err := json.Unmarshal([]byte(delaysJSON), &delays); err != nil {
		return err
	}
	return e.inner.RefreshAuto(delays)
}

func (e *Engine) Test(tagsJSON string, url string) string {
	var tags []string
	if err := json.Unmarshal([]byte(tagsJSON), &tags); err != nil {
		return marshal(map[string]any{"error": err.Error()})
	}
	return marshal(e.inner.Test(context.Background(), tags, url))
}

func (e *Engine) CloseConnection(id string) error {
	return e.inner.CloseConnection(id)
}

func (e *Engine) ClearConnections() {
	e.inner.CloseConnections()
}

func marshal(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		return "{}"
	}
	return string(data)
}
