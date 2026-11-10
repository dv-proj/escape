#!/usr/bin/env python3
"""Generate the decoy login page (a Go html/template) for fake-webapp.

Port of pagegen.go. Usage:

    python3 login.py --seed HEX [--out PATH] [--force]

The output is deterministic for a given seed (it does not match the Go
generator byte for byte). Template fields used: .AppName .Description
.Keywords .BaseURL .JSONLD .Nonce .State .Year .HideForm .Time .UnixMilli
.OffsetSec; .State is "", "invalid" or "throttled".
"""

import argparse
import hashlib
import os
import random
import re
import sys
import tempfile

SEED_RE = re.compile(r"^[0-9a-f]{16,64}$")

# ---- identifiers ------------------------------------------------------------

ONSETS = ["b", "d", "f", "g", "k", "l", "m", "n", "p", "r", "s", "t", "v", "z",
          "br", "tr", "st", "pl", "kr", "fl", "gr", "sk"]
VOWELS = ["a", "e", "i", "o", "u"]
CODAS = ["n", "r", "x", "k", "m", "l", "s"]

PREFIXES = ["auth", "login", "sign", "access", "acct", "app", "portal", "ui",
            "gate", "secure", "user", "entry", "sso", "lg"]
SEPS = ["-", "__", "_", "-"]

ROLE_NOUNS = {
    "wrap": ["wrap", "outer", "shell", "layout", "container"],
    "card": ["card", "panel", "box", "dialog", "main", "form-box"],
    "title": ["title", "heading", "brand", "name", "head"],
    "sub": ["sub", "lead", "hint", "subtitle", "intro", "caption"],
    "label": ["label", "lbl", "field-label", "caption"],
    "input": ["input", "field", "control", "text", "entry"],
    "field": ["group", "row-item", "item", "field-box"],
    "button": ["btn", "submit", "action", "button", "cta"],
    "error": ["error", "alert", "notice", "msg", "warn"],
    "time": ["time", "clock", "stamp", "server-time", "meta"],
    "help": ["help", "forgot", "link", "assist", "recover"],
    "row": ["row", "options", "inline", "check-row"],
    "check": ["check", "tick", "box-input", "toggle"],
    "remember": ["remember", "keep", "stay", "check-label"],
    "footer": ["footer", "foot", "legal", "bottom", "copy"],
    "user": ["user", "login", "account", "uid", "name-field"],
    "pass": ["pass", "pwd", "secret", "pw", "password-field"],
    "clock": ["clock", "now", "ticker", "time-value", "stamp"],
}

JS_RESERVED = {"delete", "default", "super", "tele"}

# ---- text pools -------------------------------------------------------------

SUBTITLES = ["Sign in to continue", "Please log in to your account", "Log in to access your workspace", "Welcome back, please sign in", "Enter your credentials to continue", "Sign in to your account"]
USER_LABEL = ["Username", "Login", "User name", "Email or username", "User ID"]
PASS_LABEL = ["Password", "Your password", "Passphrase", "Account password"]
BUTTONS = ["Sign in", "Log in", "Continue", "Sign in to account", "Login"]
TITLES = ["%s", "Sign in | %s", "%s - Sign in", "Log in - %s", "%s | Login"]

INVALID_MSGS = [
    "The username or password is incorrect. Please try again.",
    "Incorrect username or password. Please try again.",
    "Your login or password is incorrect. Try again.",
    "Sorry, the credentials you entered are incorrect. Please try again.",
    "The login details are incorrect. Check them and try again.",
]
THROTTLED_MSGS = [
    "Too many attempts, please try again later.",
    "Too many failed sign-in attempts. Please try again later.",
    "Too many login attempts. Try again in a few minutes.",
    "You have made too many attempts. Please wait and try again later.",
    "Too many requests for this account. Please try again later.",
]
CLOCK_LABELS = ["Server time", "Current time", "Local time", "System time", "Server clock"]
CLOCK_SEPS = [": ", ": ", " - ", " "]

HELP_TEXTS = ["Forgot password?", "Forgot your password?", "Need help?", "Need help signing in?", "Trouble signing in?", "Reset password"]
REMEMBER_TXT = ["Remember me", "Keep me signed in", "Stay signed in", "Remember this device", "Keep me logged in"]
REMEMBER_NMS = ["remember", "persist", "keep", "stay", "rm", "trust"]
TAGLINES = ["Secure access to your workspace.", "Built for teams.", "Your data stays yours.", "All systems operational.", "Protected by industry-standard encryption."]
USER_PH = ["Enter your username", "name@company.com", "Your login", "Username"]
PASS_PH = ["Enter your password", "Password", "••••••••", "Your password"]
ROBOTS_VALS = ["index, follow", "index,follow", "all"]


# ---- output formatting ------------------------------------------------------

class Emitter:
    def __init__(self):
        self.parts = []
        self.unit = ""
        self.min = False
        self.depth = 0

    def line(self, s):
        if self.min:
            self.parts.append(s)
            return
        self.parts.append(self.unit * self.depth + s + "\n")

    def open(self, s):
        self.line(s)
        self.depth += 1

    def close(self, s):
        self.depth -= 1
        self.line(s)

    def text(self):
        return "".join(self.parts)


class PageGen:
    def __init__(self, seed):
        digest = hashlib.sha256(("page:" + seed).encode("utf-8")).digest()
        self.r = random.Random(int.from_bytes(digest, "big"))
        self.used = set()
        self.id_style = 0
        self.prefix = ""
        self.sep = ""

    # random helpers
    def intn(self, n):
        return self.r.randrange(n)

    def pick(self, s):
        return s[self.intn(len(s))]

    def chance(self, percent):
        return self.intn(100) < percent

    def shuffled(self, s):
        out = list(s)
        self.r.shuffle(out)
        return out

    # identifiers
    def word(self):
        n = 2 + self.intn(2)
        b = []
        for _ in range(n):
            b.append(self.pick(ONSETS))
            b.append(self.pick(VOWELS))
        if self.chance(50):
            b.append(self.pick(CODAS))
        return "".join(b)

    def hex(self, n):
        return "".join("%x" % self.intn(16) for _ in range(n))

    def name(self, role):
        """Unique class name or element id for the given role."""
        while True:
            if self.id_style == 0:
                s = self.word()
            elif self.id_style == 1:
                s = self.prefix + self.sep + self.hex(4 + self.intn(3))
            else:
                s = self.prefix + self.sep + self.pick(ROLE_NOUNS[role])
            if s in self.used:
                s += self.sep + self.hex(3)
                if s in self.used:
                    continue
            self.used.add(s)
            return s

    def js_name(self):
        while True:
            k = self.intn(3)
            if k == 0:
                s = self.word()
            elif k == 1:
                s = "_" + self.word()
            else:
                s = self.word() + str(self.intn(10))
            if s in JS_RESERVED or ("js:" + s) in self.used:
                continue
            self.used.add("js:" + s)
            return s

    def attrs(self, *parts):
        parts = list(parts)
        if self.chance(60):
            parts = self.shuffled(parts)
        return " ".join(parts)

    # page
    def build(self):
        g = self
        e = Emitter()
        k = g.intn(5)
        if k == 0:
            e.unit = ""
        elif k == 1:
            e.unit = "  "
        elif k == 2:
            e.unit = "    "
        elif k == 3:
            e.unit = "\t"
        else:
            e.min = True
        css_mode = g.intn(3)
        if e.min:
            css_mode = 0
        g.id_style = g.intn(3)
        g.prefix = g.pick(PREFIXES)
        g.sep = g.pick(SEPS)
        if g.id_style == 1:
            g.prefix = g.pick(["c", "x", "u", "ui", "js", "v", "el"])
            g.sep = g.pick(["-", "_", ""])
        self_close = g.chance(25)

        def void(s):
            return s + (" />" if self_close else ">")

        # Optional features and wording.
        has_help, has_remember, has_footer = g.chance(55), g.chance(40), g.chance(60)
        help_after_form = g.chance(50)
        foot_copy = g.chance(80)
        foot_tag = (not foot_copy) or g.chance(40)
        field_wrap = g.chance(35)
        h1_class, btn_class = g.chance(60), g.chance(60)
        user_placeholder, pass_placeholder = g.chance(45), g.chance(45)
        wrappers = g.pick([0, 0, 1, 1, 2])
        card_tag = g.pick(["main", "section", "div"])
        sub_tag, err_tag, time_tag = g.pick(["p", "div"]), g.pick(["div", "p"]), g.pick(["div", "p"])
        foot_tag_name = g.pick(["footer", "div", "p"])
        sub_text, user_text, pass_text = g.pick(SUBTITLES), g.pick(USER_LABEL), g.pick(PASS_LABEL)
        btn_text, invalid_text, throttled_text = g.pick(BUTTONS), g.pick(INVALID_MSGS), g.pick(THROTTLED_MSGS)
        clock_text = g.pick(CLOCK_LABELS) + g.pick(CLOCK_SEPS)
        title_fmt = g.pick(TITLES)
        robots = g.pick(ROBOTS_VALS)
        charset = g.pick(["utf-8", "UTF-8"])
        doctype = g.pick(["<!DOCTYPE html>", "<!doctype html>"])
        copy_sign = g.pick(["©", "&copy;"])
        rights_txt = " All rights reserved." if g.chance(40) else ""

        # Names. The draw order is fixed so the output depends on the seed only.
        c_wrap = [g.name("wrap"), g.name("wrap")]
        c_card, c_title, c_sub = g.name("card"), g.name("title"), g.name("sub")
        c_label, c_input, c_field = g.name("label"), g.name("input"), g.name("field")
        c_btn, c_err, c_time = g.name("button"), g.name("error"), g.name("time")
        c_help, c_row, c_check, c_remember, c_foot = (
            g.name("help"), g.name("row"), g.name("check"), g.name("remember"), g.name("footer"))
        id_user, id_pass, id_clock, id_remember = (
            g.name("user"), g.name("pass"), g.name("clock"), g.name("check"))
        remember_name = g.pick(REMEMBER_NMS)

        def sel(use_class, tag, cls):
            return "." + cls if use_class else tag

        sel_title, sel_btn = sel(h1_class, "h1", c_title), sel(btn_class, "button", c_btn)

        # CSS (same look as always; rule and property order vary).
        rules = [
            ("body", ["margin:0", "min-height:100vh", "display:flex", "align-items:center", "justify-content:center", "background:#f3f5f9", 'font-family:system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif', "color:#1f2937"]),
            ("." + c_card, ["width:100%", "max-width:380px", "margin:16px", "background:#fff", "border-radius:10px", "box-shadow:0 8px 30px rgba(15,23,42,.1)", "padding:36px 32px"]),
            (sel_title, ["margin:0 0 4px", "font-size:24px", "color:#0f3d91"]),
            ("." + c_sub, ["margin:0 0 24px", "color:#6b7280", "font-size:14px"]),
            ("." + c_label, ["display:block", "font-size:13px", "font-weight:600", "margin:14px 0 6px"]),
            ("." + c_input, ["width:100%", "padding:10px 12px", "border:1px solid #cbd5e1", "border-radius:6px", "font-size:15px"]),
            ("." + c_input + ":focus", ["outline:2px solid #bcd0f7", "border-color:#2563eb"]),
            (sel_btn, ["width:100%", "margin-top:22px", "padding:11px", "background:#2563eb", "color:#fff", "border:0", "border-radius:6px", "font-size:15px", "font-weight:600", "cursor:pointer"]),
            (sel_btn + ":hover", ["background:#1d4ed8"]),
            ("." + c_err, ["background:#fef2f2", "border:1px solid #fecaca", "color:#b91c1c", "padding:10px 12px", "border-radius:6px", "font-size:14px", "margin:0 0 6px"]),
            ("." + c_time, ["margin:24px 0 0", "text-align:center", "color:#6b7280", "font-size:12px"]),
        ]
        for i in range(wrappers):
            rules.append(("." + c_wrap[i], ["width:100%", "display:flex", "justify-content:center"]))
        if field_wrap:
            rules.append(("." + c_field, ["position:relative"]))
        if has_help:
            rules.append(("." + c_help, ["display:block", "margin-top:14px", "font-size:13px", "color:#2563eb", "text-decoration:none", "text-align:" + g.pick(["center", "right", "left"])]))
        if has_remember:
            rules.append(("." + c_row, ["display:flex", "align-items:center", "gap:8px", "margin-top:14px"]))
            rules.append(("." + c_check, ["width:16px", "height:16px", "margin:0"]))
            rules.append(("." + c_remember, ["font-size:13px", "color:#4b5563"]))
        if has_footer:
            rules.append(("." + c_foot, ["margin:20px 0 0", "text-align:center", "font-size:12px", "color:#9ca3af"]))
        rules = g.shuffled(rules)
        universal = ("*", ["box-sizing:border-box"])
        if g.chance(60):
            rules = [universal] + rules
        else:
            rules.append(("*, *::before, *::after", ["box-sizing:border-box"]))

        # ---- head items ----
        nonce_attr = 'nonce="{{.Nonce}}"'

        def meta(*parts):
            return void("<meta " + g.attrs(*parts))

        items = [
            "<title>" + title_fmt.replace("%s", "{{.AppName}}") + "</title>",
            meta('name="description"', 'content="{{.Description}}"'),
            meta('name="keywords"', 'content="{{.Keywords}}"'),
            meta('name="robots"', 'content="' + robots + '"'),
            "{{if .BaseURL}}" + void("<link " + g.attrs('rel="canonical"', 'href="{{.BaseURL}}"')) + "{{end}}",
            meta('property="og:title"', 'content="{{.AppName}}"'),
            meta('property="og:description"', 'content="{{.Description}}"'),
            meta('property="og:type"', 'content="website"'),
            "{{if .BaseURL}}" + meta('property="og:url"', 'content="{{.BaseURL}}"') + "{{end}}",
            meta('name="twitter:card"', 'content="summary"'),
            meta('name="twitter:title"', 'content="{{.AppName}}"'),
            meta('name="twitter:description"', 'content="{{.Description}}"'),
            "<script " + g.attrs('type="application/ld+json"', nonce_attr) + ">{{.JSONLD}}</script>",
        ]
        items = g.shuffled(items)
        viewport = meta('name="viewport"', 'content="width=device-width, initial-scale=1"')
        head = [void('<meta charset="' + charset + '"')]
        # viewport sits in the first three positions, the rest is shuffled.
        vp = min(g.intn(3), len(items))
        head += items[:vp]
        head.append(viewport)
        head += items[vp:]

        # ---- document ----
        e.line(doctype)
        e.open('<html lang="en">')
        e.open("<head>")
        e.line(head[0])
        style_at = 3 + g.intn(len(head) - 2)  # position of <style> among the rest
        for i, h in enumerate(head[1:]):
            if i + 1 == style_at:
                g.emit_style(e, rules, css_mode, nonce_attr)
            e.line(h)
        if style_at >= len(head):
            g.emit_style(e, rules, css_mode, nonce_attr)
        e.close("</head>")
        e.open("<body>")

        # wrappers
        wrap_tags = []
        for i in range(wrappers):
            wrap_tags.append(g.pick(["div", "section", "div"]))
            e.open("<" + wrap_tags[i] + ' class="' + c_wrap[i] + '">')
        e.open("<" + card_tag + ' class="' + c_card + '">')

        if h1_class:
            e.line('<h1 class="' + c_title + '">{{.AppName}}</h1>')
        else:
            e.line("<h1>{{.AppName}}</h1>")
        e.line("<" + sub_tag + ' class="' + c_sub + '">' + sub_text + "</" + sub_tag + ">")

        e.line("{{if .State}}")
        e.open("<" + err_tag + " " + g.attrs('class="' + c_err + '"', 'role="alert"') + ">")
        e.line('{{if eq .State "throttled"}}' + throttled_text + "{{else}}" + invalid_text + "{{end}}")
        e.close("</" + err_tag + ">")
        e.line("{{end}}")

        help_link = ""
        if has_help:
            help_link = "<a " + g.attrs('href="/"', 'class="' + c_help + '"') + ">" + g.pick(HELP_TEXTS) + "</a>"

        def field(id_, name, typ, auto, label, cls, placeholder, ph):
            if field_wrap:
                e.open('<div class="' + c_field + '">')
            e.line("<label " + g.attrs('for="' + id_ + '"', 'class="' + cls + '"') + ">" + label + "</label>")
            inp = ['id="' + id_ + '"', 'name="' + name + '"', 'type="' + typ + '"',
                   'autocomplete="' + auto + '"', "required", 'class="' + c_input + '"']
            if ph:
                inp.append('placeholder="' + placeholder + '"')
            e.line("<input " + g.attrs(*inp) + ">")
            if field_wrap:
                e.close("</div>")

        e.line("{{if not .HideForm}}")
        e.open("<form " + g.attrs('method="post"', 'action="/login"', 'autocomplete="on"') + ">")
        field(id_user, "username", "text", "username", user_text, c_label, g.pick(USER_PH), user_placeholder)
        field(id_pass, "password", "password", "current-password", pass_text, c_label, g.pick(PASS_PH), pass_placeholder)
        if has_remember:
            e.open('<div class="' + c_row + '">')
            e.line("<input " + g.attrs('type="checkbox"', 'id="' + id_remember + '"', 'name="' + remember_name + '"', 'class="' + c_check + '"') + ">")
            e.line("<label " + g.attrs('for="' + id_remember + '"', 'class="' + c_remember + '"') + ">" + g.pick(REMEMBER_TXT) + "</label>")
            e.close("</div>")
        if btn_class:
            e.line("<button " + g.attrs('type="submit"', 'class="' + c_btn + '"') + ">" + btn_text + "</button>")
        else:
            e.line('<button type="submit">' + btn_text + "</button>")
        if has_help and not help_after_form:
            e.line(help_link)
        e.close("</form>")
        if has_help and help_after_form:
            e.line(help_link)
        e.line("{{end}}")

        e.line("<" + time_tag + ' class="' + c_time + '">' + clock_text +
               "<span " + g.attrs('id="' + id_clock + '"', 'data-ts="{{.UnixMilli}}"', 'data-off="{{.OffsetSec}}"') +
               ">{{.Time}}</span></" + time_tag + ">")

        if has_footer:
            parts = []
            if foot_copy:
                parts.append(copy_sign + " {{.Year}} {{.AppName}}." + rights_txt)
            if foot_tag:
                parts.append(g.pick(TAGLINES))
            e.line("<" + foot_tag_name + ' class="' + c_foot + '">' + " ".join(parts) + "</" + foot_tag_name + ">")

        e.close("</" + card_tag + ">")
        for i in range(wrappers - 1, -1, -1):
            e.close("</" + wrap_tags[i] + ">")

        g.emit_script(e, id_clock, nonce_attr)
        e.close("</body>")
        e.close("</html>")
        return e.text()

    def emit_style(self, e, rules, mode, nonce_attr):
        e.open("<style " + nonce_attr + ">")
        for sel, plist in rules:
            props = self.shuffled(plist)
            if mode == 0:
                e.line(sel + "{" + ";".join(props) + "}")
            elif mode == 1:
                sp = [p.replace(":", ": ", 1) + ";" for p in props]
                e.line(sel + " { " + " ".join(sp) + " }")
            else:
                e.open(sel + " {")
                for p in props:
                    e.line(p.replace(":", ": ", 1) + ";")
                e.close("}")
        e.close("</style>")

    def emit_script(self, e, clock_id, nonce_attr):
        g = self
        el, off, zone, pad, tick = (g.js_name(), g.js_name(), g.js_name(), g.js_name(), g.js_name())
        decl = g.pick(["var", "const", "let"])
        eq = "="
        if not e.min and g.chance(50):
            eq = " = "
        arrow = g.chance(50)
        e.open("<script " + nonce_attr + ">")
        e.open("(() => {" if arrow else "(function(){")
        e.line(decl + " " + el + eq + 'document.getElementById("' + clock_id + '");')
        if g.chance(50):
            e.line(decl + " " + off + eq + "Date.now()-Number(" + el + ".dataset.ts);")
            e.line(decl + " " + zone + eq + "Number(" + el + ".dataset.off)*1000;")
        else:
            e.line(decl + " " + off + eq + "Date.now()-Number(" + el + ".dataset.ts), " + zone + eq + "Number(" + el + ".dataset.off)*1000;")
        if g.chance(50):
            if arrow:
                e.line(decl + " " + pad + eq + 'n=>(n<10?"0":"")+n;')
            else:
                e.line("function " + pad + '(n){return (n<10?"0":"")+n}')
            fmt = ('d.getUTCFullYear()+"-"+' + pad + '(d.getUTCMonth()+1)+"-"+' + pad + '(d.getUTCDate())+" "+' +
                   pad + '(d.getUTCHours())+":"+' + pad + '(d.getUTCMinutes())+":"+' + pad + "(d.getUTCSeconds())")
        else:
            fmt = 'd.toISOString().slice(0,19).replace("T"," ")'
        if arrow:
            e.open(decl + " " + tick + eq + "()=>{")
        else:
            e.open("function " + tick + "(){")
        e.line(decl + " d" + eq + "new Date(Date.now()-" + off + "+" + zone + ");")
        e.line(el + ".textContent" + eq + fmt + ";")
        e.close("};" if arrow else "}")
        if g.chance(30):
            e.line(tick + "();")
        e.line("setInterval(" + tick + ",1000);")
        e.close("})();")
        e.close("</script>")


def generate_page(seed):
    """Return the html/template source of the decoy login page for seed."""
    return PageGen(seed).build()


def write_atomic(path, data, mode=0o644):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".page-", suffix=".tmp", dir=d)
    ok = False
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
        ok = True
    finally:
        if not ok:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate the decoy login page template.")
    ap.add_argument("--seed", required=True, help="hex seed, 16-64 chars [0-9a-f]")
    ap.add_argument("--out", help="write the page to this file instead of stdout")
    ap.add_argument("--force", action="store_true", help="overwrite --out if it exists")
    args = ap.parse_args(argv)

    if not SEED_RE.match(args.seed):
        print("error: --seed must match ^[0-9a-f]{16,64}$", file=sys.stderr)
        return 2
    data = generate_page(args.seed).encode("utf-8")

    if args.out is None:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        return 0

    if os.path.lexists(args.out) and not args.force:
        print("error: %s already exists (use --force to overwrite)" % args.out, file=sys.stderr)
        return 1
    try:
        write_atomic(args.out, data)
    except OSError as exc:
        print("error: cannot write %s: %s" % (args.out, exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
