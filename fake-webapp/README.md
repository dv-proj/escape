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
| `RATE_LIMIT_RPS` | `10` | global token bucket (burst = RPS), excess gets 429 |
| `RANDOM_DATA_SUFFIX` | required | lowercase hex, 8-12 chars; the data endpoint is `/random-<suffix>`; the app exits at startup if missing or invalid |
| `TZ` | system | timezone of displayed time |

## Endpoints

- `GET /` (and HEAD): login page with SEO metadata and server time.
- `POST /login`: always 401; the 3rd attempt for the same username (case-insensitive) within 60s gets 429 + `Retry-After`.
- `GET /random-<RANDOM_DATA_SUFFIX>?size=N`: N random bytes, 0 <= N <= 500000, else 400.
- Anything else: 302 to `/` (303 for POST).

Healthcheck: `fake-webapp -healthcheck` (GET `/` on localhost, exit 0 on 200).

Test: `go test ./...`. Build: `docker build -t fake-webapp .`
