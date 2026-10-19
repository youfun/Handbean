package shell

import (
	"fmt"
	"strings"

	mygo "github.com/egoist/mygo"
	"github.com/youfun/Handbean/desktop/windows/internal/core"
)

// HostWindow is the single shell window: starting overlay, app page, or
// failure notice. Navigation policy is wired once; the origin updates
// when the backend URL is known.
type HostWindow struct {
	Win    *mygo.Window
	origin core.AppOrigin
}

// NewHostWindow creates the shell window on a starting page so boot is
// not a 60-second blank frame.
func NewHostWindow() *HostWindow {
	h := &HostWindow{origin: core.NewAppOrigin("about:blank")}
	h.Win = mygo.NewWindow(mygo.WindowOptions{
		Title:           "Handbean",
		Width:           1200,
		Height:          800,
		MinWidth:        600,
		MinHeight:       400,
		StateKey:        "main",
		BackgroundColor: "#1e1e1e",
		Page:            mygo.PageOptions{DevTools: mygo.DevToolsAuto},
	})
	h.Win.Page().OnWillNavigate(func(e *mygo.NavigateEvent) {
		switch core.Decide(e.URL, h.origin, true) {
		case core.Allow:
		case core.OpenExternally:
			e.PreventDefault()
			go func() { _ = mygo.Shell.OpenExternal(e.URL) }()
		case core.Cancel:
			e.PreventDefault()
		}
	})
	// Links with target="_blank" and window.open() keep the default handler:
	// http(s) URLs open in the system browser, anything else is denied.
	h.ShowStarting()
	return h
}

// ShowStarting replaces the page with a boot notice.
func (h *HostWindow) ShowStarting() {
	h.origin = core.NewAppOrigin("about:blank")
	h.Win.SetTitle("Handbean")
	h.Win.Page().LoadHTML(`<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>Handbean</title>
<style>
body { font-family: system-ui, sans-serif; margin: 40px auto; max-width: 720px; color: #d4d4d4; background: #1e1e1e; }
h1 { font-size: 20px; }
</style></head>
<body>
<h1>正在启动 Handbean…</h1>
<p>正在选择回环端口并启动本地服务。</p>
</body></html>`, "about:blank")
}

// LoadApp navigates to the ready backend. attached is true only when this
// process did not spawn the server.
func (h *HostWindow) LoadApp(pageURL string, attached bool) {
	h.origin = core.NewAppOrigin(pageURL)
	if attached {
		h.Win.Page().OnPageTitleUpdated(func(e *mygo.TitleEvent) { e.PreventDefault() })
		h.Win.SetTitle("Handbean — 已附著")
	} else {
		h.Win.SetTitle("Handbean")
	}
	if err := h.Win.Page().LoadURL(pageURL); err != nil {
		Log(fmt.Sprintf("load app URL: %v", err))
		h.ShowError(fmt.Sprintf("无法打开 %s：%v", pageURL, err), "", "")
	}
}

// ShowError replaces the page with a failure notice, mirroring the macOS
// shell's failed state. The base URL is about:blank so the navigation
// policy does not treat the notice as an off-origin http page.
func (h *HostWindow) ShowError(message, logPath, logTail string) {
	h.origin = core.NewAppOrigin("about:blank")
	h.Win.SetTitle("Handbean — 启动失败")
	detail := ""
	if logTail != "" {
		detail = "<pre>" + htmlEscape(logTail) + "</pre>"
	}
	h.Win.Page().LoadHTML(fmt.Sprintf(`<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>Handbean — 启动失败</title>
<style>
body { font-family: system-ui, sans-serif; margin: 40px auto; max-width: 720px; color: #d4d4d4; background: #1e1e1e; }
h1 { font-size: 20px; }
pre { background: #111; padding: 12px; overflow: auto; font-size: 12px; }
code { background: #111; padding: 2px 4px; }
</style></head>
<body>
<h1>Handbean 启动失败</h1>
<p>%s</p>
<p>日志：<code>%s</code></p>
%s
</body></html>`, htmlEscape(message), htmlEscape(logPath), detail), "about:blank")
}

func htmlEscape(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&#34;")
	return r.Replace(s)
}
