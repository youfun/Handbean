// Package core holds the pure port, URL, and launch decisions of the Windows
// shell, mirroring desktop/macos/Sources/HandbeanCore. It does not depend on
// mygo, so every rule is unit-testable.
package core

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

// DefaultPort matches the Web UI release default (scripts/start.sh).
const DefaultPort = 5008

// BundleIdentifier matches the macOS shell.
const BundleIdentifier = "com.youfun.handbean"

// HealthPath and HealthResponse match the Phoenix side
// (HandbeanWeb.Router: get "/desktop-health", DesktopHealthController).
const (
	HealthPath     = "/desktop-health"
	HealthResponse = "handbean-desktop-health:v1"
)

// LoopbackHosts are the only hosts a discovered backend may be attached at.
// Other listeners (for example Erlang distribution on all interfaces) must
// never become desktop attachment candidates.
var LoopbackHosts = map[string]bool{
	"127.0.0.1": true,
	"localhost": true,
	"::1":       true,
	"[::1]":     true,
}

// HealthURL is the readiness probe the shell polls before loading the page.
func HealthURL(port int) string {
	return fmt.Sprintf("http://127.0.0.1:%d%s", port, HealthPath)
}

// PageURL mirrors DesktopConfig.pageURL: a server the shell spawned is
// addressed at 127.0.0.1 so the page host matches PHX_HOST and does not depend
// on localhost resolving to ::1. An attached server keeps its discovered
// loopback host, defaulting to localhost.
func PageURL(port int, spawnedByApp bool, discoveredHost string) string {
	host := "localhost"
	if spawnedByApp {
		host = "127.0.0.1"
	} else if h := SanitizeHost(discoveredHost); h != "" {
		host = h
	}
	return fmt.Sprintf("http://%s:%d/", host, port)
}

// SanitizeHost returns the host when it is a loopback name, else "".
func SanitizeHost(raw string) string {
	host := strings.ToLower(strings.TrimSpace(raw))
	host = strings.TrimPrefix(host, "[")
	host = strings.TrimSuffix(host, "]")
	if host == "" || !LoopbackHosts[host] {
		return ""
	}
	return host
}

// HasExplicitPort reports whether raw names a usable TCP port.
func HasExplicitPort(raw string) bool {
	port, err := strconv.Atoi(strings.TrimSpace(raw))
	return err == nil && port >= 1 && port <= 65535
}

// PreferredPort mirrors DesktopConfig.preferredPort: the environment wins
// over the stored preference, which wins over a kernel-assigned free port,
// which wins over the default.
func PreferredPort(environment, stored string, availablePort func() int) int {
	for _, raw := range []string{environment, stored} {
		if HasExplicitPort(raw) {
			port, _ := strconv.Atoi(strings.TrimSpace(raw))
			return port
		}
	}
	if port := availablePort(); port > 0 {
		return port
	}
	return DefaultPort
}

// AvailableLoopbackPort asks the kernel for an unused loopback port. The
// listener is closed before the backend starts, so callers must still handle
// the unlikely bind race.
func AvailableLoopbackPort() int {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

// StorageLockPath mirrors DesktopConfig.storageLockPath: the runtime holds an
// OS lock on a sidecar belonging to the resolved database path.
func StorageLockPath(databasePath string) string {
	return databasePath + ".lock"
}
