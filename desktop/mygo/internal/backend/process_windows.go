//go:build windows

package backend

import (
	"context"
	"os/exec"
	"strconv"
	"time"
)

func configureProcess(cmd *exec.Cmd) {}

// Windows taskkill addresses the leader and its current descendants. Once the
// leader has exited there is no stable process-group identity to probe.
func processTreeAlive(pid int) bool { return false }

func requestProcessTreeStop(pid int) error { return killProcessTree(pid) }

func forceProcessTreeStop(pid int) error { return killProcessTree(pid) }

func killProcessTree(pid int) error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "taskkill", "/PID", strconv.Itoa(pid), "/T", "/F").Run()
}
