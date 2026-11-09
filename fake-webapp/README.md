# fake-webapp

Decoy corporate login page served to non-VPN visitors. Plain HTTP and h2c on `LISTEN_ADDR`; TLS is terminated by nginx.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `LISTEN_ADDR` | `:8080` | listen address |
| `APP_NAME` | `Cloud Portal` | name shown on page and in `<title>` |
| `APP_DESCRIPTION` | neutral sentence | meta description |
| `APP_KEYWORDS` | neutral keywords | meta keywords |
| `BASE_URL` | empty | canonical link and `og:url` (e.g. `https://example.com`) |
| `RATE_LIMIT_RPS` | required, 1-1000 | per-client-IP token bucket rate (IP from `X-Real-IP`); excess gets an HTML 429 with `Retry-After` |
| `RATE_LIMIT_BURST` | required, 1-1000 | per-client-IP burst |
| `RATE_LIMIT_GLOBAL_RPS` | required, 1-100000 | global ceiling for all clients |
| `LOGIN_DELAY_MIN_MS` / `LOGIN_DELAY_MAX_MS` | required, 0 <= min <= max <= 10000 | `POST /login` waits a random log-normal time in this range before answering |
| `FAVICON_FILE` | `/data/favicon.ico` | replaces the built-in blank favicon if the file exists (read at start, max 1 MiB) |
| `RANDOM_DATA_SUFFIX` | required | lowercase hex, 8-12 chars; the data endpoint is `/random-<suffix>`; the app exits at startup if missing or invalid |
| `PAGE_SEED` | required | 16-64 lowercase hex chars; seed of the generated login page variant; the app exits at startup if missing or invalid |
| `PAGE_FILE` | `/data/page.html` | the page template (Go `html/template`); empty string disables the file (memory only) |
| `TZ` | system | timezone of displayed time |

## Decoy page

The login page is not a fixed template: `pagegen.go` generates it from `PAGE_SEED` (class names and ids, head tag order, CSS rule/property order, indentation, wrappers, optional help link / remember-me / footer, wording of every text including the 401 and 429 messages, clock script naming). The look stays the same. On start (`page.go`):

- `PAGE_FILE` exists and parses (and renders for every state): it is used as is.
- It exists but is broken: an error is logged, the generated page is served from memory, the file is left untouched.
- It is missing: the generated page is written atomically (temp file + rename, mode 0644) and used. If the directory is not writable, a warning is logged and the page is served from memory.

Template data: `AppName`, `Description`, `Keywords`, `BaseURL`, `JSONLD`, `Nonce`, `Time`, `UnixMilli`, `OffsetSec`, `Year`, `HideForm`, `State` (`""`, `"invalid"` for 401, `"throttled"` for 429; the message texts live in the template).

## Endpoints

- `GET /` (and HEAD): login page with SEO metadata and server time.
- `GET /favicon.ico` (and HEAD): blank 16x16 icon (or `FAVICON_FILE`), `Cache-Control: public, max-age=86400`, ETag.
- `POST /login`: delayed (see above), always 401; the 3rd attempt for the same username (case-insensitive) within 60s gets 429 + `Retry-After`.
- `GET /random-<RANDOM_DATA_SUFFIX>?size=N`: N random bytes, 0 <= N <= 500000, else 400 (HTML body).
- Anything else (incl. `/robots.txt`, `/sitemap.xml`): 302 to `/` (303 for POST) with an empty body.

No Go plain-text bodies are sent: 429 and 400 are small HTML pages (wording from `PAGE_SEED`, `errorpage.go`). Security headers (`headers.go`: CSP directive set/order, nonce length and encoding, `Referrer-Policy`, `X-Frame-Options`, `Permissions-Policy`, COOP, `Cache-Control` of the page) are derived deterministically from `PAGE_SEED`.

Healthcheck: `fake-webapp -healthcheck` (GET `/` on localhost, exit 0 on 200).

Test: `go test ./...`. Build: `docker build -t fake-webapp .`
