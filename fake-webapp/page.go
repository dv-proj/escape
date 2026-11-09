package main

import (
	"errors"
	"fmt"
	"html/template"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
)

// parsePage parses src as the page template and makes sure it renders with
// every state, so that a broken hand-edited file is rejected at startup
// instead of failing on each request.
func parsePage(src string) (*template.Template, error) {
	if strings.TrimSpace(src) == "" {
		return nil, errors.New("page is empty")
	}
	t, err := template.New("page").Parse(src)
	if err != nil {
		return nil, err
	}
	d := pageData{
		AppName: "App", Description: "d", Keywords: "k", BaseURL: "https://example.com",
		JSONLD: template.JS("{}"), Nonce: "n", Year: 2000, Time: "t",
	}
	for _, state := range []string{"", stateInvalid, stateThrottled} {
		d.State = state
		d.HideForm = state == stateThrottled
		if err := t.Execute(io.Discard, d); err != nil {
			return nil, fmt.Errorf("render with state %q: %w", state, err)
		}
	}
	return t, nil
}

// loadPage returns the page template for cfg. A valid cfg.PageFile is used as
// is; an invalid one is reported and left untouched while the generated
// variant is served from memory. A missing file is created from the generated
// variant (a write failure only produces a warning). An empty cfg.PageFile
// disables the file altogether.
func loadPage(cfg Config) (*template.Template, error) {
	generated := generatePage(cfg.PageSeed)
	fallback := func() (*template.Template, error) {
		t, err := parsePage(generated)
		if err != nil {
			return nil, fmt.Errorf("generated page (seed %q): %w", cfg.PageSeed, err)
		}
		return t, nil
	}
	if cfg.PageFile == "" {
		return fallback()
	}
	data, err := os.ReadFile(cfg.PageFile)
	switch {
	case err == nil:
		t, perr := parsePage(string(data))
		if perr == nil {
			slog.Info("page loaded from file", "file", cfg.PageFile)
			return t, nil
		}
		slog.Error("invalid page file, using the generated page (file left untouched)", "file", cfg.PageFile, "err", perr)
	case errors.Is(err, fs.ErrNotExist):
		if werr := writeFileAtomic(cfg.PageFile, []byte(generated), 0o644); werr != nil {
			slog.Warn("cannot write page file, serving the generated page from memory", "file", cfg.PageFile, "err", werr)
		} else {
			slog.Info("page file created", "file", cfg.PageFile)
		}
	default:
		slog.Error("cannot read page file, using the generated page", "file", cfg.PageFile, "err", err)
	}
	return fallback()
}

// writeFileAtomic writes data to a temporary file next to path and renames it
// into place, so readers never see a partial file.
func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".page-*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	ok := false
	defer func() {
		if !ok {
			_ = os.Remove(tmp)
		}
	}()
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Chmod(mode); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	ok = true
	return nil
}
