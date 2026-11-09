package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"log/slog"
	"net/http"
	"os"
	"time"
)

const maxFaviconSize = 1 << 20

// blankFavicon builds a valid 16x16 fully transparent 32-bit .ico.
func blankFavicon() []byte {
	var b bytes.Buffer
	le := func(v any) { _ = binary.Write(&b, binary.LittleEndian, v) }
	le(uint16(0)) // reserved
	le(uint16(1)) // type: icon
	le(uint16(1)) // count
	b.Write([]byte{16, 16, 0, 0})
	le(uint16(1))  // planes
	le(uint16(32)) // bpp
	const xor, and = 16 * 16 * 4, 16 * 4
	le(uint32(40 + xor + and)) // image size
	le(uint32(22))             // offset
	le(uint32(40))             // BITMAPINFOHEADER
	le(int32(16))
	le(int32(32)) // height doubled (XOR + AND masks)
	le(uint16(1))
	le(uint16(32))
	le(uint32(0))
	le(uint32(xor + and))
	le(int32(0))
	le(int32(0))
	le(uint32(0))
	le(uint32(0))
	b.Write(make([]byte, xor+and))
	return b.Bytes()
}

type favicon struct {
	data []byte
	ct   string
	etag string
	mod  time.Time
}

// loadFavicon returns the file at path when readable, else the blank icon.
func loadFavicon(path string, now time.Time) *favicon {
	data := blankFavicon()
	mod := now
	if path != "" {
		st, err := os.Stat(path)
		switch {
		case err != nil:
			if !os.IsNotExist(err) {
				slog.Warn("cannot read favicon file, using the built-in one", "file", path, "err", err)
			}
		case st.IsDir() || st.Size() == 0 || st.Size() > maxFaviconSize:
			slog.Warn("unusable favicon file, using the built-in one", "file", path)
		default:
			if d, err := os.ReadFile(path); err != nil {
				slog.Warn("cannot read favicon file, using the built-in one", "file", path, "err", err)
			} else {
				data, mod = d, st.ModTime()
				slog.Info("favicon loaded from file", "file", path)
			}
		}
	}
	ct := http.DetectContentType(data)
	if len(ct) < 6 || ct[:6] != "image/" {
		ct = "image/x-icon"
	}
	sum := sha256.Sum256(data)
	return &favicon{data: data, ct: ct, etag: `"` + hex.EncodeToString(sum[:8]) + `"`, mod: mod}
}

func (f *favicon) serve(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Content-Type", f.ct)
	h.Set("Cache-Control", "public, max-age=86400")
	h.Set("ETag", f.etag)
	http.ServeContent(w, r, "favicon.ico", f.mod, bytes.NewReader(f.data))
}
