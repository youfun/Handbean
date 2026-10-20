//go:build linux

package core

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestLinuxLaunch(t *testing.T) {
	root := filepath.Join("/opt", "Handbean release")
	launch := LaunchForOS("linux", root, 5008, "secret", "cookie", "/data/handbean.db", "/run/user/1000/handbean", map[string]string{"PATH": "/usr/bin"})
	wantExecutable := filepath.Join(root, "bin", "handbean")
	if launch.Executable != wantExecutable {
		t.Fatalf("Executable = %q, want %q", launch.Executable, wantExecutable)
	}
	if !reflect.DeepEqual(launch.Arguments, []string{"start"}) {
		t.Fatalf("Arguments = %v", launch.Arguments)
	}
	if launch.Environment["PATH"] != "/usr/bin" {
		t.Fatalf("PATH = %q", launch.Environment["PATH"])
	}
}

func TestReleaseLauncherPaths(t *testing.T) {
	root := filepath.Join("root", "with spaces")
	if got := ReleaseLauncherForOS("linux", root); got != filepath.Join(root, "bin", "handbean") {
		t.Fatalf("Linux launcher = %q", got)
	}
	if got := ReleaseLauncherForOS("windows", root); got != filepath.Join(root, "bin", "handbean.bat") {
		t.Fatalf("Windows launcher = %q", got)
	}
}

func TestReleaseScriptExecution(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Handbean release with spaces")
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nprintf 'action=%s node=%s cookie=%s\\n' \"$1\" \"$RELEASE_NODE\" \"$RELEASE_COOKIE\"\nexit \"${RELEASE_EXIT:-0}\"\n"
	launcher := filepath.Join(root, "bin", "handbean")
	if err := os.WriteFile(launcher, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	launch := LaunchForOS("linux", root, 51234, "test-secret", "test-cookie", "db", "runtime", environ())
	for _, action := range []string{"start", "stop"} {
		for _, exit := range []string{"0", "7"} {
			t.Run(action+"/exit="+exit, func(t *testing.T) {
				command := exec.Command(launch.Executable, ReleaseArgumentsForOS("linux", action)...)
				command.Dir = launch.WorkingDirectory
				command.Env = envSliceForTest(launch.Environment, "RELEASE_EXIT", exit)
				output, err := command.CombinedOutput()
				if exit == "0" {
					if err != nil {
						t.Fatalf("script failed: %v\n%s", err, output)
					}
				} else {
					var exitErr *exec.ExitError
					if !errors.As(err, &exitErr) || exitErr.ExitCode() != 7 {
						t.Fatalf("script exit code lost: %v\n%s", err, output)
					}
				}
				want := "action=" + action + " node=handbean_gui_51234@127.0.0.1 cookie=test-cookie"
				if !strings.Contains(string(output), want) {
					t.Fatalf("script did not receive launch environment: %s", output)
				}
			})
		}
	}
}

func environ() map[string]string {
	env := map[string]string{}
	for _, pair := range os.Environ() {
		key, value, _ := strings.Cut(pair, "=")
		env[key] = value
	}
	return env
}

func envSliceForTest(env map[string]string, key, value string) []string {
	pairs := make([]string, 0, len(env)+1)
	for name, item := range env {
		if name != key {
			pairs = append(pairs, name+"="+item)
		}
	}
	return append(pairs, key+"="+value)
}
