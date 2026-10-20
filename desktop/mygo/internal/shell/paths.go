// Package shell holds the Windows shell's paths, logging, and window.
package shell

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	mygo "github.com/egoist/mygo"
)

// ReleaseRoot is the bundled Web UI release: resources/handbean-web next to
// the executable in a package, the project's resources directory under
// go run and go test.
func ReleaseRoot() (string, error) {
	dir, err := mygo.App.Path(mygo.PathResources)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "handbean-web"), nil
}

// LogDir is where backend.log and shell.log live.
func LogDir() (string, error) {
	dir, err := mygo.App.Path(mygo.PathLogs)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

// UserDataDir is the per-user data directory (%AppData%\Handbean).
func UserDataDir() (string, error) {
	dir, err := mygo.App.Path(mygo.PathUserData)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

// RuntimeDir is RELEASE_TMP / HANDBEAN_RUNTIME_DIR for the spawned backend.
func RuntimeDir() (string, error) {
	dir, err := UserDataDir()
	if err != nil {
		return "", err
	}
	runtimeDir := filepath.Join(dir, "runtime")
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		return "", err
	}
	return runtimeDir, nil
}

// DatabasePath is the shared session database, the same default as the release
// (scripts/start.sh): ~/.handbean/handbean.db.
func DatabasePath() string {
	if v := os.Getenv("DATABASE_PATH"); v != "" {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "handbean.db"
	}
	return filepath.Join(home, ".handbean", "handbean.db")
}

// SecretPath is the persisted SECRET_KEY_BASE, so cookies survive restarts.
func SecretPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "secret_key_base"
	}
	return filepath.Join(home, ".handbean", "secret_key_base")
}

// PidPath records the backend PID, written only for a server this app spawned.
func PidPath() (string, error) {
	dir, err := UserDataDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "backend.pid"), nil
}

// StoredPort is the persisted port preference (config.json in the user data
// directory), the Windows counterpart of the macOS UserDefaults HandbeanPort.
func StoredPort() string {
	dir, err := UserDataDir()
	if err != nil {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(dir, "config.json"))
	if err != nil {
		return ""
	}
	var config struct {
		Port int `json:"port"`
	}
	if err := json.Unmarshal(data, &config); err != nil {
		return ""
	}
	if config.Port >= 1 && config.Port <= 65535 {
		return strconv.Itoa(config.Port)
	}
	return ""
}

// Log appends a line to shell.log in the log directory.
func Log(message string) {
	dir, err := mygo.App.Path(mygo.PathLogs)
	if err != nil {
		return
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	handle, err := os.OpenFile(filepath.Join(dir, "shell.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer handle.Close()
	fmt.Fprintf(handle, "%s %s\n", time.Now().Format(time.RFC3339), message)
}
