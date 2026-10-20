package core

import "testing"

func TestHealthURL(t *testing.T) {
	if got := HealthURL(5008); got != "http://127.0.0.1:5008/desktop-health" {
		t.Fatalf("HealthURL = %q", got)
	}
}

func TestPageURL(t *testing.T) {
	if got := PageURL(5008, true, ""); got != "http://127.0.0.1:5008/" {
		t.Fatalf("spawned PageURL = %q", got)
	}
	if got := PageURL(5008, false, ""); got != "http://localhost:5008/" {
		t.Fatalf("attached default PageURL = %q", got)
	}
	if got := PageURL(5008, false, "127.0.0.1"); got != "http://127.0.0.1:5008/" {
		t.Fatalf("attached discovered PageURL = %q", got)
	}
	if got := PageURL(5008, false, "evil.example.com"); got != "http://localhost:5008/" {
		t.Fatalf("non-loopback host must be ignored, got %q", got)
	}
}

func TestSanitizeHost(t *testing.T) {
	cases := map[string]string{
		"127.0.0.1":   "127.0.0.1",
		"LOCALHOST":   "localhost",
		" [::1] ":     "::1",
		"example.com": "",
		"":            "",
		"192.168.1.2": "",
	}
	for raw, want := range cases {
		if got := SanitizeHost(raw); got != want {
			t.Errorf("SanitizeHost(%q) = %q, want %q", raw, got, want)
		}
	}
}

func TestHasExplicitPort(t *testing.T) {
	for _, raw := range []string{"5008", " 5008 ", "1", "65535"} {
		if !HasExplicitPort(raw) {
			t.Errorf("HasExplicitPort(%q) = false, want true", raw)
		}
	}
	for _, raw := range []string{"", "0", "65536", "-1", "abc"} {
		if HasExplicitPort(raw) {
			t.Errorf("HasExplicitPort(%q) = true, want false", raw)
		}
	}
}

func TestPreferredPort(t *testing.T) {
	if got := PreferredPort("6001", "6002", func() int { return 6003 }); got != 6001 {
		t.Fatalf("environment must win, got %d", got)
	}
	if got := PreferredPort("", "6002", func() int { return 6003 }); got != 6002 {
		t.Fatalf("stored must beat kernel port, got %d", got)
	}
	if got := PreferredPort("", "", func() int { return 6003 }); got != 6003 {
		t.Fatalf("kernel port must beat default, got %d", got)
	}
	if got := PreferredPort("", "", func() int { return 0 }); got != DefaultPort {
		t.Fatalf("default fallback, got %d", got)
	}
}

func TestAvailableLoopbackPort(t *testing.T) {
	port := AvailableLoopbackPort()
	if port <= 0 || port > 65535 {
		t.Fatalf("AvailableLoopbackPort = %d", port)
	}
	if second := AvailableLoopbackPort(); second <= 0 {
		t.Fatalf("AvailableLoopbackPort second call = %d", second)
	}
}

func TestStorageLockPath(t *testing.T) {
	if got := StorageLockPath(`C:\Users\a\.handbean\handbean.db`); got != `C:\Users\a\.handbean\handbean.db.lock` {
		t.Fatalf("StorageLockPath = %q", got)
	}
}
