// Handbean is the Windows desktop shell around the Handbean Web UI, mirroring
// desktop/macos. The window is a WebView2 pointed at the bundled Phoenix
// server. There is no Electron, Chromium, or CEF, and no address bar, tabs,
// or bookmarks.
package main

import (
	"log"
	"runtime"
	"sync"

	mygo "github.com/egoist/mygo"
	"github.com/youfun/Handbean/desktop/windows/internal/backend"
	"github.com/youfun/Handbean/desktop/windows/internal/shell"
)

func main() {
	if !mygo.App.RequestSingleInstanceLock() {
		return // the running instance takes over
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

	// A window showing a web page needs the WebView2 runtime on Windows;
	// Windows 11 includes it.
	missingWebView := runtime.GOOS == "windows" && !mygo.WebViewAvailable()

	var controller *backend.Controller
	var stopWG sync.WaitGroup
	mygo.App.WhenReady(func() {
		if missingWebView {
			go showMissingWebViewDialog()
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
		log.Fatal(err)
	}
}

func showMissingWebViewDialog() {
	res, _ := mygo.Dialog.Message(mygo.MessageOptions{
		Type:    mygo.MessageWarning,
		Title:   "Handbean",
		Message: "此应用需要 Microsoft Edge WebView2 运行时，Windows 11 已内置。",
		Detail:  "请安装 WebView2 Evergreen 运行时后重试。",
		Buttons: []string{"下载 WebView2", "退出"},
	})
	if res.Button == 0 {
		_ = mygo.Shell.OpenExternal("https://developer.microsoft.com/microsoft-edge/webview2/")
	}
	mygo.App.Quit()
}
