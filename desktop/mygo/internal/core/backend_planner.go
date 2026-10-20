package core

import (
	"path/filepath"
	"runtime"
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

// Launch resolves the backend command for the current host platform.
func Launch(releaseRoot string, port int, secret, cookie, databasePath, runtimeDir string, inherited map[string]string) BackendLaunch {
	return LaunchForOS(runtime.GOOS, releaseRoot, port, secret, cookie, databasePath, runtimeDir, inherited)
}

// LaunchForOS resolves the platform command while keeping the environment and
// backend identity rules shared by the Windows and Linux shells.
func LaunchForOS(goos, releaseRoot string, port int, secret, cookie, databasePath, runtimeDir string, inherited map[string]string) BackendLaunch {
	env := map[string]string{}
	for key, value := range inherited {
		if goos == "windows" {
			key = strings.ToUpper(key)
		}
		env[key] = value
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
	inheritedZFlags := environmentValue(env, goos, "ERL_ZFLAGS")
	env["ERL_ZFLAGS"] = strings.TrimSpace(inheritedZFlags +
		" -proto_dist inet_tcp -kernel inet_dist_use_interface {127,0,0,1}")
	for key := range env {
		switch strings.ToUpper(key) {
		case "HANDBEAN_FILE_MANAGER", "HANDBEAN_PUBLIC_BIND", "HANDBEAN_ALLOW_HTTP":
			delete(env, key)
		}
	}
	return BackendLaunch{
		Executable:       ReleaseExecutableForOS(goos, releaseRoot),
		Arguments:        ReleaseArgumentsForOS(goos, "start"),
		Environment:      env,
		WorkingDirectory: releaseRoot,
		PageURL:          PageURL(port, true, ""),
	}
}

func environmentValue(env map[string]string, goos, name string) string {
	if goos == "windows" {
		return env[strings.ToUpper(name)]
	}
	return env[name]
}

// ReleaseLauncher is the bundled script whose presence proves a usable Web release.
func ReleaseLauncher(releaseRoot string) string {
	return ReleaseLauncherForOS(runtime.GOOS, releaseRoot)
}

// ReleaseLauncherForOS returns the platform release script.
func ReleaseLauncherForOS(goos, releaseRoot string) string {
	if goos == "windows" {
		return filepath.Join(releaseRoot, "bin", "handbean.bat")
	}
	return filepath.Join(releaseRoot, "bin", "handbean")
}

// ReleaseExecutableForOS returns the program used to invoke the release script.
func ReleaseExecutableForOS(goos, releaseRoot string) string {
	if goos == "windows" {
		return "cmd.exe"
	}
	return ReleaseLauncherForOS(goos, releaseRoot)
}

// ReleaseArguments returns the release action arguments for the current host.
func ReleaseArguments(action string) []string {
	return ReleaseArgumentsForOS(runtime.GOOS, action)
}

// ReleaseArgumentsForOS accepts only fixed release actions. Windows invokes the
// batch file through cmd.exe; Unix executes bin/handbean directly.
func ReleaseArgumentsForOS(goos, action string) []string {
	switch action {
	case "start", "stop":
	default:
		panic("unsupported release action: " + action)
	}
	if goos == "windows" {
		return []string{"/d", "/s", "/v:off", "/c", `bin\handbean.bat`, action}
	}
	return []string{action}
}
