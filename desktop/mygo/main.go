// Handbean is the MyGo desktop shell around the Handbean Web UI. Windows uses
// the system WebView2 runtime; Linux uses GTK 3 and WebKitGTK 4.1. The bundled
// Phoenix release owns application behavior while this process owns the native
// window and backend lifecycle.
package main

import (
	"fmt"
	"log"
	"runtime"
	"sync"

	mygo "github.com/egoist/mygo"
	"github.com/youfun/Handbean/desktop/mygo/internal/backend"
	"github.com/youfun/Handbean/desktop/mygo/internal/shell"
)

func main() {
	if !mygo.App.RequestSingleInstanceLock() {
		return
	}
	var mu sync.Mutex
	var mainWindow *mygo.Window
	mygo.App.OnSecondInstance(func(args []string, workingDir string) {
		mu.Lock()
		win := mainWindow
		mu.Unlock()
		if win != nil {
			win.Restore()
			win.Focus()
		}
	})

	missingWebView := (runtime.GOOS == "windows" || runtime.GOOS == "linux") && !mygo.WebViewAvailable()
	var controller *backend.Controller
	var stopWG sync.WaitGroup
	mygo.App.WhenReady(func() {
		if missingWebView {
			go showMissingWebViewDialog(runtime.GOOS)
			return
		}
		host := shell.NewHostWindow()
		mu.Lock()
		mainWindow = host.Win
		mu.Unlock()
		controller = backend.NewController(0)
		controller.OnChange(func(state backend.State, pageURL string, attached bool, failure string) {
			switch state {
			case backend.Starting:
				host.ShowStarting()
			case backend.Ready:
				host.LoadApp(pageURL, attached)
			case backend.Failed:
				logPath, logTail := controller.LogInfo()
				host.ShowError(failure, logPath, logTail)
			}
		})
		controller.Start()
	})
	mygo.App.OnWillQuit(func(e *mygo.QuitEvent) {
		if controller != nil {
			stopWG.Add(1)
			go func() {
				defer stopWG.Done()
				controller.StopOwned()
			}()
		}
	})
	mygo.App.OnQuit(func() { stopWG.Wait() })
	if err := mygo.App.Run(); err != nil {
		log.Fatal(appRunError(err, runtime.GOOS))
	}
}

func appRunError(err error, goos string) error {
	if err == nil || goos != "linux" {
		return err
	}
	return fmt.Errorf("%w\n\nHandbean on Linux requires GTK 3 and WebKitGTK 4.1. On Debian/Ubuntu install libgtk-3-0 (or libgtk-3-0t64) and libwebkit2gtk-4.1-0", err)
}

func missingWebViewOptions(goos string) mygo.MessageOptions {
	if goos == "linux" {
		return mygo.MessageOptions{
			Type:    mygo.MessageWarning,
			Title:   "Handbean",
			Message: "此应用需要 GTK 3 和 WebKitGTK 4.1。",
			Detail:  "Debian/Ubuntu 请安装 libgtk-3-0（新版本可能为 libgtk-3-0t64）和 libwebkit2gtk-4.1-0 后重试。",
			Buttons: []string{"退出"},
		}
	}
	return mygo.MessageOptions{
		Type:    mygo.MessageWarning,
		Title:   "Handbean",
		Message: "此应用需要 Microsoft Edge WebView2 运行时，Windows 11 已内置。",
		Detail:  "请安装 WebView2 Evergreen 运行时后重试。",
		Buttons: []string{"下载 WebView2", "退出"},
	}
}

func showMissingWebViewDialog(goos string) {
	res, _ := mygo.Dialog.Message(missingWebViewOptions(goos))
	if goos == "windows" && res.Button == 0 {
		_ = mygo.Shell.OpenExternal("https://developer.microsoft.com/microsoft-edge/webview2/")
	}
	mygo.App.Quit()
}
