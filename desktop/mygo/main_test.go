package main

import (
	"errors"
	"strings"
	"testing"
)

func TestAppRunErrorExplainsLinuxWebViewDependencies(t *testing.T) {
	got := appRunError(errors.New("webview unavailable"), "linux")
	for _, want := range []string{"webview unavailable", "GTK 3", "WebKitGTK 4.1", "libwebkit2gtk-4.1-0"} {
		if !strings.Contains(got.Error(), want) {
			t.Fatalf("error %q does not contain %q", got, want)
		}
	}
}

func TestMissingWebViewMessageExplainsLinuxPackages(t *testing.T) {
	options := missingWebViewOptions("linux")
	for _, want := range []string{"libgtk-3-0", "libgtk-3-0t64", "libwebkit2gtk-4.1-0"} {
		if !strings.Contains(options.Detail, want) {
			t.Fatalf("detail %q does not contain %q", options.Detail, want)
		}
	}
	if len(options.Buttons) != 1 || options.Buttons[0] != "退出" {
		t.Fatalf("Linux buttons = %v", options.Buttons)
	}
}

func TestAppRunErrorLeavesOtherPlatformsUnchanged(t *testing.T) {
	original := errors.New("original")
	if got := appRunError(original, "windows"); got != original {
		t.Fatalf("Windows error changed: %v", got)
	}
}
