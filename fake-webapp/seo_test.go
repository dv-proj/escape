package main

import (
	"regexp"
	"strings"
	"testing"
)

// Helpers moved from the removed pagegen_test.go.

var tagRe = map[string]*regexp.Regexp{}

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
