package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestValidateOutputPaths(t *testing.T) {
	root := t.TempDir()
	runtimeDir := filepath.Join(root, "runtime")
	if err := os.Mkdir(runtimeDir, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Chdir(runtimeDir)

	for _, tc := range []struct {
		name    string
		config  string
		allowed bool
	}{
		{"defaults", "{}", true},
		{"console", `{"log":{"output":"stdout"}}`, true},
		{"local outputs", `{"log":{"output":"logs/local.log"},"experimental":{"cache_file":{"path":"cache.db"}}}`, true},
		{"inside installation", `{"log":{"output":"../local.log"}}`, true},
		{"external log", `{"log":{"output":"../../outside.log"}}`, false},
		{"external cache", `{"experimental":{"cache_file":{"path":"../../outside.db"}}}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := validateOutputPaths([]byte(tc.config), root); (err == nil) != tc.allowed {
				t.Fatalf("allowed = %v, got %v", tc.allowed, err)
			}
		})
	}

	if !withinInstallDir(runtimeDir, filepath.Join(runtimeDir, "core.log")) {
		t.Error("absolute path inside runtime should be allowed")
	}
	if withinInstallDir(runtimeDir, filepath.Join(root, "outside.log")) {
		t.Error("absolute path outside runtime should be rejected")
	}
}

func TestRuntimePathRejectsSymlinkOutside(t *testing.T) {
	runtimeDir := t.TempDir()
	link := filepath.Join(runtimeDir, "redirect")
	if err := os.Symlink(t.TempDir(), link); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	if withinInstallDir(runtimeDir, filepath.Join(link, "outside.log")) {
		t.Error("symlink to an external directory should be rejected")
	}
}
