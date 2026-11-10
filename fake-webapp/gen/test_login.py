import hashlib
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import login  # noqa: E402

SCRIPT = os.path.join(HERE, "login.py")


def seed_n(i):
    return hashlib.sha256(("seed%d" % i).encode()).hexdigest()[:32]


def has_tag(b, tag, *frags):
    for m in re.findall(r"<" + tag + r"\b[^>]*>", b):
        if all(f in m for f in frags):
            return True
    return False


def render(src, state="", base="https://example.com"):
    """Minimal emulation of the Go template execution for the actions used."""
    s = src
    # {{if .BaseURL}}...{{end}}
    s = re.sub(r"\{\{if \.BaseURL\}\}(.*?)\{\{end\}\}",
               lambda m: m.group(1) if base else "", s, flags=re.S)
    hide = state == "throttled"
    # inner if/else on state
    s = re.sub(r'\{\{if eq \.State "throttled"\}\}(.*?)\{\{else\}\}(.*?)\{\{end\}\}',
               lambda m: m.group(1) if state == "throttled" else m.group(2), s, flags=re.S)
    s = re.sub(r"\{\{if \.State\}\}(.*?)\{\{end\}\}",
               lambda m: m.group(1) if state else "", s, flags=re.S)
    s = re.sub(r"\{\{if not \.HideForm\}\}(.*?)\{\{end\}\}",
               lambda m: "" if hide else m.group(1), s, flags=re.S)
    vals = {"AppName": "Test Portal", "Description": "Desc here", "Keywords": "k1, k2",
            "BaseURL": base, "JSONLD": '{"@type":"WebApplication"}', "Nonce": "NONCE123",
            "State": state, "Year": "2026", "Time": "2026-01-01 12:00:00",
            "UnixMilli": "1", "OffsetSec": "0"}
    return re.sub(r"\{\{\.(\w+)\}\}", lambda m: vals[m.group(1)], s)


class GeneratorTest(unittest.TestCase):
    def test_deterministic(self):
        self.assertEqual(login.generate_page(seed_n(1)), login.generate_page(seed_n(1)))
        self.assertNotEqual(login.generate_page(seed_n(1)), login.generate_page(seed_n(2)))

    def test_diversity(self):
        pages, classes = set(), set()
        for i in range(50):
            b = render(login.generate_page(seed_n(i)))
            pages.add(b)
            cs = set()
            for m in re.findall(r'class="([^"]*)"', b):
                cs.update(m.split())
            classes.add(" ".join(sorted(cs)))
        self.assertGreaterEqual(len(pages), 45)
        self.assertGreaterEqual(len(classes), 45)

    def test_variants_valid(self):
        for i in range(200):
            seed = seed_n(i)
            src = login.generate_page(seed)
            self.assertEqual(src.count("{{if"), src.count("{{end}}"))
            for base in ("https://example.com", ""):
                b = render(src, "", base)
                for what, ok in [
                    ("title", re.search(r"<title>[^<]*Test Portal[^<]*</title>", b)),
                    ("description", has_tag(b, "meta", 'name="description"', 'content="Desc here"')),
                    ("keywords", has_tag(b, "meta", 'name="keywords"', 'content="k1, k2"')),
                    ("robots", has_tag(b, "meta", 'name="robots"')),
                    ("og:title", has_tag(b, "meta", 'property="og:title"', 'content="Test Portal"')),
                    ("og:description", has_tag(b, "meta", 'property="og:description"', 'content="Desc here"')),
                    ("og:type", has_tag(b, "meta", 'property="og:type"', 'content="website"')),
                    ("twitter:card", has_tag(b, "meta", 'name="twitter:card"')),
                    ("viewport", has_tag(b, "meta", 'name="viewport"')),
                    ("charset", '<meta charset="utf-8"' in b.lower()),
                    ("ld+json", has_tag(b, "script", 'type="application/ld+json"', 'nonce="')),
                    ("style nonce", has_tag(b, "style", 'nonce="')),
                    ("script nonce", re.search(r'<script nonce="[^"]*">', b)),
                ]:
                    self.assertTrue(ok, "seed %s: missing %s" % (seed, what))
                if base:
                    self.assertTrue(has_tag(b, "link", 'rel="canonical"', 'href="%s"' % base))
                    self.assertTrue(has_tag(b, "meta", 'property="og:url"', 'content="%s"' % base))
                else:
                    self.assertNotIn("canonical", b)
                    self.assertNotIn("og:url", b)
                for want in ('name="username"', 'name="password"', 'action="/login"',
                             'method="post"', "NONCE123", "2026-01-01 12:00:00"):
                    self.assertIn(want, b, "seed %s" % seed)
                ids = re.findall(r'\bid="([^"]*)"', b)
                self.assertEqual(len(ids), len(set(ids)), "seed %s: duplicate id" % seed)
                fors = re.findall(r'<label[^>]*\bfor="([^"]*)"', b)
                self.assertGreaterEqual(len(fors), 2)
                for f in fors:
                    self.assertIn(f, ids)
                self.assertIn('getElementById("', b)
                self.assertNotIn("{{", b)
                self.assertNotIn("ZgotmplZ", b)

    def test_states(self):
        for i in range(200):
            seed = seed_n(i)
            src = login.generate_page(seed)
            inv = render(src, "invalid", "")
            li = inv.lower()
            self.assertTrue("incorrect" in li and "again" in li and 'role="alert"' in inv
                            and "<form" in inv, "seed %s: bad invalid page" % seed)
            thr = render(src, "throttled", "")
            self.assertTrue("too many" in thr.lower() and ("later" in thr or "minutes" in thr)
                            and "<form" not in thr and 'name="password"' not in thr,
                            "seed %s: bad throttled page" % seed)
            ok = render(src, "", "")
            lo = ok.lower()
            self.assertFalse("incorrect" in lo or "too many" in lo or 'role="alert"' in ok,
                             "seed %s: error text without state" % seed)


class CliTest(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True)

    def test_stdout(self):
        p = self.run_cli("--seed", "0123456789abcdef")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stderr, b"")
        self.assertEqual(p.stdout.decode("utf-8"), login.generate_page("0123456789abcdef"))
        self.assertEqual(p.stdout, self.run_cli("--seed", "0123456789abcdef").stdout)

    def test_bad_seed(self):
        for bad in ("", "xyz", "0123", "ABCDEF0123456789", "0" * 65, "g" * 20):
            p = self.run_cli("--seed", bad)
            self.assertEqual(p.returncode, 2, bad)
            self.assertEqual(p.stdout, b"")
            self.assertTrue(p.stderr)
        self.assertEqual(self.run_cli().returncode, 2)

    def test_out_mode_overwrite_force(self):
        old = os.umask(0o077)
        try:
            with tempfile.TemporaryDirectory() as d:
                path = os.path.join(d, "page.html")
                p = self.run_cli("--seed", "a" * 32, "--out", path)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(p.stdout, b"")
                self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o644)
                with open(path, encoding="utf-8") as f:
                    self.assertEqual(f.read(), login.generate_page("a" * 32))
                self.assertEqual(os.listdir(d), ["page.html"])

                # refuse overwrite
                p = self.run_cli("--seed", "b" * 32, "--out", path)
                self.assertEqual(p.returncode, 1)
                self.assertTrue(p.stderr)
                with open(path, encoding="utf-8") as f:
                    self.assertEqual(f.read(), login.generate_page("a" * 32))
                self.assertEqual(os.listdir(d), ["page.html"])

                # --force
                os.chmod(path, 0o600)
                p = self.run_cli("--seed", "b" * 32, "--out", path, "--force")
                self.assertEqual(p.returncode, 0, p.stderr)
                with open(path, encoding="utf-8") as f:
                    self.assertEqual(f.read(), login.generate_page("b" * 32))
                self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o644)
                self.assertEqual(os.listdir(d), ["page.html"])
        finally:
            os.umask(old)

    def test_out_failure_leaves_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "missing", "page.html")
            p = self.run_cli("--seed", "a" * 32, "--out", path)
            self.assertEqual(p.returncode, 1)
            self.assertEqual(os.listdir(d), [])


if __name__ == "__main__":
    unittest.main()
