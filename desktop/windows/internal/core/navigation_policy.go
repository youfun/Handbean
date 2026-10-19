package core

import (
	"net/url"
	"strconv"
	"strings"
)

// AppOrigin is the set of hosts and the port the shell serves.
type AppOrigin struct {
	Hosts map[string]bool
	Port  int
}

// NewAppOrigin mirrors AppOrigin.init(pageURL:extraHosts:): the page's own
// host plus every loopback name.
func NewAppOrigin(pageURL string) AppOrigin {
	hosts := map[string]bool{}
	for host := range LoopbackHosts {
		hosts[host] = true
	}
	port := 80
	if u, err := url.Parse(pageURL); err == nil {
		if h := SanitizeHost(u.Hostname()); h != "" {
			hosts[h] = true
		}
		switch {
		case u.Port() != "":
			if p, err := strconv.Atoi(u.Port()); err == nil {
				port = p
			}
		case u.Scheme == "https":
			port = 443
		}
	}
	return AppOrigin{Hosts: hosts, Port: port}
}

// NavigationDecision is what the shell does with a navigation.
type NavigationDecision int

const (
	// Allow lets the web view navigate.
	Allow NavigationDecision = iota
	// OpenExternally cancels the navigation and opens the URL in the system
	// browser.
	OpenExternally
	// Cancel silently drops the navigation.
	Cancel
)

// Decide mirrors NavigationPolicy.decide. Main-frame http(s) outside the
// Handbean origin opens in the system browser; subframes outside that origin
// are cancelled so the shell cannot be steered into another site. LiveView
// preview is proxied on the same origin. WebView2 only raises page-level
// navigation events, so the shell always passes mainFrame=true.
func Decide(rawURL string, origin AppOrigin, mainFrame bool) NavigationDecision {
	u, err := url.Parse(rawURL)
	if err != nil {
		return Cancel
	}
	switch strings.ToLower(u.Scheme) {
	case "about":
		if rawURL == "about:blank" || u.Host == "" {
			return Allow
		}
		return Cancel
	case "http", "https":
		if isAppOrigin(u, origin) {
			return Allow
		}
		if mainFrame {
			return OpenExternally
		}
		return Cancel
	case "ws", "wss":
		if isAppOrigin(u, origin) {
			return Allow
		}
		return Cancel
	case "mailto", "tel":
		return OpenExternally
	default:
		return Cancel
	}
}

func isAppOrigin(u *url.URL, origin AppOrigin) bool {
	host := SanitizeHost(u.Hostname())
	if host == "" || !origin.Hosts[host] {
		return false
	}
	port := 80
	if u.Scheme == "https" || u.Scheme == "wss" {
		port = 443
	}
	if u.Port() != "" {
		if p, err := strconv.Atoi(u.Port()); err == nil {
			port = p
		}
	}
	return port == origin.Port
}
