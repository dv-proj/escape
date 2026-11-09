package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	mrand "math/rand/v2"
	"net/http"
	"strings"
)

// headerProfile is the per-deploy shape of the security headers. It is derived
// deterministically from PAGE_SEED, so the set stays stable for one deploy but
// differs between deploys.
type headerProfile struct {
	nonceLen     int // random bytes
	nonceEnc     *base64.Encoding
	nonceHex     bool
	directives   []string // CSP directives; "%N" is replaced by 'nonce-...'
	trailingSemi bool
	referrer     string
	xfo          string // empty: no X-Frame-Options
	permissions  string // empty: no Permissions-Policy
	coop         bool
	cacheControl string
}

var (
	referrerPolicies = []string{"no-referrer", "same-origin", "strict-origin-when-cross-origin", "strict-origin"}
	cacheControls    = []string{"no-store", "no-cache, private", "private, max-age=0, must-revalidate"}
	permFeatures     = []string{"camera=()", "microphone=()", "geolocation=()", "payment=()", "usb=()", "accelerometer=()", "gyroscope=()", "magnetometer=()"}
)

func newHeaderProfile(seed string) *headerProfile {
	sum := sha256.Sum256([]byte("headers:" + seed))
	r := mrand.New(mrand.NewChaCha8(sum))
	ch := func(percent int) bool { return r.IntN(100) < percent }
	p := &headerProfile{}

	p.nonceLen = []int{16, 18, 24}[r.IntN(3)]
	switch r.IntN(4) {
	case 0:
		p.nonceEnc = base64.StdEncoding
	case 1:
		p.nonceEnc = base64.RawStdEncoding
	case 2:
		p.nonceEnc = base64.URLEncoding
	default:
		p.nonceHex = true
	}

	d := []string{"default-src 'none'", "style-src %N", "script-src %N", "frame-ancestors " + []string{"'none'", "'self'"}[r.IntN(2)]}
	d = append(d, "base-uri "+[]string{"'none'", "'self'"}[r.IntN(2)])
	if ch(75) {
		d = append(d, "form-action 'self'")
	}
	if ch(50) {
		d = append(d, "img-src 'self' data:")
	}
	if ch(40) {
		d = append(d, "object-src 'none'")
	}
	if ch(25) {
		d = append(d, "font-src 'none'")
	}
	if ch(20) {
		d = append(d, "upgrade-insecure-requests")
	}
	r.Shuffle(len(d), func(i, j int) { d[i], d[j] = d[j], d[i] })
	p.directives = d
	p.trailingSemi = ch(25)

	p.referrer = referrerPolicies[r.IntN(len(referrerPolicies))]
	if ch(50) {
		p.xfo = []string{"DENY", "SAMEORIGIN"}[r.IntN(2)]
	}
	if ch(55) {
		f := append([]string(nil), permFeatures...)
		r.Shuffle(len(f), func(i, j int) { f[i], f[j] = f[j], f[i] })
		p.permissions = strings.Join(f[:2+r.IntN(4)], ", ")
	}
	p.coop = ch(35)
	p.cacheControl = cacheControls[r.IntN(len(cacheControls))]
	return p
}

func (p *headerProfile) newNonce() string {
	b := make([]byte, p.nonceLen)
	_, _ = rand.Read(b)
	if p.nonceHex {
		return hex.EncodeToString(b)
	}
	return p.nonceEnc.EncodeToString(b)
}

func (p *headerProfile) csp(nonce string) string {
	n := "'nonce-" + nonce + "'"
	s := strings.ReplaceAll(strings.Join(p.directives, "; "), "%N", n)
	if p.trailingSemi {
		s += ";"
	}
	return s
}

// apply sets the headers of an HTML/data response.
func (p *headerProfile) apply(h http.Header, nonce string) {
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", p.referrer)
	h.Set("Content-Security-Policy", p.csp(nonce))
	if p.xfo != "" {
		h.Set("X-Frame-Options", p.xfo)
	}
	if p.permissions != "" {
		h.Set("Permissions-Policy", p.permissions)
	}
	if p.coop {
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
	}
}
