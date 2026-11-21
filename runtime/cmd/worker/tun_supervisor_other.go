//go:build !linux

package main

import "errors"

func preparePlatformWorker(_ []byte, _, _ string, supervise, managed bool) (bool, error) {
	if supervise || managed {
		return false, errors.New("managed TUN is only available on Linux")
	}
	return false, nil
}

func checkManagedTunReady(_ []byte) error { return nil }
func checkManagedTunRules(_ []byte) error { return nil }
