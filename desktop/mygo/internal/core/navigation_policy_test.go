package core

import "testing"

func testOrigin() AppOrigin {
	return NewAppOrigin("http://127.0.0.1:5008/")
}

func TestNewAppOrigin(t *testing.T) {
	origin := NewAppOrigin("http://127.0.0.1:5008/")
	if origin.Port != 5008 {
		t.Fatalf("port = %d", origin.Port)
	}
	if !origin.Hosts["127.0.0.1"] || !origin.Hosts["localhost"] {
		t.Fatalf("loopback hosts missing: %v", origin.Hosts)
	}
}

func TestDecideSameOrigin(t *testing.T) {
	origin := testOrigin()
	for _, raw := range []string{
		"http://127.0.0.1:5008/",
		"http://127.0.0.1:5008/chat/123",
		"http://localhost:5008/settings",
		"ws://127.0.0.1:5008/live/websocket",
		"about:blank",
	} {
		if got := Decide(raw, origin, true); got != Allow {
			t.Errorf("Decide(%q, main) = %v, want Allow", raw, got)
		}
	}
}

func TestDecideExternalMainFrame(t *testing.T) {
	origin := testOrigin()
	for _, raw := range []string{
		"https://example.com/",
		"http://127.0.0.1:5009/", // different port, same host
		"http://localhost:5009/",
		"mailto:a@b.c",
		"tel:+123",
	} {
		if got := Decide(raw, origin, true); got != OpenExternally {
			t.Errorf("Decide(%q, main) = %v, want OpenExternally", raw, got)
		}
	}
}

func TestDecideExternalSubframe(t *testing.T) {
	origin := testOrigin()
	if got := Decide("https://example.com/", origin, false); got != Cancel {
		t.Errorf("subframe external = %v, want Cancel", got)
	}
	if got := Decide("wss://example.com/socket", origin, false); got != Cancel {
		t.Errorf("subframe ws external = %v, want Cancel", got)
	}
}

func TestDecideUnknownScheme(t *testing.T) {
	origin := testOrigin()
	for _, raw := range []string{"file:///etc/passwd", "javascript:alert(1)", "ftp://x/"} {
		if got := Decide(raw, origin, true); got != Cancel {
			t.Errorf("Decide(%q) = %v, want Cancel", raw, got)
		}
	}
}
