package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	tunExecutable      = "/usr/lib/nekoproxy/nekoproxy-tun-worker"
	ordinaryExecutable = "/usr/lib/nekoproxy/nekoproxy-worker"
	tunLockPath        = "/run/nekoproxy/tun.lock"
	tunJournal         = "/run/nekoproxy/tun/session.json"
)

func preparePlatformWorker(config []byte, readyPath, mode string, supervise, managed bool) (bool, error) {
	if !supervise && !managed {
		if executable, err := os.Executable(); err == nil && executable == tunExecutable {
			return false, errors.New("TUN 组件需要由 NekoProxy 启动")
		}
		return false, nil
	}
	if mode != "tun" || supervise == managed {
		return false, errors.New("Linux TUN 启动模式无效")
	}
	spec, err := readManagedTun(config)
	if err != nil {
		return false, err
	}
	if managed {
		// fd 3 holds the supervisor's lock until both processes exit.
		var lock unix.Stat_t
		var installed unix.Stat_t
		if unix.Fstat(3, &lock) != nil || unix.Stat(tunLockPath, &installed) != nil ||
			lock.Ino != installed.Ino || lock.Dev != installed.Dev {
			return false, errors.New("Linux TUN 缺少监督进程")
		}
		unix.CloseOnExec(3)
		return false, nil
	}
	return true, superviseTun(spec, config, readyPath)
}

func superviseTun(spec managedTun, config []byte, readyPath string) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	const netAdmin = uint32(1 << unix.CAP_NET_ADMIN)
	header := unix.CapUserHeader{Version: unix.LINUX_CAPABILITY_VERSION_3}
	var capabilities [2]unix.CapUserData
	if err := unix.Capget(&header, &capabilities[0]); err != nil ||
		capabilities[0].Effective&netAdmin == 0 {
		return errors.New("缺少 Linux TUN 权限，请检查软件包安装和当前用户的授权")
	}
	device, err := os.Stat("/dev/net/tun")
	if err != nil || device.Mode()&os.ModeCharDevice == 0 {
		return errors.New("无法使用 /dev/net/tun，请检查内核的 TUN 支持")
	}

	lock, err := openTunLock()
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := recoverTun(); err != nil {
		return fmt.Errorf("恢复上一次 Linux TUN：%w", err)
	}
	if err := ensureTunResourcesFree(); err != nil {
		return err
	}
	spec.Namespace, err = networkNamespace()
	if err != nil {
		return err
	}
	if err := writeTunJournal(spec); err != nil {
		return fmt.Errorf("保存 Linux TUN 恢复记录：%w", err)
	}

	// The unprivileged worker is a separate package file. Only this launcher
	// supplies CAP_NET_ADMIN, after it validates the managed TUN config.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)
	capabilities[0].Inheritable |= netAdmin
	if err := unix.Capset(&header, &capabilities[0]); err != nil {
		return errors.Join(fmt.Errorf("设置 TUN 进程权限：%w", err), recoverTun())
	}
	args := append(append([]string(nil), os.Args[1:]...), "-supervise-tun=false", "-managed-tun=true")
	cmd := exec.Command(ordinaryExecutable, args...)
	cmd.Env = []string{"PATH=/usr/sbin:/usr/bin", "LANG=C.UTF-8"}
	cmd.ExtraFiles = []*os.File{lock}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		AmbientCaps: []uintptr{unix.CAP_NET_ADMIN},
		Pdeathsig:   syscall.SIGTERM,
	}
	cmd.Stdin = bytes.NewReader(config)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return errors.Join(fmt.Errorf("启动受监督的 Linux TUN：%w", err), recoverTun())
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err = <-done:
	case <-signals:
		_ = cmd.Process.Signal(syscall.SIGTERM)
		timer := time.NewTimer(6 * time.Second)
		defer timer.Stop()
		select {
		case err = <-done:
		case <-timer.C:
			_ = cmd.Process.Kill()
			err = <-done
		}
	}
	cleanup := recoverTun()
	if cleanup != nil {
		return fmt.Errorf("清理 Linux TUN：%w", cleanup)
	}
	if err != nil {
		if _, statErr := os.Stat(readyPath + ".error"); statErr == nil {
			// Preserve the worker's more specific startup error.
			return nil
		}
		return fmt.Errorf("Linux TUN 内核异常退出：%w", err)
	}
	return nil
}

func openTunLock() (*os.File, error) {
	fd, err := unix.Open(tunLockPath, unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("无法访问 TUN 锁，请检查当前用户的授权：%w", err)
	}
	file := os.NewFile(uintptr(fd), tunLockPath)
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil || stat.Uid != 0 ||
		stat.Mode&unix.S_IFMT != unix.S_IFREG || stat.Mode&0007 != 0 {
		file.Close()
		return nil, errors.New("TUN 锁的所有者或权限无效")
	}
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, errors.New("已有一个 Linux TUN 会话正在运行")
		}
		return nil, fmt.Errorf("无法锁定 Linux TUN：%w", err)
	}
	return file, nil
}

func checkManagedTunReady(config []byte) error {
	spec, err := readManagedTun(config)
	if err != nil {
		return err
	}
	if _, err := tunRules(spec, false); err != nil {
		return err
	}
	if !spec.AutoRoute {
		return nil
	}
	// When systemd-resolved is active, wait until the per-link DNS is set.
	// sing-tun configures this asynchronously and cannot report an error.
	info, err := os.Stat("/run/systemd/resolve/io.systemd.Resolve")
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("检查 systemd-resolved：%w", err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return errors.New("systemd-resolved 的运行端点无效")
	}
	if _, err := net.InterfaceByName(tunInterface); err != nil {
		return fmt.Errorf("检查 Linux TUN 接口：%w", err)
	}
	dns := []string{"dns", tunInterface, "172.19.0.2"}
	if spec.IPv6 {
		dns = append(dns, "fdfe:dcba:9876::2")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, args := range [][]string{
		dns, {"domain", tunInterface, "~."}, {"default-route", tunInterface, "true"},
	} {
		cmd := exec.CommandContext(ctx, "/usr/bin/resolvectl", args...)
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("为 Linux TUN 设置 systemd-resolved DNS：%w", err)
		}
	}
	return nil
}

func checkManagedTunRules(config []byte) error {
	spec, err := readManagedTun(config)
	if err != nil {
		return err
	}
	_, err = tunRules(spec, false)
	return err
}

func writeTunJournal(spec managedTun) error {
	temp, err := os.CreateTemp("/run/nekoproxy/tun", ".session-")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	defer temp.Close()
	if err := temp.Chmod(0660); err != nil {
		return err
	}
	if err := json.NewEncoder(temp).Encode(spec); err != nil {
		return err
	}
	if err := temp.Sync(); err != nil {
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(temp.Name(), tunJournal)
}

func recoverTun() error {
	file, err := os.OpenFile(tunJournal, os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer file.Close()
	spec, err := decodeTunJournal(file)
	if err != nil {
		return err
	}
	namespace, err := networkNamespace()
	if err != nil {
		return err
	}
	if namespace != spec.Namespace {
		return errors.New("上一次 TUN 会话属于其他网络命名空间")
	}
	if err := checkTunInterface(); err != nil {
		return err
	}
	rules, conflict := tunRules(spec, true)
	for _, rule := range rules {
		if err := deleteTunRule(rule); err != nil {
			return errors.Join(conflict, err)
		}
	}
	if conflict != nil {
		return conflict
	}
	if err := ensureTunResourcesFree(); err != nil {
		return err
	}
	return os.Remove(tunJournal)
}

func networkNamespace() (uint64, error) {
	var stat unix.Stat_t
	if err := unix.Stat("/proc/self/ns/net", &stat); err != nil {
		return 0, fmt.Errorf("识别 Linux TUN 网络命名空间：%w", err)
	}
	return stat.Ino, nil
}
