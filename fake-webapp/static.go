package main

import (
	"mime"
	"net/http"
	"path"
	"strconv"
	"strings"
)

// staticName maps a request path to a file name relative to the static root.
// It rejects unclean paths, hidden segments and the login template.
func staticName(p string) (string, bool) {
	if len(p) < 2 || p[0] != '/' || path.Clean(p) != p {
		return "", false
	}
	name := p[1:]
	if strings.EqualFold(name, "login.html") {
		return "", false
	}
	for _, seg := range strings.Split(name, "/") {
		if seg == "" || strings.HasPrefix(seg, ".") {
			return "", false
		}
	}
	return name, true
}

// serveStatic serves a regular file from the static root, read on every
// request. It reports false when the path is not servable.
func (a *App) serveStatic(w http.ResponseWriter, r *http.Request) bool {
	name, ok := staticName(r.URL.Path)
	if !ok {
		return false
	}
	f, err := a.static.Open(name)
	if err != nil {
		return false
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		return false
	}
	ct := mime.TypeByExtension(path.Ext(name))
	if ct == "" {
		ct = "application/octet-stream"
	}
	h := w.Header()
	h.Set("Content-Type", ct)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Cache-Control", "no-cache")
	h.Set("ETag", `"`+strconv.FormatInt(st.Size(), 16)+"-"+strconv.FormatInt(st.ModTime().UnixNano(), 16)+`"`)
	http.ServeContent(w, r, name, st.ModTime(), f)
	return true
}
