package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	testSuffix = "0123abcd9f"
	testSeed   = "00112233445566778899aabbccddeeff"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) Now() time.Time { return c.t }

func testConfig() Config {
	return Config{
		AppName: "Test Portal", Description: "Desc here", Keywords: "k1, k2", BaseURL: "https://example.com",
		RateLimit: 1000, RateBurst: 1000, GlobalRate: 100000,
		LoginDelayMin: 200 * time.Millisecond, LoginDelayMax: 800 * time.Millisecond,
		RandomSuffix: testSuffix, PageSeed: testSeed,
	}
}

// newTestApp builds an app with generous limits; the login delay is recorded
// in app.slept instead of being waited for.
var (
	loginOnce sync.Once
	loginPath string
)

// sharedLogin writes a generated login page into a process-wide temp dir.
func sharedLogin() string {
	loginOnce.Do(func() {
		d, err := os.MkdirTemp("", "fakewebapp-test")
		if err != nil {
			panic(err)
		}
		loginPath = filepath.Join(d, "login.html")
		// testdata/login.html: python3 gen/login.py --seed <testSeed> --out testdata/login.html
		page, err := os.ReadFile(filepath.Join("testdata", "login.html"))
		if err != nil {
			panic(err)
		}
		if err := os.WriteFile(loginPath, page, 0o644); err != nil {
			panic(err)
		}
	})
	return loginPath
}

func newTestAppCfg(mod func(*Config)) (*App, *fakeClock, http.Handler) {
	clk := &fakeClock{t: time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)}
	cfg := testConfig()
	cfg.LoginFile, cfg.StaticDir = sharedLogin(), filepath.Dir(sharedLogin())
	if mod != nil {
		mod(&cfg)
	}
	a, err := NewApp(cfg, clk.Now)
	if err != nil {
		panic(err)
	}
	a.sleep = func(ctx context.Context, d time.Duration) { slept = append(slept, d) }
	return a, clk, a.Handler()
}

var slept []time.Duration

func newTestApp(_ float64) (*App, *fakeClock, http.Handler) { return newTestAppCfg(nil) }

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
	checkSEO(t, b, "https://example.com", "Test Portal", "Desc here", "k1, k2")
	for _, want := range []string{"application/ld+json", `"@type":"WebApplication"`, `action="/login"`, "2026-01-01 12:00:00"} {
		if !strings.Contains(b, want) {
			t.Errorf("missing %q", want)
		}
	}
	csp := rec.Header().Get("Content-Security-Policy")
	if csp == "" || rec.Header().Get("X-Content-Type-Options") != "nosniff" || rec.Header().Get("Referrer-Policy") == "" {
		t.Error("security headers missing")
	}
	m := regexp.MustCompile(`nonce-([^']+)'`).FindStringSubmatch(csp)
	if m == nil || strings.Count(b, `nonce="`+m[1]+`"`) < 2 {
		t.Errorf("nonce from CSP %q not found in the page", csp)
	}
	if rec.Header().Get("Cache-Control") == "" {
		t.Error("no Cache-Control")
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
			if rec.Header().Get("Retry-After") == "" || !strings.Contains(strings.ToLower(rec.Body.String()), "too many") {
				t.Fatal("429 lacks Retry-After/message")
			}
		} else if !strings.Contains(strings.ToLower(rec.Body.String()), "incorrect") || !strings.Contains(rec.Body.String(), "<form") {
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
		rec := do(h, "GET", "/random-"+testSuffix+"?size="+s, nil)
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
		if rec := do(h, "GET", "/random-"+testSuffix+"?size="+q, nil); rec.Code != 400 {
			t.Errorf("size %q: %d", q, rec.Code)
		}
	}
	if rec := do(h, "GET", "/random-"+testSuffix, nil); rec.Code != 400 {
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
		{"GET", "/robots.txt", 302}, {"GET", "/sitemap.xml", 302}, {"POST", "/favicon.ico", 303}, {"PUT", "/random-" + testSuffix, 302}, {"POST", "/random-" + testSuffix, 303},
		{"GET", "/random-data", 302}, {"GET", "/random-data?size=5", 302}, {"GET", "/random-ffffffff00", 302}, {"GET", "/random-" + testSuffix + "x", 302},
	}
	for _, c := range cases {
		rec := do(h, c.m, c.p, nil)
		if rec.Code != c.code || rec.Header().Get("Location") != "/" || rec.Body.Len() != 0 || rec.Header().Get("Content-Length") != "0" {
			t.Errorf("%s %s: %d %q body %q", c.m, c.p, rec.Code, rec.Header().Get("Location"), rec.Body.String())
		}
	}
}

func TestGlobalLimiter(t *testing.T) {
	_, clk, h := newTestAppCfg(func(c *Config) { c.GlobalRate = 3 })
	for i := 0; i < 3; i++ {
		if rec := do(h, "GET", "/", nil); rec.Code != 200 {
			t.Fatalf("req %d: %d", i, rec.Code)
		}
	}
	rec := do(h, "GET", "/", nil)
	if rec.Code != 429 || rec.Header().Get("Retry-After") != "1" {
		t.Fatalf("got %d %q", rec.Code, rec.Header().Get("Retry-After"))
	}
	checkHTML429(t, rec)
	clk.t = clk.t.Add(time.Second)
	if rec := do(h, "GET", "/", nil); rec.Code != 200 {
		t.Fatalf("after refill: %d", rec.Code)
	}
}

func checkHTML429(t *testing.T, rec *httptest.ResponseRecorder) {
	t.Helper()
	b := rec.Body.String()
	if !strings.HasPrefix(rec.Header().Get("Content-Type"), "text/html") || !strings.Contains(b, "<html") || strings.HasPrefix(b, "Too many requests\n") {
		t.Errorf("429 is not an HTML page: %q %q", rec.Header().Get("Content-Type"), b)
	}
}

func doIP(h http.Handler, ip, path string) *httptest.ResponseRecorder {
	req := httptest.NewRequest("GET", path, nil)
	req.Header.Set("X-Real-IP", ip)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestPerIPLimiter(t *testing.T) {
	_, clk, h := newTestAppCfg(func(c *Config) { c.RateLimit = 2; c.RateBurst = 4 })
	for i := 0; i < 4; i++ {
		if rec := doIP(h, "1.1.1.1", "/"); rec.Code != 200 {
			t.Fatalf("req %d: %d", i, rec.Code)
		}
	}
	rec := doIP(h, "1.1.1.1", "/")
	if rec.Code != 429 || rec.Header().Get("Retry-After") == "" {
		t.Fatalf("got %d", rec.Code)
	}
	checkHTML429(t, rec)
	if rec := doIP(h, "2.2.2.2", "/"); rec.Code != 200 {
		t.Fatalf("other ip: %d", rec.Code)
	}
	clk.t = clk.t.Add(time.Second) // 2 tokens
	if rec := doIP(h, "1.1.1.1", "/"); rec.Code != 200 {
		t.Fatalf("after refill: %d", rec.Code)
	}
}

func TestIPLimiterBounded(t *testing.T) {
	clk := &fakeClock{t: time.Now()}
	l := newIPLimiter(1, 5, clk.Now)
	l.max = 10
	for i := 0; i < 100; i++ {
		l.Allow(strconv.Itoa(i))
		if len(l.m) > 10 {
			t.Fatalf("tracked %d", len(l.m))
		}
	}
	clk.t = clk.t.Add(time.Minute)
	l.Cleanup()
	if len(l.m) != 0 {
		t.Fatalf("cleanup left %d", len(l.m))
	}
}

func writeFile(t *testing.T, p, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// staticApp returns a handler serving a fresh static dir.
func staticApp(t *testing.T) (string, http.Handler) {
	t.Helper()
	dir := t.TempDir()
	_, _, h := newTestAppCfg(func(c *Config) { c.StaticDir = dir })
	return dir, h
}

func TestLoginFileErrors(t *testing.T) {
	dir := t.TempDir()
	for name, content := range map[string]string{"empty": "", "blank": " \n", "invalid": "{{if}}", "badfield": "<p>{{.Nope}}</p>"} {
		p := filepath.Join(dir, name+".html")
		writeFile(t, p, content)
		cfg := testConfig()
		cfg.LoginFile, cfg.StaticDir = p, dir
		if _, err := NewApp(cfg, time.Now); err == nil || !strings.Contains(err.Error(), "gen/login.py") {
			t.Errorf("%s: err %v", name, err)
		}
	}
	cfg := testConfig()
	cfg.LoginFile, cfg.StaticDir = filepath.Join(dir, "missing.html"), dir
	if _, err := NewApp(cfg, time.Now); err == nil || !strings.Contains(err.Error(), "gen/login.py") {
		t.Errorf("missing: %v", err)
	}
	cfg.LoginFile, cfg.StaticDir = sharedLogin(), filepath.Join(dir, "nodir")
	if _, err := NewApp(cfg, time.Now); err == nil {
		t.Error("missing static dir accepted")
	}
}

func TestStaticServed(t *testing.T) {
	dir, h := staticApp(t)
	writeFile(t, filepath.Join(dir, "app.css"), "body{}")
	writeFile(t, filepath.Join(dir, "a/b/c.css"), "x{}")
	writeFile(t, filepath.Join(dir, "blob.zzunknown"), "data")
	rec := do(h, "GET", "/app.css", nil)
	if rec.Code != 200 || rec.Body.String() != "body{}" || !strings.HasPrefix(rec.Header().Get("Content-Type"), "text/css") ||
		rec.Header().Get("Cache-Control") != "no-cache" || rec.Header().Get("X-Content-Type-Options") != "nosniff" ||
		rec.Header().Get("Content-Security-Policy") == "" || rec.Header().Get("Last-Modified") == "" {
		t.Fatalf("%d %v", rec.Code, rec.Header())
	}
	etag := rec.Header().Get("ETag")
	if etag == "" {
		t.Fatal("no ETag")
	}
	req := httptest.NewRequest("GET", "/app.css", nil)
	req.Header.Set("If-None-Match", etag)
	r2 := httptest.NewRecorder()
	h.ServeHTTP(r2, req)
	if r2.Code != 304 {
		t.Errorf("conditional: %d", r2.Code)
	}
	if rec := do(h, "HEAD", "/app.css", nil); rec.Code != 200 || rec.Body.Len() != 0 || rec.Header().Get("ETag") != etag {
		t.Errorf("HEAD: %d len %d", rec.Code, rec.Body.Len())
	}
	if rec := do(h, "GET", "/a/b/c.css", nil); rec.Code != 200 || rec.Body.String() != "x{}" {
		t.Errorf("subdir: %d", rec.Code)
	}
	if rec := do(h, "GET", "/blob.zzunknown", nil); rec.Header().Get("Content-Type") != "application/octet-stream" {
		t.Errorf("fallback type %q", rec.Header().Get("Content-Type"))
	}
	// Edits are visible immediately and change the ETag.
	writeFile(t, filepath.Join(dir, "app.css"), "body{color:red}")
	rec = do(h, "GET", "/app.css", nil)
	if rec.Body.String() != "body{color:red}" || rec.Header().Get("ETag") == etag {
		t.Errorf("edit not visible: %q %q", rec.Body.String(), rec.Header().Get("ETag"))
	}
	if rec := do(h, "POST", "/app.css", nil); rec.Code != 303 {
		t.Errorf("POST: %d", rec.Code)
	}
}

func TestStaticNotServed(t *testing.T) {
	dir, h := staticApp(t)
	writeFile(t, filepath.Join(dir, ".secret"), "s")
	writeFile(t, filepath.Join(dir, ".hid/x.txt"), "s")
	writeFile(t, filepath.Join(dir, "a/.x.txt"), "s")
	writeFile(t, filepath.Join(dir, "login.html"), "s")
	writeFile(t, filepath.Join(dir, "index.html"), "s")
	writeFile(t, filepath.Join(dir, "sub/ok.txt"), "s")
	outside := t.TempDir()
	writeFile(t, filepath.Join(outside, "out.txt"), "outside")
	if err := os.Symlink(filepath.Join(outside, "out.txt"), filepath.Join(dir, "link.txt")); err != nil {
		t.Skip(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "linkdir")); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"/.secret", "/.hid/x.txt", "/a/.x.txt", "/login.html", "/LOGIN.HTML", "/Login.Html", "/sub", "/sub/", "/index.html/", "//app.css",
		"/../out.txt", "/sub/../../out.txt", "/%2e%2e/out.txt", "/sub/%2e%2e/ok.txt", "/link.txt", "/linkdir/out.txt", "/nosuch", "/favicon.ico"} {
		rec := do(h, "GET", p, nil)
		if rec.Code != 302 || rec.Header().Get("Location") != "/" || rec.Body.Len() != 0 {
			t.Errorf("%s: %d %q", p, rec.Code, rec.Body.String())
		}
	}
	if rec := do(h, "GET", "/sub/ok.txt", nil); rec.Code != 200 {
		t.Errorf("control: %d", rec.Code)
	}
}

func TestFaviconStatic(t *testing.T) {
	dir, h := staticApp(t)
	if rec := do(h, "GET", "/favicon.ico", nil); rec.Code != 302 {
		t.Errorf("absent: %d", rec.Code)
	}
	writeFile(t, filepath.Join(dir, "favicon.ico"), "\x00\x00\x01\x00 icon")
	rec := do(h, "GET", "/favicon.ico", nil)
	if rec.Code != 200 || !bytes.HasPrefix(rec.Body.Bytes(), []byte{0, 0, 1, 0}) || rec.Header().Get("Content-Type") == "" {
		t.Errorf("present: %d %v", rec.Code, rec.Header())
	}
}

func TestLoginDelay(t *testing.T) {
	_, _, h := newTestApp(0)
	slept = nil
	do(h, "POST", "/login", url.Values{"username": {"a"}})
	do(h, "POST", "/login", url.Values{"username": {"a"}})
	do(h, "POST", "/login", url.Values{"username": {"a"}}) // 429 is delayed too
	if len(slept) != 3 {
		t.Fatalf("slept %d times", len(slept))
	}
	for _, d := range slept {
		if d < 200*time.Millisecond || d > 800*time.Millisecond {
			t.Errorf("delay %v out of range", d)
		}
	}
	slept = nil
	do(h, "GET", "/", nil)
	if len(slept) != 0 {
		t.Error("GET / delayed")
	}
}

func TestLoginDelayDistribution(t *testing.T) {
	lo, hi := 200*time.Millisecond, 800*time.Millisecond
	distinct := map[time.Duration]bool{}
	var sum float64
	n := 2000
	for i := 0; i < n; i++ {
		d := loginDelay(lo, hi, rand.NormFloat64())
		if d < lo || d > hi {
			t.Fatalf("out of range: %v", d)
		}
		distinct[d] = true
		sum += float64(d)
	}
	mean := time.Duration(sum / float64(n))
	if len(distinct) < n/2 || mean <= lo+(hi-lo)/5 || mean >= lo+(hi-lo)*3/5 {
		t.Errorf("distribution looks wrong: distinct %d mean %v", len(distinct), mean)
	}
	if loginDelay(lo, hi, -100) != lo || loginDelay(lo, hi, 100) != hi {
		t.Error("not clamped")
	}
}

func TestLoginDelayContextCancel(t *testing.T) {
	a, _, _ := newTestApp(0)
	a.sleep = sleepCtx
	a.delay = func() time.Duration { return time.Hour }
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest("POST", "/login", strings.NewReader("username=a")).WithContext(ctx)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { a.Handler().ServeHTTP(rec, req); close(done) }()
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("handler did not stop after cancel")
	}
	if rec.Body.Len() != 0 {
		t.Error("response written after cancel")
	}
}

func TestPlainTextBodiesGone(t *testing.T) {
	_, _, h := newTestApp(0)
	rec := do(h, "GET", "/random-"+testSuffix+"?size=abc", nil)
	if rec.Code != 400 || !strings.Contains(rec.Body.String(), "<html") || !strings.HasPrefix(rec.Header().Get("Content-Type"), "text/html") {
		t.Errorf("400: %d %q", rec.Code, rec.Body.String())
	}
}

func TestConfigValidate(t *testing.T) {
	for _, v := range []string{"", "short", "0123456", "0123456789abc", "0123ABCD9f", "0123abcg9f"} {
		if (withIDs(v, testSeed)).validate() == nil {
			t.Errorf("%q accepted", v)
		}
	}
	for _, v := range []string{"01234567", "0123456789ab"} {
		if err := (withIDs(v, testSeed)).validate(); err != nil {
			t.Errorf("%q: %v", v, err)
		}
	}
	for _, v := range []string{"", "0123456789abcde", "ABCDEF0123456789", "xyz0123456789abc", strings.Repeat("a", 65)} {
		if (withIDs(testSuffix, v)).validate() == nil {
			t.Errorf("seed %q accepted", v)
		}
	}
	for _, v := range []string{"0123456789abcdef", strings.Repeat("f", 64)} {
		if err := (withIDs(testSuffix, v)).validate(); err != nil {
			t.Errorf("seed %q: %v", v, err)
		}
	}
}

func withIDs(suffix, seed string) Config {
	c := testConfig()
	c.RandomSuffix, c.PageSeed = suffix, seed
	return c
}

func TestConfigValidateNumbers(t *testing.T) {
	if err := testConfig().validate(); err != nil {
		t.Fatal(err)
	}
	bad := map[string]func(*Config){
		"rps0":     func(c *Config) { c.RateLimit = 0 },
		"burst0":   func(c *Config) { c.RateBurst = 0 },
		"global0":  func(c *Config) { c.GlobalRate = 0 },
		"minmax":   func(c *Config) { c.LoginDelayMin = time.Second; c.LoginDelayMax = time.Millisecond },
		"hugedel":  func(c *Config) { c.LoginDelayMax = time.Minute },
		"envError": func(c *Config) { c.envErr = errors.New("RATE_LIMIT_RPS must be an integer") },
	}
	for name, mod := range bad {
		c := testConfig()
		mod(&c)
		if c.validate() == nil {
			t.Errorf("%s accepted", name)
		}
	}
}

func TestLoadConfigEnv(t *testing.T) {
	t.Setenv("RATE_LIMIT_RPS", "12")
	t.Setenv("RATE_LIMIT_BURST", "30")
	t.Setenv("RATE_LIMIT_GLOBAL_RPS", "200")
	t.Setenv("LOGIN_DELAY_MIN_MS", "250")
	t.Setenv("LOGIN_DELAY_MAX_MS", "900")
	t.Setenv("RANDOM_DATA_SUFFIX", testSuffix)
	t.Setenv("PAGE_SEED", testSeed)
	c := loadConfig()
	if err := c.validate(); err != nil || c.RateLimit != 12 || c.RateBurst != 30 || c.GlobalRate != 200 || c.LoginDelayMin != 250*time.Millisecond || c.LoginDelayMax != 900*time.Millisecond {
		t.Fatalf("%v %+v", err, c)
	}
	t.Setenv("RATE_LIMIT_BURST", "x")
	if loadConfig().validate() == nil {
		t.Error("non-numeric accepted")
	}
	t.Setenv("RATE_LIMIT_BURST", "")
	if loadConfig().validate() == nil {
		t.Error("missing accepted")
	}
}
