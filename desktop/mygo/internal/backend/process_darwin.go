//go:build darwin

package backend

import (
	"os"
	"os/exec"
)

// Darwin is supported for development tests only; the production macOS shell
// remains the native Swift/WebKit application.
func configureProcess(cmd *exec.Cmd) {}

func processTreeAlive(pid int) bool { return false }

func requestProcessTreeStop(pid int) error { return killProcess(pid) }

func forceProcessTreeStop(pid int) error { return killProcess(pid) }

func killProcess(pid int) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Kill()
}
