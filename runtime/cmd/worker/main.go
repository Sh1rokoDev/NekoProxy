package main

import (
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"nekoproxy/runtime/engine"
	"nekoproxy/runtime/rulesets"
)

var version = "dev"

func main() {
	if len(os.Args) == 5 && os.Args[1] == "convert-rules" {
		if err := rulesets.Convert(os.Args[2], os.Args[3], os.Args[4]); err != nil {
			fail("", err.Error())
		}
		return
	}
	var (
		configPath = flag.String("config", "", "path to sing-box configuration")
		readyPath  = flag.String("ready", "", "path to runtime readiness file")
		logPath    = flag.String("log", "", "path to log file")
		installDir = flag.String("install-dir", "", "root for configuration output files")
		token      = flag.String("token", "", "control token")
		mode       = flag.String("mode", "normal", "worker mode label")
		leaseSecs  = flag.Int("lease", 90, "exit after this many seconds without a client")
	)
	flag.Parse()

	if *logPath != "" {
		_ = os.MkdirAll(filepath.Dir(*logPath), 0o700)
		if file, err := os.OpenFile(*logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
			os.Stdout = file
			os.Stderr = file
			log.SetOutput(file)
			defer file.Close()
		}
	}

	if *configPath == "" || *readyPath == "" {
		fail(*readyPath, "missing -config or -ready")
	}
	if *token == "" {
		buffer := make([]byte, 32)
		if _, err := rand.Read(buffer); err != nil {
			fail(*readyPath, "generate token: "+err.Error())
		}
		*token = hex.EncodeToString(buffer)
	}
	if len(*token) < 32 {
		fail(*readyPath, "control token is too short")
	}

	configData, err := readConfig(*configPath)
	if err != nil {
		fail(*readyPath, "read configuration: "+err.Error())
	}
	if err = validateOutputPaths(configData, *installDir); err != nil {
		fail(*readyPath, err.Error())
	}

	configData, protection, err := prepareWireGuardProtection(configData)
	if err != nil {
		fail(*readyPath, err.Error())
	}
	var firewall *wireGuardFirewall
	if protection != nil {
		firewall, err = installWireGuardProtection(protection)
		if err != nil {
			fail(*readyPath, "install WireGuard protection: "+err.Error())
		}
		defer func() {
			if err := firewall.close(); err != nil {
				log.Printf("close WireGuard protection: %v", err)
			}
		}()
	}

	engineInstance := engine.New()
	if err = engineInstance.Start(configData); err != nil {
		fail(*readyPath, "start: "+err.Error())
	}
	if firewall != nil {
		if err = firewall.allowTun(protection); err != nil {
			_ = engineInstance.Close()
			fail(*readyPath, "enable WireGuard TUN protection: "+err.Error())
		}
	}

	stop := make(chan struct{})
	server, err := engine.NewServer(engineInstance, *token, func() {
		_ = engineInstance.Close()
		close(stop)
	})
	if err != nil {
		_ = engineInstance.Close()
		fail(*readyPath, "listen control socket: "+err.Error())
	}
	go server.Serve()

	if err = engine.WriteReadyFile(*readyPath, engine.ReadyInfo{
		Port:      server.Port(),
		Token:     *token,
		PID:       os.Getpid(),
		StartedAt: time.Now().UnixMilli(),
		Mode:      *mode,
		Version:   version,
	}); err != nil {
		_ = engineInstance.Close()
		server.Close()
		fail(*readyPath, "write ready file: "+err.Error())
	}
	defer engine.RemoveFile(*readyPath)

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	lease := time.Duration(*leaseSecs) * time.Second
	for {
		select {
		case <-signals:
			_ = engineInstance.Close()
			server.Close()
			return
		case <-stop:
			return
		case <-ticker.C:
			if time.Since(server.LastActive()) > lease {
				log.Printf("control lease expired; shutting down")
				_ = engineInstance.Close()
				server.Close()
				return
			}
		}
	}
}

func readConfig(path string) ([]byte, error) {
	if path != "-" {
		return os.ReadFile(path)
	}
	const maxConfigSize = 32 << 20
	data, err := io.ReadAll(io.LimitReader(os.Stdin, maxConfigSize+1))
	if err == nil && len(data) > maxConfigSize {
		return nil, fmt.Errorf("configuration exceeds %d bytes", maxConfigSize)
	}
	return data, err
}

func fail(readyPath, message string) {
	if readyPath != "" {
		engine.WriteErrorFile(readyPath, message)
	}
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}
