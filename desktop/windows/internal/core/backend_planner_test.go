package core

import (
	"reflect"
	"strings"
	"testing"
)

func TestLaunchEnvironment(t *testing.T) {
	inherited := map[string]string{
		"Path":                  `C:\Windows`,
		"HANDBEAN_FILE_MANAGER": "macos",
		"HANDBEAN_PUBLIC_BIND":  "1",
		"HANDBEAN_ALLOW_HTTP":   "1",
		"release_distribution":  "none",
		"release_node":          "unrelated@other-host",
		"release_cookie":        "unrelated-cookie",
		"erl_epmd_address":      "0.0.0.0",
		"erl_zflags":            "+S 2 -kernel inet_dist_use_interface {0,0,0,0}",
	}
	launch := Launch(`C:\Handbean\handbean-web`, 5008, "secret", "spawn-cookie", `C:\Users\a\.handbean\handbean.db`, `C:\Handbean\runtime`, inherited)
	env := launch.Environment
	checks := map[string]string{
		"PHX_SERVER":           "true",
		"PORT":                 "5008",
		"PHX_HOST":             "127.0.0.1",
		"DATABASE_PATH":        `C:\Users\a\.handbean\handbean.db`,
		"SECRET_KEY_BASE":      "secret",
		"RELEASE_TMP":          `C:\Handbean\runtime`,
		"HANDBEAN_RUNTIME_DIR": `C:\Handbean\runtime`,
		"RELEASE_DISTRIBUTION": "name",
		"RELEASE_NODE":         "handbean_gui_5008@127.0.0.1",
		"RELEASE_COOKIE":       "spawn-cookie",
		"ERL_EPMD_ADDRESS":     "127.0.0.1",
		"PATH":                 `C:\Windows`,
	}
	for key, want := range checks {
		if got := env[key]; got != want {
			t.Errorf("env[%s] = %q, want %q", key, got, want)
		}
	}
	for _, key := range []string{"HANDBEAN_FILE_MANAGER", "HANDBEAN_PUBLIC_BIND", "HANDBEAN_ALLOW_HTTP"} {
		if _, ok := env[key]; ok {
			t.Errorf("%s must be unset on Windows, got %q", key, env[key])
		}
	}
	for key := range env {
		if key != strings.ToUpper(key) {
			t.Errorf("duplicate case-insensitive environment key: %s", key)
		}
	}
	if !strings.HasPrefix(env["ERL_ZFLAGS"], inherited["erl_zflags"]) ||
		!strings.HasSuffix(env["ERL_ZFLAGS"], "-proto_dist inet_tcp -kernel inet_dist_use_interface {127,0,0,1}") {
		t.Errorf("loopback VM flags must follow inherited flags: %q", env["ERL_ZFLAGS"])
	}
	if inherited["release_distribution"] != "none" {
		t.Fatal("Launch mutated the caller's environment")
	}
	if launch.Executable != "cmd.exe" {
		t.Errorf("Executable = %q, want cmd.exe", launch.Executable)
	}
	if !reflect.DeepEqual(launch.Arguments, ReleaseArguments("start")) {
		t.Errorf("Arguments = %v", launch.Arguments)
	}
	if launch.WorkingDirectory != `C:\Handbean\handbean-web` {
		t.Errorf("WorkingDirectory = %q", launch.WorkingDirectory)
	}
	if launch.PageURL != "http://127.0.0.1:5008/" {
		t.Errorf("PageURL = %q", launch.PageURL)
	}
}

func TestLaunchIsolatesBackendNodes(t *testing.T) {
	first := Launch("release", 5008, "secret", "first-cookie", "db", "runtime", nil)
	second := Launch("release", 5009, "secret", "second-cookie", "db", "runtime", nil)
	if first.Environment["RELEASE_NODE"] == second.Environment["RELEASE_NODE"] {
		t.Fatal("different backend ports must have different RPC targets")
	}
	if first.Environment["RELEASE_COOKIE"] == second.Environment["RELEASE_COOKIE"] {
		t.Fatal("backend launches must retain their own RPC cookies")
	}
}
