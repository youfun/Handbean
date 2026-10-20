//go:build linux

package backend

import (
	"errors"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

func configureProcess(cmd *exec.Cmd) {
	// Give the owned OTP release its own process group. Pdeathsig prevents a
	// shell crash from leaving the direct BEAM child behind; bounded shutdown
	// still addresses the group so descendants cannot escape normal cleanup.
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setpgid:   true,
		Pdeathsig: syscall.SIGTERM,
	}
}

func processTreeAlive(pid int) bool {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return processGroupExists(pid)
	}
	unknownMember := false
	for _, entry := range entries {
		processID, err := strconv.Atoi(entry.Name())
		if err != nil || processID <= 0 {
			continue
		}
		data, err := os.ReadFile("/proc/" + entry.Name() + "/stat")
		if err != nil {
			if !errors.Is(err, os.ErrNotExist) {
				unknownMember = true
			}
			continue
		}
		state, processGroup, ok := linuxProcessState(data)
		if ok && processGroup == pid && state != 'Z' && state != 'X' {
			return true
		}
	}
	// kill(2) reports zombie-only groups as present. Use it only when procfs did
	// not let us inspect every possible member, preferring a conservative result.
	return unknownMember && processGroupExists(pid)
}

func linuxProcessState(stat []byte) (byte, int, bool) {
	closeName := strings.LastIndexByte(string(stat), ')')
	if closeName == -1 || closeName+2 >= len(stat) {
		return 0, 0, false
	}
	fields := strings.Fields(string(stat[closeName+1:]))
	if len(fields) < 3 || len(fields[0]) != 1 {
		return 0, 0, false
	}
	processGroup, err := strconv.Atoi(fields[2])
	if err != nil {
		return 0, 0, false
	}
	return fields[0][0], processGroup, true
}

func processGroupExists(pid int) bool {
	err := syscall.Kill(-pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func requestProcessTreeStop(pid int) error {
	return signalProcessGroup(pid, syscall.SIGTERM)
}

func forceProcessTreeStop(pid int) error {
	return signalProcessGroup(pid, syscall.SIGKILL)
}

func signalProcessGroup(pid int, signal syscall.Signal) error {
	err := syscall.Kill(-pid, signal)
	if errors.Is(err, syscall.ESRCH) {
		return nil
	}
	return err
}
