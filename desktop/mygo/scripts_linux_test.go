//go:build linux

package main

import (
	archivetar "archive/tar"
	"compress/gzip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestFetchWebReleaseStagesBeforeReplacingExistingPayload(t *testing.T) {
	temp := t.TempDir()
	payload := filepath.Join(temp, "payload")
	mustMkdir(t, filepath.Join(payload, "bin"), 0o700)
	mustMkdir(t, filepath.Join(payload, "releases"), 0o700)
	mustWrite(t, filepath.Join(payload, "bin", "handbean"), "#!/bin/sh\n", 0o700)
	mustWrite(t, filepath.Join(payload, "releases", "start_erl.data"), "17.0 0.3.3\n", 0o600)
	mustWrite(t, filepath.Join(payload, "ordinary.txt"), "public application data\n", 0o600)

	archive := filepath.Join(temp, "valid.tar.gz")
	tar(t, archive, payload)
	destination := filepath.Join(temp, "imported")
	fetch(t, archive, destination, true)

	assertMode(t, destination, 0o005)
	assertMode(t, filepath.Join(destination, "bin", "handbean"), 0o005)
	assertMode(t, filepath.Join(destination, "ordinary.txt"), 0o004)
	marker := filepath.Join(destination, "existing-marker")
	mustWrite(t, marker, "keep\n", 0o600)

	invalidPayload := filepath.Join(temp, "invalid-payload")
	mustMkdir(t, invalidPayload, 0o755)
	mustWrite(t, filepath.Join(invalidPayload, "not-a-release"), "invalid\n", 0o644)
	invalidArchive := filepath.Join(temp, "invalid.tar.gz")
	tar(t, invalidArchive, invalidPayload)
	fetch(t, invalidArchive, destination, false)
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("failed import replaced existing payload: %v", err)
	}
}

func TestFetchWebReleaseRejectsSymlinkHiddenByUnreadableDirectory(t *testing.T) {
	temp := t.TempDir()
	destination := filepath.Join(temp, "imported")
	mustMkdir(t, destination, 0o755)
	marker := filepath.Join(destination, "existing-marker")
	mustWrite(t, marker, "keep\n", 0o600)

	archive := filepath.Join(temp, "escaping-symlink.tar.gz")
	writeEscapingSymlinkArchive(t, archive)
	fetch(t, archive, destination, false)
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("unsafe import replaced existing payload: %v", err)
	}
}

func TestFetchWebReleaseRejectsProtectedAndSymlinkDestinations(t *testing.T) {
	temp := t.TempDir()
	repositoryRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	missingArchive := filepath.Join(temp, "missing.tar.gz")
	output, err := runFetch(missingArchive, repositoryRoot)
	if err == nil || !strings.Contains(string(output), "contains the repository") {
		t.Fatalf("repository root was not rejected before reading archive: %v\n%s", err, output)
	}

	target := filepath.Join(temp, "target")
	mustMkdir(t, target, 0o755)
	marker := filepath.Join(target, "existing-marker")
	mustWrite(t, marker, "keep\n", 0o600)
	link := filepath.Join(temp, "destination-link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	for _, destination := range []string{link, link + "/", link + "/."} {
		output, err = runFetch(missingArchive, destination)
		if err == nil || !strings.Contains(string(output), "symbolic-link") {
			t.Fatalf("symbolic-link destination %q was not rejected: %v\n%s", destination, err, output)
		}
		if _, err := os.Stat(marker); err != nil {
			t.Fatalf("symbolic-link destination target changed for %q: %v", destination, err)
		}
	}
}

func fetch(t *testing.T, archive, destination string, wantSuccess bool) {
	t.Helper()
	output, err := runFetch(archive, destination)
	if wantSuccess && err != nil {
		t.Fatalf("fetch valid release: %v\n%s", err, output)
	}
	if !wantSuccess && err == nil {
		t.Fatalf("fetch invalid release unexpectedly succeeded:\n%s", output)
	}
}

func runFetch(archive, destination string) ([]byte, error) {
	script := filepath.Join("scripts", "fetch_web_release.sh")
	cmd := exec.Command("bash", script)
	cmd.Env = append(os.Environ(), "HANDBEAN_WEB_TAR="+archive, "HANDBEAN_WEB_DEST="+destination)
	return cmd.CombinedOutput()
}

func writeEscapingSymlinkArchive(t *testing.T, archive string) {
	t.Helper()
	file, err := os.Create(archive)
	if err != nil {
		t.Fatal(err)
	}
	gzipWriter := gzip.NewWriter(file)
	tarWriter := archivetar.NewWriter(gzipWriter)
	entries := []struct {
		header archivetar.Header
		body   string
	}{
		{header: archivetar.Header{Name: "bin/", Mode: 0o755, Typeflag: archivetar.TypeDir}},
		{header: archivetar.Header{Name: "bin/handbean", Mode: 0o755, Typeflag: archivetar.TypeReg}, body: "#!/bin/sh\n"},
		{header: archivetar.Header{Name: "releases/", Mode: 0o755, Typeflag: archivetar.TypeDir}},
		{header: archivetar.Header{Name: "releases/start_erl.data", Mode: 0o644, Typeflag: archivetar.TypeReg}, body: "17.0 0.3.3\n"},
		{header: archivetar.Header{Name: "sealed/", Mode: 0, Typeflag: archivetar.TypeDir}},
		{header: archivetar.Header{Name: "sealed/outside", Mode: 0o777, Typeflag: archivetar.TypeSymlink, Linkname: "../../outside"}},
	}
	for _, entry := range entries {
		entry.header.Size = int64(len(entry.body))
		if err := tarWriter.WriteHeader(&entry.header); err != nil {
			t.Fatal(err)
		}
		if entry.body != "" {
			if _, err := tarWriter.Write([]byte(entry.body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gzipWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}

func tar(t *testing.T, archive, source string) {
	t.Helper()
	output, err := exec.Command("tar", "-czf", archive, "-C", source, ".").CombinedOutput()
	if err != nil {
		t.Fatalf("create archive: %v\n%s", err, output)
	}
}

func mustMkdir(t *testing.T, path string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(path, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func mustWrite(t *testing.T, path, content string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func assertMode(t *testing.T, path string, required os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&required != required {
		t.Fatalf("%s mode = %04o, missing %04o", path, info.Mode().Perm(), required)
	}
}
