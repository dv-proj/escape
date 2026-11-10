package main

import (
	"context"
	crand "crypto/rand"
	"encoding/json"
	"html/template"
	"log/slog"
	"math"
	"math/rand/v2"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// MaxRandomDataSize is the maximum number of bytes /random-<suffix> may return.
const MaxRandomDataSize = 500000

// Page states passed to the template as .State; the texts live in the template.
const (
	stateInvalid   = "invalid"
	stateThrottled = "throttled"
)

type pageData struct {
	AppName, Description, Keywords, BaseURL string
	JSONLD                                  template.JS
	Nonce                                   string
	State                                   string
	Year                                    int
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
	ips      *ipLimiter
	throttle *loginThrottle
	hdr      *headerProfile
	errs     *errorPages
	icon     *favicon
	// sleep waits for d or until ctx is done; delay picks the login delay.
	sleep  func(ctx context.Context, d time.Duration)
	delay  func() time.Duration
	jsonLD template.JS
	page   *template.Template
}

// NewApp builds the app; the page template comes from loadPage.
func NewApp(cfg Config, now Clock) (*App, error) {
	page, err := loadPage(cfg)
	if err != nil {
		return nil, err
	}
	a := &App{
		cfg: cfg, now: now, page: page,
		global:   newBucket(cfg.GlobalRate, cfg.GlobalRate, now),
		ips:      newIPLimiter(cfg.RateLimit, cfg.RateBurst, now),
		throttle: newLoginThrottle(now),
		hdr:      newHeaderProfile(cfg.PageSeed),
		errs:     newErrorPages(cfg.PageSeed),
		icon:     loadFavicon(cfg.FaviconFile, now()),
		sleep:    sleepCtx,
	}
	a.delay = func() time.Duration { return loginDelay(cfg.LoginDelayMin, cfg.LoginDelayMax, rand.NormFloat64()) }
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
	return a, nil
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

type nonceKey struct{}

func (a *App) security(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/favicon.ico" {
			w.Header().Set("X-Content-Type-Options", "nosniff")
			next.ServeHTTP(w, r)
			return
		}
		nonce := a.hdr.newNonce()
		a.hdr.apply(w.Header(), nonce)
		next.ServeHTTP(w, r.WithContext(withNonce(r, nonce)))
	})
}

func (a *App) limit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ok, retry := a.ips.Allow(clientIP(r)); !ok {
			a.errs.tooMany(w, r, int((retry+time.Second-1)/time.Second))
			return
		}
		if !a.global.Allow() {
			a.errs.tooMany(w, r, 1)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// sleepCtx waits for d or until ctx is cancelled.
func sleepCtx(ctx context.Context, d time.Duration) {
	if d <= 0 {
		return
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
	case <-ctx.Done():
	}
}

// loginDelay maps a standard-normal sample z to a delay in [lo, hi] using a
// log-normal shape (median ~30% into the range, long tail), clamped.
func loginDelay(lo, hi time.Duration, z float64) time.Duration {
	frac := math.Exp(math.Log(0.3) + 0.55*z)
	frac = min(max(frac, 0), 1)
	return lo + time.Duration(frac*float64(hi-lo))
}

func (a *App) route(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/" && (r.Method == http.MethodGet || r.Method == http.MethodHead):
		a.renderPage(w, r, http.StatusOK, "")
	case r.URL.Path == "/login" && r.Method == http.MethodPost:
		a.login(w, r)
	case r.URL.Path == "/favicon.ico" && (r.Method == http.MethodGet || r.Method == http.MethodHead):
		a.icon.serve(w, r)
	case r.URL.Path == "/random-"+a.cfg.RandomSuffix && r.Method == http.MethodGet:
		a.randomData(w, r)
	default:
		code := http.StatusFound
		if r.Method == http.MethodPost {
			code = http.StatusSeeOther
		}
		// Empty body: Go's http.Redirect would add an `<a href>Found</a>` stub.
		h := w.Header()
		h.Set("Location", "/")
		h.Set("Content-Length", "0")
		w.WriteHeader(code)
	}
}

func (a *App) renderPage(w http.ResponseWriter, r *http.Request, status int, state string) {
	t := a.now()
	_, off := t.Zone()
	d := pageData{
		AppName: a.cfg.AppName, Description: a.cfg.Description, Keywords: a.cfg.Keywords,
		BaseURL: a.cfg.BaseURL, JSONLD: a.jsonLD, Nonce: nonceFrom(r),
		State: state, HideForm: state == stateThrottled, Year: t.Year(),
		Time: t.Format("2006-01-02 15:04:05"), UnixMilli: t.UnixMilli(), OffsetSec: off,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", a.hdr.cacheControl)
	w.WriteHeader(status)
	if r.Method == http.MethodHead {
		return
	}
	if err := a.page.Execute(w, d); err != nil {
		slog.Error("template", "err", err)
	}
}

func (a *App) login(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	_ = r.ParseForm()
	user := strings.ToLower(strings.TrimSpace(r.PostFormValue("username")))
	ok, retry := a.throttle.Attempt(user)
	a.sleep(r.Context(), a.delay())
	if r.Context().Err() != nil {
		return
	}
	if !ok {
		secs := int((retry + time.Second - 1) / time.Second)
		w.Header().Set("Retry-After", strconv.Itoa(secs))
		a.renderPage(w, r, http.StatusTooManyRequests, stateThrottled)
		return
	}
	a.renderPage(w, r, http.StatusUnauthorized, stateInvalid)
}

func (a *App) randomData(w http.ResponseWriter, r *http.Request) {
	s := r.URL.Query().Get("size")
	n, err := strconv.Atoi(s)
	if s == "" || err != nil || n < 0 || n > MaxRandomDataSize {
		const minSize = 50_000
		n = minSize + rand.IntN(MaxRandomDataSize-minSize)
	}
	buf := make([]byte, n)
	_, _ = crand.Read(buf)
	h := w.Header()
	h.Set("Content-Type", "application/octet-stream")
	h.Set("Content-Disposition", `attachment; filename="data-`+strconv.Itoa(n)+`.bin"`)
	h.Set("Content-Length", strconv.Itoa(n))
	h.Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(buf)
}
