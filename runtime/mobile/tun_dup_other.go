//go:build !android && !linux && !darwin

package mobile

import E "github.com/sagernet/sing/common/exceptions"

func dupFd(fd int) (int, error) {
	return 0, E.New("external TUN descriptors are not supported on this platform")
}
