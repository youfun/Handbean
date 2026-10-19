package core

import (
	"strconv"
	"strings"
)

// BackendLaunch is a fully resolved backend process, mirroring the Swift
// BackendLaunch value.
type BackendLaunch struct {
	Executable       string
	Arguments        []string
	Environment      map[string]string
	WorkingDirectory string
	PageURL          string
}

// Launch mirrors BackendPlanner.launch. The Windows release starts through
// cmd.exe, with the release root as working directory. A fixed relative batch
// path keeps the installation path out of cmd.exe's command language.
//
// The planner never claims a listener it did not spawn (mirroring
// BackendPlanner.claimsExistingListener): attachment only happens on a port
// the operator explicitly configured.
func Launch(releaseRoot string, port int, secret, cookie, databasePath, runtimeDir string, inherited map[string]string) BackendLaunch {
	env := map[string]string{}
	for key, value := range inherited {
		env[strings.ToUpper(key)] = value
	}
	overrides := map[string]string{
		"PHX_SERVER":           "true",
		"PORT":                 strconv.Itoa(port),
		"PHX_HOST":             "127.0.0.1",
		"DATABASE_PATH":        databasePath,
		"SECRET_KEY_BASE":      secret,
		"RELEASE_TMP":          runtimeDir,
		"HANDBEAN_RUNTIME_DIR": runtimeDir,
		"RELEASE_DISTRIBUTION": "name",
		"RELEASE_NODE":         "handbean_gui_" + strconv.Itoa(port) + "@127.0.0.1",
		"RELEASE_COOKIE":       cookie,
		"ERL_EPMD_ADDRESS":     "127.0.0.1",
	}
	for key, value := range overrides {
		env[key] = value
	}
	// ERL_ZFLAGS is parsed after the other VM arguments. Constrain the
	// distribution listener even if the caller supplied other Erlang flags.
	env["ERL_ZFLAGS"] = strings.TrimSpace(env["ERL_ZFLAGS"] +
		" -proto_dist inet_tcp -kernel inet_dist_use_interface {127,0,0,1}")
	// Drop inherited desktop/LAN knobs. The GUI always binds loopback;
	// the runtime only supports the macOS file-manager backend.
	for key := range env {
		switch strings.ToUpper(key) {
		case "HANDBEAN_FILE_MANAGER", "HANDBEAN_PUBLIC_BIND", "HANDBEAN_ALLOW_HTTP":
			delete(env, key)
		}
	}
	return BackendLaunch{
		Executable:       "cmd.exe",
		Arguments:        ReleaseArguments("start"),
		Environment:      env,
		WorkingDirectory: releaseRoot,
		PageURL:          PageURL(port, true, ""),
	}
}

// ReleaseArguments runs the release batch file without interpolating a path
// into shell syntax. Only the fixed release actions start and stop are accepted.
func ReleaseArguments(action string) []string {
	switch action {
	case "start", "stop":
		return []string{"/d", "/s", "/v:off", "/c", `bin\handbean.bat`, action}
	default:
		panic("unsupported release action: " + action)
	}
}
