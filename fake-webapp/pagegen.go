package main

import (
	"crypto/sha256"
	"fmt"
	"math/rand/v2"
	"strings"
)

// generatePage returns the source (html/template) of the decoy login page for
// the given seed. The output is fully deterministic: the same seed always
// yields byte-identical text, different seeds yield different markup, CSS,
// identifiers and wording. The visual design is the same in every variant.
//
// Template data: see pageData in handlers.go. The 401/429 texts live in the
// template and are selected by .State ("", "invalid", "throttled").
func generatePage(seed string) string {
	sum := sha256.Sum256([]byte(seed))
	g := &pageGen{r: rand.New(rand.NewChaCha8(sum)), used: map[string]bool{}}
	return g.build()
}

type pageGen struct {
	r    *rand.Rand
	used map[string]bool

	// identifier style: 0 syllable words, 1 prefix+hex, 2 prefix+sep+role noun
	idStyle int
	prefix  string
	sep     string
}

// ---- random helpers ---------------------------------------------------------

func pick[T any](g *pageGen, s []T) T { return s[g.r.IntN(len(s))] }

func (g *pageGen) chance(percent int) bool { return g.r.IntN(100) < percent }

func shuffled[T any](g *pageGen, s []T) []T {
	out := append([]T(nil), s...)
	g.r.Shuffle(len(out), func(i, j int) { out[i], out[j] = out[j], out[i] })
	return out
}

// ---- identifiers ------------------------------------------------------------

var (
	onsets = []string{"b", "d", "f", "g", "k", "l", "m", "n", "p", "r", "s", "t", "v", "z", "br", "tr", "st", "pl", "kr", "fl", "gr", "sk"}
	vowels = []string{"a", "e", "i", "o", "u"}
	codas  = []string{"n", "r", "x", "k", "m", "l", "s"}

	prefixes = []string{"auth", "login", "sign", "access", "acct", "app", "portal", "ui", "gate", "secure", "user", "entry", "sso", "lg"}
	seps     = []string{"-", "__", "_", "-"}

	roleNouns = map[string][]string{
		"wrap":     {"wrap", "outer", "shell", "layout", "container"},
		"card":     {"card", "panel", "box", "dialog", "main", "form-box"},
		"title":    {"title", "heading", "brand", "name", "head"},
		"sub":      {"sub", "lead", "hint", "subtitle", "intro", "caption"},
		"label":    {"label", "lbl", "field-label", "caption"},
		"input":    {"input", "field", "control", "text", "entry"},
		"field":    {"group", "row-item", "item", "field-box"},
		"button":   {"btn", "submit", "action", "button", "cta"},
		"error":    {"error", "alert", "notice", "msg", "warn"},
		"time":     {"time", "clock", "stamp", "server-time", "meta"},
		"help":     {"help", "forgot", "link", "assist", "recover"},
		"row":      {"row", "options", "inline", "check-row"},
		"check":    {"check", "tick", "box-input", "toggle"},
		"remember": {"remember", "keep", "stay", "check-label"},
		"footer":   {"footer", "foot", "legal", "bottom", "copy"},
		"user":     {"user", "login", "account", "uid", "name-field"},
		"pass":     {"pass", "pwd", "secret", "pw", "password-field"},
		"clock":    {"clock", "now", "ticker", "time-value", "stamp"},
	}
)

func (g *pageGen) word() string {
	var b strings.Builder
	n := 2 + g.r.IntN(2)
	for i := 0; i < n; i++ {
		b.WriteString(pick(g, onsets))
		b.WriteString(pick(g, vowels))
	}
	if g.chance(50) {
		b.WriteString(pick(g, codas))
	}
	return b.String()
}

func (g *pageGen) hex(n int) string {
	var b strings.Builder
	for i := 0; i < n; i++ {
		fmt.Fprintf(&b, "%x", g.r.IntN(16))
	}
	return b.String()
}

// name returns a unique class name or element id for the given role.
func (g *pageGen) name(role string) string {
	for {
		var s string
		switch g.idStyle {
		case 0:
			s = g.word()
		case 1:
			s = g.prefix + g.sep + g.hex(4+g.r.IntN(3))
		default:
			s = g.prefix + g.sep + pick(g, roleNouns[role])
		}
		if g.used[s] {
			s += g.sep + g.hex(3)
			if g.used[s] {
				continue
			}
		}
		g.used[s] = true
		return s
	}
}

var jsReserved = map[string]bool{"delete": true, "default": true, "super": true, "tele": true}

// jsName returns a JavaScript local identifier.
func (g *pageGen) jsName() string {
	for {
		var s string
		switch g.r.IntN(3) {
		case 0:
			s = g.word()
		case 1:
			s = "_" + g.word()
		default:
			s = g.word() + fmt.Sprint(g.r.IntN(10))
		}
		if jsReserved[s] || g.used["js:"+s] {
			continue
		}
		g.used["js:"+s] = true
		return s
	}
}

// ---- text pools -------------------------------------------------------------

var (
	subtitles = []string{"Sign in to continue", "Please log in to your account", "Log in to access your workspace", "Welcome back, please sign in", "Enter your credentials to continue", "Sign in to your account"}
	userLabel = []string{"Username", "Login", "User name", "Email or username", "User ID"}
	passLabel = []string{"Password", "Your password", "Passphrase", "Account password"}
	buttons   = []string{"Sign in", "Log in", "Continue", "Sign in to account", "Login"}
	titles    = []string{"%s", "Sign in | %s", "%s - Sign in", "Log in - %s", "%s | Login"}

	invalidMsgs = []string{
		"The username or password is incorrect. Please try again.",
		"Incorrect username or password. Please try again.",
		"Your login or password is incorrect. Try again.",
		"Sorry, the credentials you entered are incorrect. Please try again.",
		"The login details are incorrect. Check them and try again.",
	}
	throttledMsgs = []string{
		"Too many attempts, please try again later.",
		"Too many failed sign-in attempts. Please try again later.",
		"Too many login attempts. Try again in a few minutes.",
		"You have made too many attempts. Please wait and try again later.",
		"Too many requests for this account. Please try again later.",
	}
	clockLabels = []string{"Server time", "Current time", "Local time", "System time", "Server clock"}
	clockSeps   = []string{": ", ": ", " - ", " "}

	helpTexts   = []string{"Forgot password?", "Forgot your password?", "Need help?", "Need help signing in?", "Trouble signing in?", "Reset password"}
	rememberTxt = []string{"Remember me", "Keep me signed in", "Stay signed in", "Remember this device", "Keep me logged in"}
	rememberNms = []string{"remember", "persist", "keep", "stay", "rm", "trust"}
	taglines    = []string{"Secure access to your workspace.", "Built for teams.", "Your data stays yours.", "All systems operational.", "Protected by industry-standard encryption."}
	userPh      = []string{"Enter your username", "name@company.com", "Your login", "Username"}
	passPh      = []string{"Enter your password", "Password", "••••••••", "Your password"}
	robotsVals  = []string{"index, follow", "index,follow", "all"}
)

// ---- output formatting ------------------------------------------------------

type emitter struct {
	sb    strings.Builder
	unit  string
	min   bool
	depth int
}

func (e *emitter) line(s string) {
	if e.min {
		e.sb.WriteString(s)
		return
	}
	for i := 0; i < e.depth; i++ {
		e.sb.WriteString(e.unit)
	}
	e.sb.WriteString(s)
	e.sb.WriteByte('\n')
}

func (e *emitter) open(s string)  { e.line(s); e.depth++ }
func (e *emitter) close(s string) { e.depth--; e.line(s) }

type cssRule struct {
	sel   string
	props []string
}

// ---- page -------------------------------------------------------------------

func (g *pageGen) attrs(parts ...string) string {
	if g.chance(60) {
		parts = shuffled(g, parts)
	}
	return strings.Join(parts, " ")
}

func (g *pageGen) build() string {
	// Layout choices.
	e := &emitter{}
	switch g.r.IntN(5) {
	case 0:
		e.unit = "" // flat: newlines, no indentation
	case 1:
		e.unit = "  "
	case 2:
		e.unit = "    "
	case 3:
		e.unit = "\t"
	default:
		e.min = true
	}
	cssMode := g.r.IntN(3)
	if e.min {
		cssMode = 0
	}
	g.idStyle = g.r.IntN(3)
	g.prefix = pick(g, prefixes)
	g.sep = pick(g, seps)
	if g.idStyle == 1 {
		g.prefix = pick(g, []string{"c", "x", "u", "ui", "js", "v", "el"})
		g.sep = pick(g, []string{"-", "_", ""})
	}
	selfClose := g.chance(25)
	void := func(s string) string { // closes a void element
		if selfClose {
			return s + " />"
		}
		return s + ">"
	}

	// Optional features and wording.
	hasHelp, hasRemember, hasFooter := g.chance(55), g.chance(40), g.chance(60)
	helpAfterForm := g.chance(50)
	footCopy := g.chance(80)
	footTag := !footCopy || g.chance(40)
	fieldWrap := g.chance(35)
	h1Class, btnClass := g.chance(60), g.chance(60)
	userPlaceholder, passPlaceholder := g.chance(45), g.chance(45)
	wrappers := pick(g, []int{0, 0, 1, 1, 2})
	cardTag := pick(g, []string{"main", "section", "div"})
	subTag, errTag, timeTag := pick(g, []string{"p", "div"}), pick(g, []string{"div", "p"}), pick(g, []string{"div", "p"})
	footTagName := pick(g, []string{"footer", "div", "p"})
	subText, userText, passText := pick(g, subtitles), pick(g, userLabel), pick(g, passLabel)
	btnText, invalidText, throttledText := pick(g, buttons), pick(g, invalidMsgs), pick(g, throttledMsgs)
	clockText := pick(g, clockLabels) + pick(g, clockSeps)
	titleFmt := pick(g, titles)
	robots := pick(g, robotsVals)
	charset := pick(g, []string{"utf-8", "UTF-8"})
	doctype := pick(g, []string{"<!DOCTYPE html>", "<!doctype html>"})
	copySign := pick(g, []string{"©", "&copy;"})
	rightsTxt := ""
	if g.chance(40) {
		rightsTxt = " All rights reserved."
	}

	// Names. The draw order is fixed so the output depends on the seed only.
	cWrap := []string{g.name("wrap"), g.name("wrap")}
	cCard, cTitle, cSub := g.name("card"), g.name("title"), g.name("sub")
	cLabel, cInput, cField := g.name("label"), g.name("input"), g.name("field")
	cBtn, cErr, cTime := g.name("button"), g.name("error"), g.name("time")
	cHelp, cRow, cCheck, cRemember, cFoot := g.name("help"), g.name("row"), g.name("check"), g.name("remember"), g.name("footer")
	idUser, idPass, idClock, idRemember := g.name("user"), g.name("pass"), g.name("clock"), g.name("check")
	rememberName := pick(g, rememberNms)

	sel := func(useClass bool, tag, class string) string {
		if useClass {
			return "." + class
		}
		return tag
	}
	selTitle, selBtn := sel(h1Class, "h1", cTitle), sel(btnClass, "button", cBtn)

	// CSS (same look as always; rule and property order vary).
	rules := []cssRule{
		{"body", []string{"margin:0", "min-height:100vh", "display:flex", "align-items:center", "justify-content:center", "background:#f3f5f9", `font-family:system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif`, "color:#1f2937"}},
		{"." + cCard, []string{"width:100%", "max-width:380px", "margin:16px", "background:#fff", "border-radius:10px", "box-shadow:0 8px 30px rgba(15,23,42,.1)", "padding:36px 32px"}},
		{selTitle, []string{"margin:0 0 4px", "font-size:24px", "color:#0f3d91"}},
		{"." + cSub, []string{"margin:0 0 24px", "color:#6b7280", "font-size:14px"}},
		{"." + cLabel, []string{"display:block", "font-size:13px", "font-weight:600", "margin:14px 0 6px"}},
		{"." + cInput, []string{"width:100%", "padding:10px 12px", "border:1px solid #cbd5e1", "border-radius:6px", "font-size:15px"}},
		{"." + cInput + ":focus", []string{"outline:2px solid #bcd0f7", "border-color:#2563eb"}},
		{selBtn, []string{"width:100%", "margin-top:22px", "padding:11px", "background:#2563eb", "color:#fff", "border:0", "border-radius:6px", "font-size:15px", "font-weight:600", "cursor:pointer"}},
		{selBtn + ":hover", []string{"background:#1d4ed8"}},
		{"." + cErr, []string{"background:#fef2f2", "border:1px solid #fecaca", "color:#b91c1c", "padding:10px 12px", "border-radius:6px", "font-size:14px", "margin:0 0 6px"}},
		{"." + cTime, []string{"margin:24px 0 0", "text-align:center", "color:#6b7280", "font-size:12px"}},
	}
	for i := 0; i < wrappers; i++ {
		rules = append(rules, cssRule{"." + cWrap[i], []string{"width:100%", "display:flex", "justify-content:center"}})
	}
	if fieldWrap {
		rules = append(rules, cssRule{"." + cField, []string{"position:relative"}})
	}
	if hasHelp {
		rules = append(rules, cssRule{"." + cHelp, []string{"display:block", "margin-top:14px", "font-size:13px", "color:#2563eb", "text-decoration:none", "text-align:" + pick(g, []string{"center", "right", "left"})}})
	}
	if hasRemember {
		rules = append(rules,
			cssRule{"." + cRow, []string{"display:flex", "align-items:center", "gap:8px", "margin-top:14px"}},
			cssRule{"." + cCheck, []string{"width:16px", "height:16px", "margin:0"}},
			cssRule{"." + cRemember, []string{"font-size:13px", "color:#4b5563"}})
	}
	if hasFooter {
		rules = append(rules, cssRule{"." + cFoot, []string{"margin:20px 0 0", "text-align:center", "font-size:12px", "color:#9ca3af"}})
	}
	rules = shuffled(g, rules)
	universal := cssRule{"*", []string{"box-sizing:border-box"}}
	if g.chance(60) {
		rules = append([]cssRule{universal}, rules...)
	} else {
		rules = append(rules, cssRule{"*, *::before, *::after", []string{"box-sizing:border-box"}})
	}

	// ---- head items ----
	nonceAttr := `nonce="{{.Nonce}}"`
	meta := func(parts ...string) string { return void("<meta " + g.attrs(parts...)) }
	items := []string{
		"<title>" + fmt.Sprintf(titleFmt, "{{.AppName}}") + "</title>",
		meta(`name="description"`, `content="{{.Description}}"`),
		meta(`name="keywords"`, `content="{{.Keywords}}"`),
		meta(`name="robots"`, `content="`+robots+`"`),
		"{{if .BaseURL}}" + void(`<link `+g.attrs(`rel="canonical"`, `href="{{.BaseURL}}"`)) + "{{end}}",
		meta(`property="og:title"`, `content="{{.AppName}}"`),
		meta(`property="og:description"`, `content="{{.Description}}"`),
		meta(`property="og:type"`, `content="website"`),
		"{{if .BaseURL}}" + meta(`property="og:url"`, `content="{{.BaseURL}}"`) + "{{end}}",
		meta(`name="twitter:card"`, `content="summary"`),
		meta(`name="twitter:title"`, `content="{{.AppName}}"`),
		meta(`name="twitter:description"`, `content="{{.Description}}"`),
		"<script " + g.attrs(`type="application/ld+json"`, nonceAttr) + ">{{.JSONLD}}</script>",
	}
	items = shuffled(g, items)
	viewport := meta(`name="viewport"`, `content="width=device-width, initial-scale=1"`)
	head := []string{void(`<meta charset="` + charset + `"`)}
	// viewport sits in the first three positions, the rest is shuffled.
	vp := g.r.IntN(3)
	if vp > len(items) {
		vp = len(items)
	}
	head = append(head, items[:vp]...)
	head = append(head, viewport)
	head = append(head, items[vp:]...)

	// ---- document ----
	e.line(doctype)
	e.open(`<html lang="en">`)
	e.open("<head>")
	for _, h := range head[:1] {
		e.line(h)
	}
	styleAt := 3 + g.r.IntN(len(head)-2) // position of <style> among the rest
	for i, h := range head[1:] {
		if i+1 == styleAt {
			g.emitStyle(e, rules, cssMode, nonceAttr)
		}
		e.line(h)
	}
	if styleAt >= len(head) {
		g.emitStyle(e, rules, cssMode, nonceAttr)
	}
	e.close("</head>")
	e.open("<body>")

	// wrappers
	wrapTags := make([]string, wrappers)
	for i := range wrapTags {
		wrapTags[i] = pick(g, []string{"div", "section", "div"})
		e.open(`<` + wrapTags[i] + ` class="` + cWrap[i] + `">`)
	}
	e.open("<" + cardTag + ` class="` + cCard + `">`)

	if h1Class {
		e.line("<h1 " + `class="` + cTitle + `">{{.AppName}}</h1>`)
	} else {
		e.line("<h1>{{.AppName}}</h1>")
	}
	e.line("<" + subTag + ` class="` + cSub + `">` + subText + "</" + subTag + ">")

	e.line("{{if .State}}")
	e.open("<" + errTag + " " + g.attrs(`class="`+cErr+`"`, `role="alert"`) + ">")
	e.line(`{{if eq .State "throttled"}}` + throttledText + `{{else}}` + invalidText + `{{end}}`)
	e.close("</" + errTag + ">")
	e.line("{{end}}")

	helpLink := ""
	if hasHelp {
		helpLink = "<a " + g.attrs(`href="/"`, `class="`+cHelp+`"`) + ">" + pick(g, helpTexts) + "</a>"
	}
	field := func(id, name, typ, auto, label, class, placeholder string, ph bool) {
		if fieldWrap {
			e.open(`<div class="` + cField + `">`)
		}
		e.line("<label " + g.attrs(`for="`+id+`"`, `class="`+class+`"`) + ">" + label + "</label>")
		in := []string{`id="` + id + `"`, `name="` + name + `"`, `type="` + typ + `"`, `autocomplete="` + auto + `"`, "required", `class="` + cInput + `"`}
		if ph {
			in = append(in, `placeholder="`+placeholder+`"`)
		}
		e.line("<input " + g.attrs(in...) + ">")
		if fieldWrap {
			e.close("</div>")
		}
	}

	e.line("{{if not .HideForm}}")
	e.open("<form " + g.attrs(`method="post"`, `action="/login"`, `autocomplete="on"`) + ">")
	field(idUser, "username", "text", "username", userText, cLabel, pick(g, userPh), userPlaceholder)
	field(idPass, "password", "password", "current-password", passText, cLabel, pick(g, passPh), passPlaceholder)
	if hasRemember {
		e.open(`<div class="` + cRow + `">`)
		e.line("<input " + g.attrs(`type="checkbox"`, `id="`+idRemember+`"`, `name="`+rememberName+`"`, `class="`+cCheck+`"`) + ">")
		e.line("<label " + g.attrs(`for="`+idRemember+`"`, `class="`+cRemember+`"`) + ">" + pick(g, rememberTxt) + "</label>")
		e.close("</div>")
	}
	if btnClass {
		e.line("<button " + g.attrs(`type="submit"`, `class="`+cBtn+`"`) + ">" + btnText + "</button>")
	} else {
		e.line(`<button type="submit">` + btnText + `</button>`)
	}
	if hasHelp && !helpAfterForm {
		e.line(helpLink)
	}
	e.close("</form>")
	if hasHelp && helpAfterForm {
		e.line(helpLink)
	}
	e.line("{{end}}")

	e.line("<" + timeTag + ` class="` + cTime + `">` + clockText +
		"<span " + g.attrs(`id="`+idClock+`"`, `data-ts="{{.UnixMilli}}"`, `data-off="{{.OffsetSec}}"`) + ">{{.Time}}</span></" + timeTag + ">")

	if hasFooter {
		var parts []string
		if footCopy {
			parts = append(parts, copySign+" {{.Year}} {{.AppName}}."+rightsTxt)
		}
		if footTag {
			parts = append(parts, pick(g, taglines))
		}
		e.line("<" + footTagName + ` class="` + cFoot + `">` + strings.Join(parts, " ") + "</" + footTagName + ">")
	}

	e.close("</" + cardTag + ">")
	for i := wrappers - 1; i >= 0; i-- {
		e.close("</" + wrapTags[i] + ">")
	}

	g.emitScript(e, idClock, nonceAttr)
	e.close("</body>")
	e.close("</html>")
	return e.sb.String()
}

func (g *pageGen) emitStyle(e *emitter, rules []cssRule, mode int, nonceAttr string) {
	e.open("<style " + nonceAttr + ">")
	for _, r := range rules {
		props := shuffled(g, r.props)
		switch mode {
		case 0:
			e.line(r.sel + "{" + strings.Join(props, ";") + "}")
		case 1:
			sp := make([]string, len(props))
			for i, p := range props {
				sp[i] = strings.Replace(p, ":", ": ", 1) + ";"
			}
			e.line(r.sel + " { " + strings.Join(sp, " ") + " }")
		default:
			e.open(r.sel + " {")
			for _, p := range props {
				e.line(strings.Replace(p, ":", ": ", 1) + ";")
			}
			e.close("}")
		}
	}
	e.close("</style>")
}

func (g *pageGen) emitScript(e *emitter, clockID, nonceAttr string) {
	el, off, zone, pad, tick := g.jsName(), g.jsName(), g.jsName(), g.jsName(), g.jsName()
	decl := pick(g, []string{"var", "const", "let"})
	eq := "="
	if !e.min && g.chance(50) {
		eq = " = "
	}
	arrow := g.chance(50)
	e.open("<script " + nonceAttr + ">")
	if arrow {
		e.open("(() => {")
	} else {
		e.open("(function(){")
	}
	e.line(decl + " " + el + eq + `document.getElementById("` + clockID + `");`)
	if g.chance(50) {
		e.line(decl + " " + off + eq + "Date.now()-Number(" + el + ".dataset.ts);")
		e.line(decl + " " + zone + eq + "Number(" + el + ".dataset.off)*1000;")
	} else {
		e.line(decl + " " + off + eq + "Date.now()-Number(" + el + ".dataset.ts), " + zone + eq + "Number(" + el + ".dataset.off)*1000;")
	}
	var format string
	if g.chance(50) {
		if arrow {
			e.line(decl + " " + pad + eq + `n=>(n<10?"0":"")+n;`)
		} else {
			e.line("function " + pad + `(n){return (n<10?"0":"")+n}`)
		}
		format = `d.getUTCFullYear()+"-"+` + pad + `(d.getUTCMonth()+1)+"-"+` + pad + `(d.getUTCDate())+" "+` +
			pad + `(d.getUTCHours())+":"+` + pad + `(d.getUTCMinutes())+":"+` + pad + `(d.getUTCSeconds())`
	} else {
		format = `d.toISOString().slice(0,19).replace("T"," ")`
	}
	if arrow {
		e.open(decl + " " + tick + eq + "()=>{")
	} else {
		e.open("function " + tick + "(){")
	}
	e.line(decl + " d" + eq + "new Date(Date.now()-" + off + "+" + zone + ");")
	e.line(el + ".textContent" + eq + format + ";")
	if arrow {
		e.close("};")
	} else {
		e.close("}")
	}
	if g.chance(30) {
		e.line(tick + "();")
	}
	e.line("setInterval(" + tick + ",1000);")
	e.close("})();")
	e.close("</script>")
}
