//go:build !windows

package main

import "errors"

type wireGuardFirewall struct{}

func installWireGuardProtection(_ *wireGuardProtection) (*wireGuardFirewall, error) {
	return nil, errors.New("Windows WireGuard protection is unavailable")
}
func (*wireGuardFirewall) allowTun(_ *wireGuardProtection) error { return nil }
func (*wireGuardFirewall) close() error                          { return nil }
