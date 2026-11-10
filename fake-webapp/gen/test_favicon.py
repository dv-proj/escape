import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import favicon  # noqa: E402

SCRIPT = os.path.join(HERE, "favicon.py")
SEED = "0123456789abcdef0123"


def parse_ico(data):
    res, typ, n = struct.unpack_from("<HHH", data, 0)
    assert (res, typ) == (0, 1)
    entries = []
    for i in range(n):
        entries.append(struct.unpack_from("<BBBBHHII", data, 6 + 16 * i))
    return entries


def check_png(tc, png, size):
    tc.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
    pos, idat, seen = 8, b"", []
    while pos < len(png):
        ln, = struct.unpack_from(">I", png, pos)
        t = png[pos + 4:pos + 8]
        d = png[pos + 8:pos + 8 + ln]
        crc, = struct.unpack_from(">I", png, pos + 8 + ln)
        tc.assertEqual(crc, zlib.crc32(t + d) & 0xFFFFFFFF)
        seen.append(t)
        if t == b"IHDR":
            tc.assertEqual(struct.unpack(">IIBBBBB", d), (size, size, 8, 6, 0, 0, 0))
        if t == b"IDAT":
            idat += d
        pos += 12 + ln
    tc.assertEqual(seen[0], b"IHDR")
    tc.assertEqual(seen[-1], b"IEND")
    tc.assertEqual(len(zlib.decompress(idat)), size * (size * 4 + 1))


class IcoTests(unittest.TestCase):
    def test_structure(self):
        data = favicon.generate(SEED, "Acme")
        entries = parse_ico(data)
        self.assertEqual([e[0] for e in entries], [16, 32, 48])
        end = 6 + 16 * 3
        for (w, h, _, _, planes, bpp, size, off), s in zip(entries, (16, 32, 48)):
            self.assertEqual((w, h, planes, bpp), (s, s, 1, 32))
            self.assertEqual(off, end)
            check_png(self, data[off:off + size], s)
            end += size
        self.assertEqual(end, len(data))

    def test_deterministic_and_distinct(self):
        self.assertEqual(favicon.generate(SEED, "Acme"), favicon.generate(SEED, "Acme"))
        self.assertNotEqual(favicon.generate(SEED, "Acme"),
                            favicon.generate("fedcba9876543210ff", "Acme"))
        self.assertNotEqual(favicon.generate(SEED, "Acme"), favicon.generate(SEED, "Zed"))

    def test_no_alnum_name(self):
        data = favicon.generate(SEED, "---")
        for e in parse_ico(data):
            check_png(self, data[e[7]:e[7] + e[6]], e[0])

    def test_all_glyphs(self):
        for ch in favicon.FONT:
            self.assertEqual(len(favicon.FONT[ch]), 7)
            self.assertTrue(all(len(r) == 5 for r in favicon.FONT[ch]))
        self.assertEqual(len(favicon.FONT), 36)


class CliTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True)

    def test_stdout(self):
        r = self.run_cli("--seed", SEED, "--name", "Acme")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stderr, b"")
        self.assertEqual(r.stdout, favicon.generate(SEED, "Acme"))

    def test_out_mode_overwrite_force(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "f.ico")
            old = os.umask(0o077)
            try:
                r = self.run_cli("--seed", SEED, "--name", "Acme", "--out", p)
            finally:
                os.umask(old)
            self.assertEqual(r.returncode, 0)
            self.assertEqual(os.stat(p).st_mode & 0o777, 0o644)
            first = open(p, "rb").read()
            r = self.run_cli("--seed", "ab" * 10, "--name", "Zed", "--out", p)
            self.assertEqual(r.returncode, 1)
            self.assertEqual(open(p, "rb").read(), first)
            r = self.run_cli("--seed", "ab" * 10, "--name", "Zed", "--out", p, "--force")
            self.assertEqual(r.returncode, 0)
            self.assertNotEqual(open(p, "rb").read(), first)
            self.assertEqual(os.listdir(d), ["f.ico"])

    def test_bad_args(self):
        for args in (["--seed", "xyz", "--name", "A"],
                     ["--seed", "abc", "--name", "A"],
                     ["--seed", "A" * 16, "--name", "A"],
                     ["--seed", SEED, "--name", "  "],
                     ["--seed", SEED],
                     ["--name", "A"]):
            r = self.run_cli(*args)
            self.assertEqual(r.returncode, 2, args)
            self.assertEqual(r.stdout, b"")
            self.assertTrue(r.stderr)


if __name__ == "__main__":
    unittest.main()
