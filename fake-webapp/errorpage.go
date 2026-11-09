package main

import (
	"crypto/sha256"
	"fmt"
	"html"
	mrand "math/rand/v2"
	"net/http"
	"strconv"
)

// errorPages renders minimal HTML bodies for 429 and 400 so that no Go default
// plain-text body is ever sent. The wording and font are picked from the seed.
type errorPages struct {
	font               string
	rateTitle, rateMsg string
	badTitle, badMsg   string
	headingTag         string
}

var (
	errFonts      = []string{"-apple-system,Segoe UI,Roboto,sans-serif", "system-ui,sans-serif", "Helvetica,Arial,sans-serif", "Georgia,serif"}
	rateTitles    = []string{"Too many requests", "Slow down", "Request limit reached", "Rate limit exceeded", "Please wait a moment"}
	rateMsgs      = []string{"You are sending requests too quickly. Please try again in a few seconds.", "Too many requests from your network. Wait a moment and retry.", "Request limit reached. Please try again shortly.", "We are receiving a lot of requests from you. Please slow down and retry."}
	badTitles     = []string{"Bad request", "Invalid request", "Request error"}
	badMsgs       = []string{"The request could not be processed.", "Some of the request parameters are invalid.", "Please check the request and try again."}
	errHeadingTag = []string{"h1", "h2"}
)

func newErrorPages(seed string) *errorPages {
	sum := sha256.Sum256([]byte("errors:" + seed))
	r := mrand.New(mrand.NewChaCha8(sum))
	p := func(s []string) string { return s[r.IntN(len(s))] }
	return &errorPages{font: p(errFonts), rateTitle: p(rateTitles), rateMsg: p(rateMsgs), badTitle: p(badTitles), badMsg: p(badMsgs), headingTag: p(errHeadingTag)}
}

func (e *errorPages) write(w http.ResponseWriter, r *http.Request, status int, title, msg string) {
	nonce := nonceFrom(r)
	body := fmt.Sprintf(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%[1]s</title>
<style nonce="%[3]s">body{font-family:%[4]s;background:#f4f5f7;color:#333;margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center}main{text-align:center;padding:24px}%[5]s{font-size:22px;margin:0 0 12px}p{margin:0;color:#666}</style>
</head>
<body>
<main>
<%[5]s>%[1]s</%[5]s>
<p>%[2]s</p>
</main>
</body>
</html>
`, html.EscapeString(title), html.EscapeString(msg), html.EscapeString(nonce), e.font, e.headingTag)
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Content-Length", strconv.Itoa(len(body)))
	h.Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if r.Method != http.MethodHead {
		_, _ = w.Write([]byte(body))
	}
}

func (e *errorPages) tooMany(w http.ResponseWriter, r *http.Request, retrySecs int) {
	w.Header().Set("Retry-After", strconv.Itoa(max(retrySecs, 1)))
	e.write(w, r, http.StatusTooManyRequests, e.rateTitle, e.rateMsg)
}

func (e *errorPages) badRequest(w http.ResponseWriter, r *http.Request) {
	e.write(w, r, http.StatusBadRequest, e.badTitle, e.badMsg)
}
