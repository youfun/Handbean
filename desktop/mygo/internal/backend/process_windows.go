//go:build windows

package backend

import (
	"context"
	"os/exec"
	"strconv"
	"syscall"
	"time"
)

const createNoWindow = 0x08000000

func configureProcess(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow,
	}
}

// Windows taskkill addresses the leader and its current descendants. Once the
// leader has exited there is no stable process-group identity to probe.
func processTreeAlive(pid int) bool { return false }

func requestProcessTreeStop(pid int) error { return killProcessTree(pid) }

func forceProcessTreeStop(pid int) error { return killProcessTree(pid) }

func killProcessTree(pid int) error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "taskkill", "/PID", strconv.Itoa(pid), "/T", "/F")
	configureProcess(cmd)
	return cmd.Run()
}
