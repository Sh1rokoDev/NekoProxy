package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type ReadyInfo struct {
	Port      int    `json:"port"`
	Token     string `json:"token"`
	PID       int    `json:"pid"`
	StartedAt int64  `json:"startedAt"`
	Mode      string `json:"mode"`
	Version   string `json:"version"`
}

func WriteReadyFile(path string, info ReadyInfo) error {
	data, err := json.MarshalIndent(info, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(path, data)
}

func WriteErrorFile(readyPath, message string) {
	_ = atomicWrite(readyPath+".error", []byte(message))
}

func atomicWrite(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".nekoproxy-*.tmp")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer os.Remove(name)
	if _, err = temp.Write(data); err != nil {
		_ = temp.Close()
		return err
	}
	if err = temp.Sync(); err != nil {
		_ = temp.Close()
		return err
	}
	if err = temp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

func RemoveFile(path string) {
	_ = os.Remove(path)
	_ = os.Remove(path + ".error")
}
