// Package backend owns the Phoenix server process, mirroring
// desktop/macos/Sources/Handbean/BackendController.swift. The shell process
// owns a backend only when it spawned that process in this lifetime; an
// attached server is never signalled on quit.
package backend

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/youfun/Handbean/desktop/mygo/internal/core"
	"github.com/youfun/Handbean/desktop/mygo/internal/shell"
)

// State is the backend lifecycle state the window reacts to.
type State int

const (
	Idle State = iota
	Starting
	Ready
	Failed
)

// errBootSuperseded is returned when spawn finishes after StopOwned or a
// newer Start has already taken over.
var errBootSuperseded = errors.New("boot superseded")

// Controller spawns, attaches to, probes, and stops the Phoenix server.
type Controller struct {
	mu sync.Mutex

	managedPort                    int
	allowsConfiguredPortAttachment bool
	port                           int

	state    State
	pageURL  string
	attached bool
	failure  string
	onChange func(state State, pageURL string, attached bool, failure string)

	cmd             *exec.Cmd
	exited          chan struct{}
	logFile         *os.File
	logPath         string
	intentionalStop bool
	generation      int
}

// NewController resolves the managed port: an explicit port wins, then
// HANDBEAN_PORT, then the stored preference, then a kernel-assigned free
// port, then the default.
func NewController(explicitPort int) *Controller {
	environmentPort := os.Getenv("HANDBEAN_PORT")
	resolved := explicitPort
	if resolved == 0 {
		resolved = core.PreferredPort(environmentPort, shell.StoredPort(), core.AvailableLoopbackPort)
	}
	return &Controller{
		managedPort:                    resolved,
		allowsConfiguredPortAttachment: explicitPort != 0 || core.HasExplicitPort(environmentPort),
		port:                           resolved,
	}
}

// OnChange registers the state listener. It is called from a backend
// goroutine; mygo calls made inside it hop to the main thread.
func (c *Controller) OnChange(fn func(state State, pageURL string, attached bool, failure string)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.onChange = fn
}

// Port is the port the backend serves or will serve.
func (c *Controller) Port() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.port
}

// LogInfo returns the backend log path and its tail, for the failure page.
func (c *Controller) LogInfo() (string, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.logPath, c.logTailLocked()
}

// Start begins boot on a goroutine.
func (c *Controller) Start() {
	c.mu.Lock()
	c.generation++
	generation := c.generation
	c.state = Starting
	c.intentionalStop = false
	fn := c.onChange
	c.mu.Unlock()
	if fn != nil {
		fn(Starting, "", false, "")
	}
	go c.boot(generation)
}

func (c *Controller) boot(generation int) {
	c.mu.Lock()
	running := c.cmd != nil
	c.mu.Unlock()
	if running {
		c.publishReady(generation, true)
		return
	}
	// Phase 1 does no storage-lock PID arbitration in the MyGo shell. An
	// explicitly configured port with a live Handbean server attaches;
	// anything else spawns, and a busy database surfaces as a backend boot
	// failure.
	if c.allowsConfiguredPortAttachment && Probe(c.port, 3*time.Second) {
		shell.Log(fmt.Sprintf("attaching to explicitly configured port %d", c.port))
		c.setReady(generation, core.PageURL(c.port, false, ""), true)
		return
	}
	if err := c.spawn(generation); err != nil {
		if errors.Is(err, errBootSuperseded) {
			return
		}
		c.fail(generation, fmt.Sprintf("无法启动本地服务：%v", err))
		return
	}
	c.publishReady(generation, true)
}

func (c *Controller) spawn(generation int) error {
	root, err := shell.ReleaseRoot()
	if err != nil {
		return err
	}
	launcher := core.ReleaseLauncher(root)
	info, err := os.Stat(launcher)
	if err != nil {
		return fmt.Errorf("找不到 Web 发行版（缺少 %s）。请先导入对应平台的 Web 发行版，或附加到已在运行的服务", launcher)
	}
	if runtime.GOOS != "windows" && info.Mode()&0o111 == 0 {
		return fmt.Errorf("Web 发行版启动程序不可执行：%s", launcher)
	}
	runtimeDir, err := shell.RuntimeDir()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(shell.DatabasePath()), 0o755); err != nil {
		return err
	}
	logDir, err := shell.LogDir()
	if err != nil {
		return err
	}
	secret, err := resolveSecret(shell.SecretPath())
	if err != nil {
		return err
	}
	database := os.Getenv("DATABASE_PATH")
	if database == "" {
		database = shell.DatabasePath()
	}
	cookie := make([]byte, 32)
	if _, err := rand.Read(cookie); err != nil {
		return err
	}
	launch := core.Launch(root, c.port, secret, hex.EncodeToString(cookie), database, runtimeDir, environMap())

	logPath := filepath.Join(logDir, "backend.log")
	rotateLogIfNeeded(logPath, 1<<20)
	handle, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	cmd := exec.Command(launch.Executable, launch.Arguments...)
	configureProcess(cmd)
	cmd.Env = envSlice(launch.Environment)
	cmd.Dir = launch.WorkingDirectory
	cmd.Stdout = handle
	cmd.Stderr = handle
	if err := cmd.Start(); err != nil {
		handle.Close()
		return err
	}
	exited := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(exited)
	}()
	c.mu.Lock()
	if c.intentionalStop || c.generation != generation {
		c.mu.Unlock()
		_ = forceProcessTreeStop(cmd.Process.Pid)
		<-exited
		handle.Close()
		return errBootSuperseded
	}
	c.cmd = cmd
	c.exited = exited
	c.logFile = handle
	c.logPath = logPath
	c.mu.Unlock()
	c.writePidFile(cmd.Process.Pid)
	shell.Log(fmt.Sprintf("spawned backend pid %d port %d", cmd.Process.Pid, c.port))
	go c.watchExit(exited)
	return nil
}

// watchExit mirrors the macOS termination handler: a backend that exits
// without the shell stopping it is a failure, unless a boot is superseded.
func (c *Controller) watchExit(exited chan struct{}) {
	<-exited
	c.mu.Lock()
	intentional := c.intentionalStop
	generation := c.generation
	c.mu.Unlock()
	if intentional {
		return
	}
	c.fail(generation, fmt.Sprintf("后端已退出。日志：%s", c.logPathValue()))
}

func (c *Controller) publishReady(generation int, spawned bool) {
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		if generation != c.generation {
			c.mu.Unlock()
			return
		}
		exited := c.exited
		c.mu.Unlock()
		if exited != nil {
			select {
			case <-exited:
				// watchExit reports the exit; do not also report a timeout.
				return
			default:
			}
		}
		if Probe(c.port, 2*time.Second) {
			c.setReady(generation, core.PageURL(c.port, spawned, ""), !spawned)
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
	c.fail(generation, fmt.Sprintf("本地服务没有在 %d 就绪。日志：%s\n\n%s", c.port, c.logPathValue(), c.logTailValue()))
}

// StopOwned gives the owned backend up to 8 seconds to stop through release
// RPC, including the stop command itself. Process-group escalation is bounded
// separately. An attached server is never signalled.
func (c *Controller) StopOwned() {
	c.mu.Lock()
	c.intentionalStop = true
	c.generation++
	cmd := c.cmd
	exited := c.exited
	c.mu.Unlock()
	if cmd == nil {
		c.closeLog()
		c.removePidFile()
		return
	}
	pid := cmd.Process.Pid
	if channelClosed(exited) {
		if finalizeOwnedProcessTree(pid, exited) {
			c.finishStop()
		} else {
			shell.Log("backend process tree remained after its leader exited; preserving PID file")
		}
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	// The node name, cookie and VM flags belong to this exact launch, not
	// the current host environment. cmd.Path is the resolved command interpreter.
	stop := exec.CommandContext(ctx, cmd.Path, core.ReleaseArguments("stop")...)
	configureProcess(stop)
	stop.Dir = cmd.Dir
	stop.Env = cmd.Env
	stop.Cancel = func() error {
		if err := forceProcessTreeStop(stop.Process.Pid); err != nil {
			return stop.Process.Kill()
		}
		return nil
	}
	stopErr := stop.Run()
	if stopErr != nil {
		shell.Log(fmt.Sprintf("backend stop command failed: %v", stopErr))
	} else {
		select {
		case <-exited:
			if finalizeOwnedProcessTree(pid, exited) {
				c.finishStop()
			} else {
				shell.Log("backend process tree remained after release stop; preserving PID file")
			}
			return
		case <-ctx.Done():
		}
	}

	if stopOwnedProcessTree(pid, exited) {
		c.finishStop()
		return
	}
	// Preserve the PID file when termination of either the leader or its
	// process group could not be confirmed.
	shell.Log("backend process-tree exit not confirmed after forced cleanup")
}

func stopOwnedProcessTree(pid int, exited <-chan struct{}) bool {
	if err := requestProcessTreeStop(pid); err != nil {
		shell.Log(fmt.Sprintf("backend graceful process-tree cleanup failed: %v", err))
	}
	if waitForOwnedProcessTreeExit(pid, exited, time.Second) {
		return true
	}
	if err := forceProcessTreeStop(pid); err != nil {
		shell.Log(fmt.Sprintf("backend forced process-tree cleanup failed: %v", err))
	}
	return waitForOwnedProcessTreeExit(pid, exited, 2*time.Second)
}

func finalizeOwnedProcessTree(pid int, exited <-chan struct{}) bool {
	if processTreeAlive(pid) {
		if err := forceProcessTreeStop(pid); err != nil {
			shell.Log(fmt.Sprintf("backend lingering process-tree cleanup failed: %v", err))
		}
	}
	return waitForOwnedProcessTreeExit(pid, exited, 2*time.Second)
}

func waitForOwnedProcessTreeExit(pid int, exited <-chan struct{}, timeout time.Duration) bool {
	leaderExited := channelClosed(exited)
	leaderExit := exited
	if leaderExited {
		leaderExit = nil
	}
	if leaderExited && !processTreeAlive(pid) {
		return true
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-leaderExit:
			leaderExited = true
			leaderExit = nil
			if !processTreeAlive(pid) {
				return true
			}
		case <-ticker.C:
			if leaderExited && !processTreeAlive(pid) {
				return true
			}
		case <-timer.C:
			return leaderExited && !processTreeAlive(pid)
		}
	}
}

func channelClosed(ch <-chan struct{}) bool {
	if ch == nil {
		return true
	}
	select {
	case <-ch:
		return true
	default:
		return false
	}
}

func (c *Controller) finishStop() {
	c.mu.Lock()
	c.cmd = nil
	c.exited = nil
	c.mu.Unlock()
	c.closeLog()
	c.removePidFile()
	shell.Log("stopped owned backend")
}

func (c *Controller) setReady(generation int, pageURL string, attached bool) {
	c.mu.Lock()
	if generation != c.generation {
		c.mu.Unlock()
		return
	}
	c.state = Ready
	c.pageURL = pageURL
	c.attached = attached
	fn := c.onChange
	c.mu.Unlock()
	if fn != nil {
		fn(Ready, pageURL, attached, "")
	}
}

func (c *Controller) fail(generation int, message string) {
	c.mu.Lock()
	if generation != c.generation || c.state == Failed {
		c.mu.Unlock()
		return
	}
	c.state = Failed
	c.failure = message
	fn := c.onChange
	c.mu.Unlock()
	if fn != nil {
		fn(Failed, "", false, message)
	}
}

func (c *Controller) closeLog() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.logFile != nil {
		_ = c.logFile.Close()
		c.logFile = nil
	}
}

func (c *Controller) logPathValue() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.logPath
}

func (c *Controller) logTailValue() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.logTailLocked()
}

func (c *Controller) logTailLocked() string {
	if c.logPath == "" {
		return ""
	}
	data, err := os.ReadFile(c.logPath)
	if err != nil {
		return ""
	}
	const max = 4096
	if len(data) > max {
		data = data[len(data)-max:]
	}
	return strings.TrimSpace(string(data))
}

func (c *Controller) writePidFile(pid int) {
	path, err := shell.PidPath()
	if err != nil {
		return
	}
	_ = os.WriteFile(path, []byte(strconv.Itoa(pid)+"\n"), 0o600)
}

func (c *Controller) removePidFile() {
	path, err := shell.PidPath()
	if err != nil {
		return
	}
	_ = os.Remove(path)
}

// Probe reports whether a Handbean server answers the health check on port.
func Probe(port int, timeout time.Duration) bool {
	client := &http.Client{Timeout: timeout}
	req, err := http.NewRequest(http.MethodGet, core.HealthURL(port), nil)
	if err != nil {
		return false
	}
	req.Header.Set("Cache-Control", "no-cache")
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil {
		return false
	}
	return string(body) == core.HealthResponse
}

// resolveSecret mirrors the macOS shell: SECRET_KEY_BASE from the environment
// wins; otherwise the key is read from ~/.handbean/secret_key_base, created on
// first use, so cookies survive restarts.
func resolveSecret(path string) (string, error) {
	if secret := os.Getenv("SECRET_KEY_BASE"); secret != "" {
		return secret, nil
	}
	if data, err := os.ReadFile(path); err == nil {
		if secret := strings.TrimSpace(string(data)); secret != "" {
			return secret, nil
		}
	}
	random := make([]byte, 48)
	if _, err := rand.Read(random); err != nil {
		return "", err
	}
	secret := base64.StdEncoding.EncodeToString(random)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	// 0o600 is the Unix mode the macOS shell uses. On Windows it does not
	// replace the parent directory DACL; keep the file in ~/.handbean.
	if err := os.WriteFile(path, []byte(secret+"\n"), 0o600); err != nil {
		return "", err
	}
	return secret, nil
}

func rotateLogIfNeeded(path string, maxBytes int64) {
	info, err := os.Stat(path)
	if err != nil || info.Size() < maxBytes {
		return
	}
	_ = os.Rename(path, path+".old")
}

func environMap() map[string]string {
	env := map[string]string{}
	for _, pair := range os.Environ() {
		key, value, _ := strings.Cut(pair, "=")
		env[key] = value
	}
	return env
}

func envSlice(env map[string]string) []string {
	pairs := make([]string, 0, len(env))
	for key, value := range env {
		pairs = append(pairs, key+"="+value)
	}
	return pairs
}
