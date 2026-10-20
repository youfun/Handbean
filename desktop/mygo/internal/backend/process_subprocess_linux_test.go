//go:build linux

package backend

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"
)

func TestFinalizeOwnedProcessTreeKillsDescendantAfterLeaderExits(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=TestOwnedProcessTreeHelper")
	cmd.Env = append(os.Environ(), "HANDBEAN_PROCESS_TREE_HELPER=1")
	configureProcess(cmd)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	leaderPID := cmd.Process.Pid
	defer func() { _ = forceProcessTreeStop(leaderPID) }()

	scanner := bufio.NewScanner(stdout)
	if !scanner.Scan() {
		t.Fatalf("helper did not report descendant PID: %v", scanner.Err())
	}
	descendantPID, err := strconv.Atoi(scanner.Text())
	if err != nil {
		t.Fatalf("invalid descendant PID %q: %v", scanner.Text(), err)
	}

	exited := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(exited)
	}()
	if err := requestProcessTreeStop(leaderPID); err != nil {
		t.Fatalf("send SIGTERM: %v", err)
	}
	select {
	case <-exited:
	case <-time.After(2 * time.Second):
		t.Fatal("process-group leader did not exit after SIGTERM")
	}
	if !linuxProcessRunning(descendantPID) {
		t.Fatal("test descendant did not ignore SIGTERM")
	}

	if !finalizeOwnedProcessTree(leaderPID, exited) {
		t.Fatal("lingering descendant was not removed")
	}
	if linuxProcessRunning(descendantPID) {
		t.Fatal("descendant is still running after forced process-tree cleanup")
	}
}

func TestOwnedProcessTreeHelper(t *testing.T) {
	if os.Getenv("HANDBEAN_PROCESS_TREE_HELPER") != "1" {
		return
	}
	child := exec.Command("sh", "-c", "trap '' TERM; echo ready; exec sleep 300")
	ready, err := child.StdoutPipe()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if err := child.Start(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	readyScanner := bufio.NewScanner(ready)
	if !readyScanner.Scan() || readyScanner.Text() != "ready" {
		fmt.Fprintln(os.Stderr, "descendant did not become ready")
		os.Exit(2)
	}
	fmt.Println(child.Process.Pid)
	for {
		time.Sleep(time.Hour)
	}
}

func linuxProcessRunning(pid int) bool {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return false
	}
	state, _, ok := linuxProcessState(data)
	return ok && state != 'Z' && state != 'X'
}
