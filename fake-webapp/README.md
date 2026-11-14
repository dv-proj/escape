# fake-webapp

Decoy corporate login page served to non-VPN visitors. Plain HTTP and h2c on `LISTEN_ADDR`; TLS is terminated by your nginx in front of it.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `LISTEN_ADDR` | `:8080` | listen address |
| `APP_NAME` | `Cloud Portal` | name shown on page and in `<title>` |
| `APP_DESCRIPTION` | neutral sentence | meta description |
| `APP_KEYWORDS` | neutral keywords | meta keywords |
| `BASE_URL` | empty | canonical link and `og:url` (e.g. `https://example.com`); the compose file sets it to `https://<DOMAIN>` when `DOMAIN` is set in `.env` |
| `RATE_LIMIT_RPS` | required, 1-1000 | per-client-IP token bucket rate (IP from `X-Real-IP`); excess gets an HTML 429 with `Retry-After` |
| `RATE_LIMIT_BURST` | required, 1-1000 | per-client-IP burst |
| `RATE_LIMIT_GLOBAL_RPS` | required, 1-100000 | global ceiling for all clients |
| `LOGIN_DELAY_MIN_MS` / `LOGIN_DELAY_MAX_MS` | required, 0 <= min <= max <= 10000 | `POST /login` waits a random log-normal time in this range before answering |
| `RANDOM_DATA_SUFFIX` | required | lowercase hex, 8-12 chars; the data endpoint is `/random-<suffix>`; the app exits at startup if missing or invalid |
| `PAGE_SEED` | required | 16-64 lowercase hex chars; seed of the header/error-page variants (and of the generators); the app exits at startup if missing or invalid |
| `LOGIN_FILE` | `/data/login.html` | login page template (Go `html/template`) produced by `gen/login.py`; read once at start, the app exits if it is missing, empty or invalid (changes need a restart) |
| `STATIC_DIR` | `/data` | read-only directory served as static files (opened at start, the app exits if it cannot be opened) |
| `TZ` | system | timezone of displayed time |

## Decoy page

The app generates nothing and writes no files. The data directory (mounted read-only) is prepared by external generators that live in `gen/` (Python 3, stdlib only; not part of the image):

- `python3 gen/login.py --seed <PAGE_SEED> --out <dir>/login.html`: the login page template (class names and ids, tag order, CSS order, wording of every text including the 401 and 429 messages, ...).
- `python3 gen/favicon.py --seed <PAGE_SEED> --name <APP_NAME> --out <dir>/favicon.ico`: the favicon.

Both write files with mode 0644; the app only reads them. At start `LOGIN_FILE` is read and checked (it must parse and render for every state); if it is missing, unreadable, empty or invalid the app logs the generator command and exits with status 1. The page is not re-read while running.

Template data: `AppName`, `Description`, `Keywords`, `BaseURL`, `JSONLD`, `Nonce`, `Time`, `UnixMilli`, `OffsetSec`, `Year`, `HideForm`, `State` (`""`, `"invalid"` for 401, `"throttled"` for 429; the message texts live in the template).

## Endpoints

- `GET /` (and HEAD): login page with SEO metadata and server time.
- `POST /login`: delayed (see above), always 401; the 3rd attempt for the same username (case-insensitive) within 60s gets 429 + `Retry-After`.
- `GET /random-<RANDOM_DATA_SUFFIX>?size=N`: N random bytes for 0 <= N <= 500000; without `size` or with an invalid one, a random size between 50000 and 500000.
- `GET`/`HEAD` of a file in `STATIC_DIR` (e.g. `/favicon.ico`, `/a/b/c.css`), read on every request so edits show immediately: `Last-Modified`/`If-Modified-Since`/`Range` via `http.ServeContent`, `ETag` (size + mtime), `Cache-Control: no-cache`, `Content-Type` from the extension (else `application/octet-stream`), `X-Content-Type-Options: nosniff`, and the same security headers as the page. Files are opened through `os.OpenRoot`, so `..` and symlinks cannot leave the directory. Not served (redirect below): path segments starting with `.`, `/login.html` (any case), directories (no listing, no index), non-regular files, unclean paths.
- Routing precedence: `/`, `POST /login`, `/random-<suffix>`, static files, then the redirect.
- Anything else (incl. `/robots.txt`, `/sitemap.xml`): 302 to `/` (303 for POST) with an empty body.

No Go plain-text bodies are sent: 429 and 400 are small HTML pages (wording from `PAGE_SEED`, `errorpage.go`). Security headers (`headers.go`: CSP directive set/order, nonce length and encoding, `Referrer-Policy`, `X-Frame-Options`, `Permissions-Policy`, COOP, `Cache-Control` of the page) are derived deterministically from `PAGE_SEED`.

Healthcheck: `fake-webapp -healthcheck` (GET `/` on localhost, exit 0 on 200).

Test: `go test ./...`. Build: `docker build -t fake-webapp .`

Compose: `docker-compose.yml` here defines the `fakeapp` service for `include:` from a main compose file (variables come from the including project's `.env`; data directory `${FAKEAPP_DATA_DIR:-../data/fakeapp}`, `LISTEN_ADDR` is `:${FAKEAPP_PORT:-8080}` and the same port is published on `${FAKEAPP_BIND:-127.0.0.1}`).
