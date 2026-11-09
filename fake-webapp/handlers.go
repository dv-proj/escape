package main

import (
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/json"
	"html/template"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// MaxRandomDataSize is the maximum number of bytes /random-data may return.
const MaxRandomDataSize = 500000

//go:embed templates/*.html
var templatesFS embed.FS

var pageTmpl = template.Must(template.ParseFS(templatesFS, "templates/page.html"))

type pageData struct {
	AppName, Description, Keywords, BaseURL string
	JSONLD                                  template.JS
	Nonce                                   string
	Error                                   string
	HideForm                                bool
	Time                                    string
	UnixMilli                               int64
	OffsetSec                               int
}

// App wires configuration, limiters and clock together.
type App struct {
	cfg      Config
	now      Clock
	global   *bucket
	throttle *loginThrottle
	jsonLD   template.JS
}

func NewApp(cfg Config, now Clock) *App {
	a := &App{cfg: cfg, now: now, global: newBucket(cfg.RateLimit, now), throttle: newLoginThrottle(now)}
	ld := map[string]any{
		"@context":            "https://schema.org",
		"@type":               "WebApplication",
		"name":                cfg.AppName,
		"description":         cfg.Description,
		"keywords":            cfg.Keywords,
		"applicationCategory": "BusinessApplication",
		"operatingSystem":     "Any",
	}
	if cfg.BaseURL != "" {
		ld["url"] = cfg.BaseURL
	}
	b, _ := json.Marshal(ld)
	a.jsonLD = template.JS(b)
	return a
}

// Handler returns the full middleware chain.
func (a *App) Handler() http.Handler {
	return a.logging(a.security(a.limit(http.HandlerFunc(a.route))))
}

func clientIP(r *http.Request) string {
	if v := strings.TrimSpace(r.Header.Get("X-Real-IP")); v != "" {
		return v
	}
	if v := r.Header.Get("X-Forwarded-For"); v != "" {
		return strings.TrimSpace(strings.Split(v, ",")[0])
	}
	h, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return h
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (a *App) logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		slog.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", sw.status,
			"duration", time.Since(start).String(),
			"ip", clientIP(r),
		)
	})
}

func newNonce() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return base64.RawStdEncoding.EncodeToString(b)
}

type nonceKey struct{}

func (a *App) security(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		nonce := newNonce()
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy", "default-src 'none'; style-src 'nonce-"+nonce+"'; script-src 'nonce-"+nonce+"'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
		next.ServeHTTP(w, r.WithContext(withNonce(r, nonce)))
	})
}

func (a *App) limit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !a.global.Allow() {
			w.Header().Set("Retry-After", "1")
			http.Error(w, "Too many requests", http.StatusTooManyRequests)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *App) route(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/" && (r.Method == http.MethodGet || r.Method == http.MethodHead):
		a.renderPage(w, r, http.StatusOK, "", false)
	case r.URL.Path == "/login" && r.Method == http.MethodPost:
		a.login(w, r)
	case r.URL.Path == "/random-data" && r.Method == http.MethodGet:
		a.randomData(w, r)
	default:
		code := http.StatusFound
		if r.Method == http.MethodPost {
			code = http.StatusSeeOther
		}
		http.Redirect(w, r, "/", code)
	}
}

func (a *App) renderPage(w http.ResponseWriter, r *http.Request, status int, msg string, hideForm bool) {
	t := a.now()
	_, off := t.Zone()
	d := pageData{
		AppName: a.cfg.AppName, Description: a.cfg.Description, Keywords: a.cfg.Keywords,
		BaseURL: a.cfg.BaseURL, JSONLD: a.jsonLD, Nonce: nonceFrom(r),
		Error: msg, HideForm: hideForm,
		Time: t.Format("2006-01-02 15:04:05"), UnixMilli: t.UnixMilli(), OffsetSec: off,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if r.Method == http.MethodHead {
		return
	}
	if err := pageTmpl.Execute(w, d); err != nil {
		slog.Error("template", "err", err)
	}
}

func (a *App) login(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	_ = r.ParseForm()
	user := strings.ToLower(strings.TrimSpace(r.PostFormValue("username")))
	ok, retry := a.throttle.Attempt(user)
	if !ok {
		secs := int((retry + time.Second - 1) / time.Second)
		w.Header().Set("Retry-After", strconv.Itoa(secs))
		a.renderPage(w, r, http.StatusTooManyRequests, "Too many attempts, please try again later.", true)
		return
	}
	a.renderPage(w, r, http.StatusUnauthorized, "The username or password is incorrect. Please try again.", false)
}

func (a *App) randomData(w http.ResponseWriter, r *http.Request) {
	s := r.URL.Query().Get("size")
	n, err := strconv.Atoi(s)
	if s == "" || err != nil || n < 0 || n > MaxRandomDataSize || s[0] == '+' || s[0] == '-' {
		http.Error(w, "size must be an integer between 0 and "+strconv.Itoa(MaxRandomDataSize), http.StatusBadRequest)
		return
	}
	buf := make([]byte, n)
	_, _ = rand.Read(buf)
	h := w.Header()
	h.Set("Content-Type", "application/octet-stream")
	h.Set("Content-Disposition", `attachment; filename="data-`+strconv.Itoa(n)+`.bin"`)
	h.Set("Content-Length", strconv.Itoa(n))
	h.Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(buf)
}
