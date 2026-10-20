package core

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestReleaseBatchExecution(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Handbean & release with spaces")
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	batch := "@echo off\r\necho action=%1 node=%RELEASE_NODE% cookie=%RELEASE_COOKIE%\r\nexit /b %BATCH_EXIT%\r\n"
	if err := os.WriteFile(filepath.Join(root, "bin", "handbean.bat"), []byte(batch), 0o600); err != nil {
		t.Fatal(err)
	}
	inherited := map[string]string{}
	for _, pair := range os.Environ() {
		key, value, _ := strings.Cut(pair, "=")
		inherited[key] = value
	}
	launch := Launch(root, 51234, "test-secret", "test-cookie", "db", "runtime", inherited)
	for _, action := range []string{"start", "stop"} {
		for _, exit := range []string{"0", "7"} {
			t.Run(action+"/exit="+exit, func(t *testing.T) {
				command := exec.Command(launch.Executable, ReleaseArguments(action)...)
				command.Dir = launch.WorkingDirectory
				for key, value := range launch.Environment {
					if key != "BATCH_EXIT" {
						command.Env = append(command.Env, key+"="+value)
					}
				}
				command.Env = append(command.Env, "BATCH_EXIT="+exit)
				output, err := command.CombinedOutput()
				if exit == "0" {
					if err != nil {
						t.Fatalf("batch failed: %v\n%s", err, output)
					}
				} else {
					var exitErr *exec.ExitError
					if !errors.As(err, &exitErr) || exitErr.ExitCode() != 7 {
						t.Fatalf("batch exit code lost: %v\n%s", err, output)
					}
				}
				want := "action=" + action + " node=handbean_gui_51234@127.0.0.1 cookie=test-cookie"
				if !strings.Contains(string(output), want) {
					t.Fatalf("batch did not receive launch environment: %s", output)
				}
			})
		}
	}
}
