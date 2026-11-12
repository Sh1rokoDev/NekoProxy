//go:build android || linux || darwin

package mobile

import "syscall"

func dupFd(fd int) (int, error) {
	dup, err := syscall.Dup(fd)
	if err != nil {
		return 0, err
	}
	syscall.CloseOnExec(dup)
	return dup, nil
}
