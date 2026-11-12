package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// The desktop app starts the worker in userdata/runtime. Validate the paths
// that advanced and custom configuration can supply for log and cache writes.
func validateOutputPaths(config []byte, installDir string) error {
	var outputs struct {
		Log struct {
			Output string `json:"output"`
		} `json:"log"`
		Experimental struct {
			CacheFile struct {
				Path string `json:"path"`
			} `json:"cache_file"`
		} `json:"experimental"`
	}
	if err := json.Unmarshal(config, &outputs); err != nil {
		return errors.New("无法读取配置中的日志和缓存路径")
	}
	runtimeDir, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("读取核心工作目录: %w", err)
	}
	if installDir == "" {
		installDir = runtimeDir
	}
	for _, output := range []struct {
		field string
		path  string
	}{
		{"log.output", outputs.Log.Output},
		{"experimental.cache_file.path", outputs.Experimental.CacheFile.Path},
	} {
		if output.path == "" || (output.field == "log.output" &&
			(output.path == "stdout" || output.path == "stderr")) {
			continue
		}
		path := output.path
		if !filepath.IsAbs(path) {
			if filepath.VolumeName(path) != "" || strings.HasPrefix(path, string(filepath.Separator)) ||
				strings.HasPrefix(path, "/") {
				return fmt.Errorf("%s 必须指向安装目录内部", output.field)
			}
			path = filepath.Join(runtimeDir, path)
		}
		if !withinInstallDir(installDir, path) {
			return fmt.Errorf("%s 必须指向安装目录内部", output.field)
		}
	}
	return nil
}

func withinInstallDir(installDir, path string) bool {
	relative, err := filepath.Rel(installDir, path)
	if err != nil || relative == "." || !filepath.IsLocal(relative) ||
		strings.Contains(relative, ":") {
		return false
	}
	root, err := os.OpenRoot(installDir)
	if err != nil {
		return false
	}
	defer root.Close()
	// New files may not exist yet. Check every existing parent without
	// following links out of the installation directory.
	for relative != "." {
		if _, err = root.Stat(relative); err == nil {
			return true
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return false
		}
		if _, err = root.Lstat(relative); !errors.Is(err, fs.ErrNotExist) {
			return false
		}
		relative = filepath.Dir(relative)
	}
	return true
}
