//go:build linux

package backend

import (
	"os/exec"
	"testing"
)

func TestConfigureProcessOwnsLinuxProcessGroup(t *testing.T) {
	cmd := exec.Command("true")
	configureProcess(cmd)
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.Setpgid {
		t.Fatal("backend must start in its own process group")
	}
	if cmd.SysProcAttr.Pdeathsig == 0 {
		t.Fatal("backend must receive a parent-death signal")
	}
}

func TestSignalMissingProcessGroupIsAlreadyStopped(t *testing.T) {
	if err := forceProcessTreeStop(1 << 30); err != nil {
		t.Fatalf("missing process group should be treated as stopped: %v", err)
	}
}

func TestLinuxProcessStateHandlesCommandNameWithParenthesis(t *testing.T) {
	state, group, ok := linuxProcessState([]byte("123 (name with ) parenthesis) S 1 456 1 0"))
	if !ok || state != 'S' || group != 456 {
		t.Fatalf("state=%q group=%d ok=%v", state, group, ok)
	}
}
