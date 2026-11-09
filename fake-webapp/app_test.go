package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) Now() time.Time { return c.t }

func newTestApp(rps float64) (*App, *fakeClock, http.Handler) {
	clk := &fakeClock{t: time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)}
	cfg := Config{AppName: "Test Portal", Description: "Desc here", Keywords: "k1, k2", BaseURL: "https://example.com", RateLimit: rps}
	a := NewApp(cfg, clk.Now)
	return a, clk, a.Handler()
}

func do(h http.Handler, method, target string, form url.Values) *httptest.ResponseRecorder {
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req := httptest.NewRequest(method, target, body)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestIndex(t *testing.T) {
	_, _, h := newTestApp(100)
	rec := do(h, "GET", "/", nil)
	if rec.Code != 200 {
		t.Fatalf("code %d", rec.Code)
	}
	b := rec.Body.String()
	for _, want := range []string{
		"<title>Test Portal</title>", `name="description" content="Desc here"`, `name="keywords" content="k1, k2"`,
		`name="robots" content="index, follow"`, `rel="canonical" href="https://example.com"`,
		`property="og:title"`, `property="og:type" content="website"`, `property="og:url" content="https://example.com"`,
		`name="twitter:card"`, `name="viewport"`, `charset="utf-8"`, "application/ld+json", `"@type":"WebApplication"`,
		`action="/login"`, "2026-01-01 12:00:00",
	} {
		if !strings.Contains(b, want) {
			t.Errorf("missing %q", want)
		}
	}
	if rec.Header().Get("X-Frame-Options") != "DENY" || rec.Header().Get("Content-Security-Policy") == "" {
		t.Error("security headers missing")
	}
	if rec.Header().Get("Server") != "" {
		t.Error("Server header set")
	}
	if rec := do(h, "HEAD", "/", nil); rec.Code != 200 || rec.Body.Len() != 0 {
		t.Errorf("HEAD: %d len %d", rec.Code, rec.Body.Len())
	}
}

func TestLoginThrottle(t *testing.T) {
	_, clk, h := newTestApp(1000)
	f := func(u string) url.Values { return url.Values{"username": {u}, "password": {"x"}} }
	for i, want := range []int{401, 401, 429, 429} {
		u := "Alice"
		if i == 1 {
			u = "  alice "
		}
		rec := do(h, "POST", "/login", f(u))
		if rec.Code != want {
			t.Fatalf("attempt %d: got %d want %d", i+1, rec.Code, want)
		}
		if want == 429 {
			if rec.Header().Get("Retry-After") == "" || !strings.Contains(rec.Body.String(), "Too many attempts") {
				t.Fatal("429 lacks Retry-After/message")
			}
		} else if !strings.Contains(rec.Body.String(), "incorrect") || !strings.Contains(rec.Body.String(), "<form") {
			t.Fatal("401 page lacks message/form")
		}
	}
	if rec := do(h, "POST", "/login", f("bob")); rec.Code != 401 {
		t.Errorf("other user: %d", rec.Code)
	}
	if rec := do(h, "POST", "/login", f("")); rec.Code != 401 {
		t.Errorf("empty user: %d", rec.Code)
	}
	clk.t = clk.t.Add(61 * time.Second)
	if rec := do(h, "POST", "/login", f("alice")); rec.Code != 401 {
		t.Errorf("after window: %d", rec.Code)
	}
}

func TestThrottleEvictionBound(t *testing.T) {
	clk := &fakeClock{t: time.Now()}
	l := newLoginThrottle(clk.Now)
	l.maxKeys = 10
	for i := 0; i < 100; i++ {
		l.Attempt(strconv.Itoa(i))
	}
	if len(l.attempts) > 10 {
		t.Fatalf("tracked %d", len(l.attempts))
	}
	clk.t = clk.t.Add(2 * time.Minute)
	l.Cleanup()
	if len(l.attempts) != 0 || len(l.order) != 0 {
		t.Fatal("cleanup left entries")
	}
}

func TestRandomData(t *testing.T) {
	_, _, h := newTestApp(1000)
	for _, n := range []int{0, 1, 500000} {
		s := strconv.Itoa(n)
		rec := do(h, "GET", "/random-data?size="+s, nil)
		if rec.Code != 200 || rec.Body.Len() != n {
			t.Errorf("size %d: code %d len %d", n, rec.Code, rec.Body.Len())
		}
		if rec.Header().Get("Content-Type") != "application/octet-stream" || rec.Header().Get("Cache-Control") != "no-store" ||
			!strings.Contains(rec.Header().Get("Content-Disposition"), "data-"+s+".bin") ||
			rec.Header().Get("Content-Length") != s {
			t.Errorf("size %d: bad headers %v", n, rec.Header())
		}
	}
	for _, q := range []string{"500001", "-1", "abc", "", "1.5", "+5"} {
		if rec := do(h, "GET", "/random-data?size="+q, nil); rec.Code != 400 {
			t.Errorf("size %q: %d", q, rec.Code)
		}
	}
	if rec := do(h, "GET", "/random-data", nil); rec.Code != 400 {
		t.Errorf("missing: %d", rec.Code)
	}
}

func TestRedirects(t *testing.T) {
	_, _, h := newTestApp(1000)
	cases := []struct {
		m, p string
		code int
	}{
		{"GET", "/foo", 302}, {"GET", "/login", 302}, {"POST", "/", 303}, {"POST", "/foo", 303},
		{"GET", "/favicon.ico", 302}, {"PUT", "/random-data", 302}, {"POST", "/random-data", 303},
	}
	for _, c := range cases {
		rec := do(h, c.m, c.p, nil)
		if rec.Code != c.code || rec.Header().Get("Location") != "/" {
			t.Errorf("%s %s: %d %q", c.m, c.p, rec.Code, rec.Header().Get("Location"))
		}
	}
}

func TestGlobalLimiter(t *testing.T) {
	_, clk, h := newTestApp(3)
	for i := 0; i < 3; i++ {
		if rec := do(h, "GET", "/", nil); rec.Code != 200 {
			t.Fatalf("req %d: %d", i, rec.Code)
		}
	}
	rec := do(h, "GET", "/", nil)
	if rec.Code != 429 || rec.Header().Get("Retry-After") != "1" {
		t.Fatalf("got %d %q", rec.Code, rec.Header().Get("Retry-After"))
	}
	clk.t = clk.t.Add(time.Second)
	if rec := do(h, "GET", "/", nil); rec.Code != 200 {
		t.Fatalf("after refill: %d", rec.Code)
	}
}
