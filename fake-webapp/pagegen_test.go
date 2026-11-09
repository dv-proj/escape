package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

var (
	tagRe   = map[string]*regexp.Regexp{}
	classRe = regexp.MustCompile(`class="([^"]*)"`)
	idRe    = regexp.MustCompile(`\bid="([^"]*)"`)
	forRe   = regexp.MustCompile(`<label[^>]*\bfor="([^"]*)"`)
)

// hasTag reports whether some <tag ...> in b contains all the given fragments
// (attribute order is randomized, so exact substrings do not work).
func hasTag(b, tag string, frags ...string) bool {
	re, ok := tagRe[tag]
	if !ok {
		re = regexp.MustCompile(`<` + tag + `\b[^>]*>`)
		tagRe[tag] = re
	}
next:
	for _, m := range re.FindAllString(b, -1) {
		for _, f := range frags {
			if !strings.Contains(m, f) {
				continue next
			}
		}
		return true
	}
	return false
}

func checkSEO(t *testing.T, b, baseURL, name, desc, kw string) {
	t.Helper()
	lb := strings.ToLower(b)
	checks := []struct {
		ok   bool
		what string
	}{
		{regexp.MustCompile(`<title>[^<]*` + regexp.QuoteMeta(name) + `[^<]*</title>`).MatchString(b), "title"},
		{hasTag(b, "meta", `name="description"`, `content="`+desc+`"`), "description"},
		{hasTag(b, "meta", `name="keywords"`, `content="`+kw+`"`), "keywords"},
		{hasTag(b, "meta", `name="robots"`), "robots"},
		{hasTag(b, "meta", `property="og:title"`, `content="`+name+`"`), "og:title"},
		{hasTag(b, "meta", `property="og:description"`, `content="`+desc+`"`), "og:description"},
		{hasTag(b, "meta", `property="og:type"`, `content="website"`), "og:type"},
		{hasTag(b, "meta", `name="twitter:card"`), "twitter:card"},
		{hasTag(b, "meta", `name="viewport"`), "viewport"},
		{strings.Contains(lb, `<meta charset="utf-8"`), "charset"},
		{hasTag(b, "script", `type="application/ld+json"`, `nonce="`), "ld+json nonce"},
		{hasTag(b, "style", `nonce="`), "style nonce"},
		{regexp.MustCompile(`<script nonce="[^"]*">`).MatchString(b), "script nonce"},
	}
	if baseURL != "" {
		checks = append(checks,
			struct {
				ok   bool
				what string
			}{hasTag(b, "link", `rel="canonical"`, `href="`+baseURL+`"`), "canonical"},
			struct {
				ok   bool
				what string
			}{hasTag(b, "meta", `property="og:url"`, `content="`+baseURL+`"`), "og:url"})
	}
	for _, c := range checks {
		if !c.ok {
			t.Errorf("missing %s", c.what)
		}
	}
}

func renderVariant(t *testing.T, seed, state string, baseURL string) string {
	t.Helper()
	tm, err := parsePage(generatePage(seed))
	if err != nil {
		t.Fatalf("seed %s: %v", seed, err)
	}
	var buf bytes.Buffer
	d := pageData{
		AppName: "Test Portal", Description: "Desc here", Keywords: "k1, k2", BaseURL: baseURL,
		JSONLD: template.JS(`{"@type":"WebApplication"}`), Nonce: "NONCE123", State: state,
		HideForm: state == stateThrottled, Time: "2026-01-01 12:00:00", UnixMilli: 1, OffsetSec: 0, Year: 2026,
	}
	if err := tm.Execute(&buf, d); err != nil {
		t.Fatalf("seed %s: %v", seed, err)
	}
	return buf.String()
}

func seedN(i int) string {
	return fmt.Sprintf("%032x", sha256.Sum256([]byte(fmt.Sprint("seed", i))))[:32]
}

func TestGenerateDeterministic(t *testing.T) {
	a, b := generatePage(testSeed), generatePage(testSeed)
	if a != b {
		t.Fatal("same seed produced different output")
	}
	if generatePage(seedN(1)) == generatePage(seedN(2)) {
		t.Fatal("different seeds produced the same output")
	}
}

func classSet(b string) string {
	set := map[string]bool{}
	for _, m := range classRe.FindAllStringSubmatch(b, -1) {
		for _, c := range strings.Fields(m[1]) {
			set[c] = true
		}
	}
	var l []string
	for c := range set {
		l = append(l, c)
	}
	sort.Strings(l)
	return strings.Join(l, " ")
}

func TestGenerateDiversity(t *testing.T) {
	hashes, classes := map[[32]byte]bool{}, map[string]bool{}
	for i := 0; i < 50; i++ {
		b := renderVariant(t, seedN(i), "", "https://example.com")
		hashes[sha256.Sum256([]byte(b))] = true
		classes[classSet(b)] = true
	}
	if len(hashes) < 45 || len(classes) < 45 {
		t.Fatalf("distinct pages %d, distinct class sets %d (want >= 45)", len(hashes), len(classes))
	}
}

func TestGenerateVariantsValid(t *testing.T) {
	for i := 0; i < 200; i++ {
		seed := seedN(i)
		for _, base := range []string{"https://example.com", ""} {
			b := renderVariant(t, seed, "", base)
			checkSEO(t, b, base, "Test Portal", "Desc here", "k1, k2")
			for _, want := range []string{`name="username"`, `name="password"`, `action="/login"`, `method="post"`, "NONCE123", "2026-01-01 12:00:00"} {
				if !strings.Contains(b, want) {
					t.Fatalf("seed %s: missing %q", seed, want)
				}
			}
			ids := map[string]bool{}
			for _, m := range idRe.FindAllStringSubmatch(b, -1) {
				if ids[m[1]] {
					t.Fatalf("seed %s: duplicate id %q", seed, m[1])
				}
				ids[m[1]] = true
			}
			fors := forRe.FindAllStringSubmatch(b, -1)
			if len(fors) < 2 {
				t.Fatalf("seed %s: %d labels", seed, len(fors))
			}
			for _, m := range fors {
				if !ids[m[1]] {
					t.Fatalf("seed %s: label for=%q has no input", seed, m[1])
				}
			}
			if !strings.Contains(b, `getElementById("`) {
				t.Fatalf("seed %s: no clock script", seed)
			}
			if strings.Contains(b, "{{") || strings.Contains(b, "ZgotmplZ") {
				t.Fatalf("seed %s: unrendered template", seed)
			}
		}
	}
}

func TestGenerateStates(t *testing.T) {
	for i := 0; i < 200; i++ {
		seed := seedN(i)
		inv := renderVariant(t, seed, stateInvalid, "")
		if !strings.Contains(strings.ToLower(inv), "incorrect") || !strings.Contains(strings.ToLower(inv), "again") || !strings.Contains(inv, `role="alert"`) || !strings.Contains(inv, "<form") {
			t.Fatalf("seed %s: bad invalid page", seed)
		}
		thr := renderVariant(t, seed, stateThrottled, "")
		if !strings.Contains(strings.ToLower(thr), "too many") || !strings.Contains(thr, "later") && !strings.Contains(thr, "minutes") || strings.Contains(thr, "<form") || strings.Contains(thr, `name="password"`) {
			t.Fatalf("seed %s: bad throttled page", seed)
		}
		ok := renderVariant(t, seed, "", "")
		if strings.Contains(strings.ToLower(ok), "incorrect") || strings.Contains(strings.ToLower(ok), "too many") || strings.Contains(ok, `role="alert"`) {
			t.Fatalf("seed %s: error text without state", seed)
		}
	}
}

func TestLoadPage(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "page.html")
	cfg := Config{PageSeed: testSeed, PageFile: file}

	// Missing file: generated and written (0644), no leftovers.
	if _, err := loadPage(cfg); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(file)
	if err != nil || string(got) != generatePage(testSeed) {
		t.Fatalf("file not written with generated content: %v", err)
	}
	if st, _ := os.Stat(file); st.Mode().Perm() != 0o644 {
		t.Errorf("mode %v", st.Mode().Perm())
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 1 {
		t.Errorf("leftover files: %v", ents)
	}

	// Existing valid file is used as is.
	custom := `<html><body>CUSTOM {{.AppName}} {{.State}}</body></html>`
	if err := os.WriteFile(file, []byte(custom), 0o600); err != nil {
		t.Fatal(err)
	}
	tm, err := loadPage(cfg)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := tm.Execute(&buf, pageData{AppName: "X", State: "invalid"}); err != nil || buf.String() != "<html><body>CUSTOM X invalid</body></html>" {
		t.Fatalf("custom page not used: %q %v", buf.String(), err)
	}

	// Invalid files: fallback to generated, file untouched.
	for _, bad := range []string{`{{if}}`, `<p>{{.NoSuchField}}</p>`, "  \n"} {
		if err := os.WriteFile(file, []byte(bad), 0o600); err != nil {
			t.Fatal(err)
		}
		tm, err := loadPage(cfg)
		if err != nil {
			t.Fatal(err)
		}
		buf.Reset()
		_ = tm.Execute(&buf, pageData{AppName: "X"})
		if !strings.Contains(buf.String(), `name="username"`) {
			t.Errorf("%q: fallback page not generated", bad)
		}
		if got, _ := os.ReadFile(file); string(got) != bad {
			t.Errorf("%q: file was overwritten", bad)
		}
	}

	// Unwritable location: memory fallback.
	cfg.PageFile = filepath.Join(dir, "missing-dir", "page.html")
	if _, err := loadPage(cfg); err != nil {
		t.Fatalf("unwritable dir: %v", err)
	}
	// No file configured.
	cfg.PageFile = ""
	if _, err := loadPage(cfg); err != nil {
		t.Fatal(err)
	}
}
