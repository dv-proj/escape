package main

import (
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

var nonceRe = regexp.MustCompile(`'nonce-[^']+'`)

func headerShape(seed string) string {
	h := http.Header{}
	p := newHeaderProfile(seed)
	p.apply(h, "NONCE")
	h.Set("Cache-Control", p.cacheControl)
	return strings.Join(strings.Fields(h.Get("Content-Security-Policy")+"|"+h.Get("Referrer-Policy")+"|"+h.Get("X-Frame-Options")+"|"+h.Get("Permissions-Policy")+"|"+h.Get("Cross-Origin-Opener-Policy")+"|"+h.Get("Cache-Control")+"|"+strconv.Itoa(p.nonceLen)+strconv.FormatBool(p.nonceHex)), " ")
}

func TestHeaderProfileDeterministic(t *testing.T) {
	for _, seed := range []string{testSeed, "ffeeddccbbaa99887766554433221100"} {
		if headerShape(seed) != headerShape(seed) {
			t.Fatal("same seed gives different headers")
		}
	}
}

func TestHeaderProfileVariety(t *testing.T) {
	shapes, refs, xfo, perms, coop, caches, lens, encs := map[string]bool{}, map[string]bool{}, map[bool]bool{}, map[bool]bool{}, map[bool]bool{}, map[string]bool{}, map[int]bool{}, map[string]bool{}
	for i := 0; i < 60; i++ {
		seed := strconv.FormatInt(int64(i)+1000000, 16) + "aaaaaaaaaaaaaaaaaaaaaaaa"
		p := newHeaderProfile(seed)
		shapes[headerShape(seed)] = true
		refs[p.referrer] = true
		xfo[p.xfo != ""] = true
		perms[p.permissions != ""] = true
		coop[p.coop] = true
		caches[p.cacheControl] = true
		lens[p.nonceLen] = true
		n := p.newNonce()
		switch {
		case p.nonceHex:
			encs["hex"] = true
			if !regexp.MustCompile(`^[0-9a-f]+$`).MatchString(n) {
				t.Fatalf("bad hex nonce %q", n)
			}
		case strings.HasSuffix(n, "="):
			encs["padded"] = true
		case strings.ContainsAny(n, "-_"):
			encs["url"] = true
		default:
			encs["raw"] = true
		}
		csp := p.csp(n)
		if strings.Count(csp, n) != 2 || !strings.Contains(csp, "default-src 'none'") || !strings.Contains(csp, "frame-ancestors") {
			t.Fatalf("bad CSP %q", csp)
		}
	}
	if len(shapes) < 40 || len(refs) < 3 || len(xfo) != 2 || len(perms) != 2 || len(coop) != 2 || len(caches) != 3 || len(lens) != 3 || len(encs) < 3 {
		t.Errorf("too little variety: shapes %d refs %d xfo %d perms %d coop %d cache %d lens %d encs %v", len(shapes), len(refs), len(xfo), len(perms), len(coop), len(caches), len(lens), encs)
	}
}

func TestHeadersNoFakeServer(t *testing.T) {
	_, _, h := newTestApp(0)
	rec := do(h, "GET", "/", nil)
	for _, k := range []string{"Server", "X-Powered-By"} {
		if rec.Header().Get(k) != "" {
			t.Errorf("%s set", k)
		}
	}
}
