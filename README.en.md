# escape: the fake-webapp decoy site behind nginx in Docker

English | [Русский](README.md)

The tool deploys a Docker stack on a server: an `nginx` container accepts HTTPS on port 443 and serves the `fakeapp` decoy site. It is a believable login page of a web service (Go, sources in `fake-webapp/`). It is what ordinary visitors and active probes see when they open your domain without a VPN key.

nginx publishes ports 80 and 443 of the host, obtains a Let's Encrypt certificate for your domain (certbot, webroot method) and renews it by itself. `fakeapp` is not published to the outside: it is reachable only inside the compose network as `http://fakeapp:<port>`. Additional services (extensions) are attached to this stack through separate files and add their own `location` blocks to nginx (see [Extensions](#extensions)). The script **does not touch** Xray, 3X-UI or the firewall.

## Contents of the project

| File | Purpose |
|---|---|
| `install.sh` | the single entry point: installation and management (`./install.sh <command>`). A small file: it downloads the project (a tarball, no git) when run through `curl | bash` and sources the modules from `lib/` in a fixed order |
| `lib/i18n.sh` | message language: the `t KEY` function, language choice (`--lang`, `FAKEAPP_LANG`), loading the texts of extensions (`ext_load_lang`) |
| `lib/lang/en.sh`, `lib/lang/ru.sh` | message texts in English and Russian (identical key sets) |
| `lib/common.sh` | output, `die`/`step`/`on_err`, phases and the problem list (`phase`, `problem`), `confirm`, the `docker compose` wrapper, shared paths (`init_paths`) |
| `lib/instdir.sh` | the install directory: the question and its validation, copying the project into it (`sync_to_install_dir`, the allowlist), finding the installation (`resolve_app_dir`, the pointer file) |
| `lib/gen.sh` | random values and the look of the decoy site (name, description, keywords) |
| `lib/env.sh` | `.env`: value checks, questions, generation from `.env.example`, completing an existing `.env`, reading values |
| `lib/system.sh` | OS and tool checks, package installation, Docker detection and installation |
| `lib/nginx.sh` | building the nginx config from the template, the `data/nginx` directory, checking ports 80/443 |
| `lib/certs.sh` | certificates: temporary self-signed, Let's Encrypt (certbot), the renewal timer (systemd or cron), DNS check, certificates of extension names (`ext_cert_request`) |
| `lib/app.sh` | the project: file checks, the data directory, the site answer check, the final summary |
| `lib/extensions.sh` | the extension framework and the `ext_*` functions for files in `extensions.d/` |
| `lib/commands.sh` | the `install`, `start`, `stop` and other commands, the help text, `main` |
| `extensions.d/` | installation extensions (one file per extension) and their description ([extensions.d/README.md](extensions.d/README.md)); `extensions.d/telegram-web-proxy/`: scripts of the Telegram web proxy extension, `extensions.d/<id>/lang/`: the extension's texts in two languages |
| `tests/check-i18n.sh` | checks the message files: identical `en`/`ru` key sets, every key used in code exists in the English file (source repository only: not copied to the install directory) |
| `nginx/` | `docker-compose.yml` (the `nginx` service and the one-shot `certbot`) and the config template `default.conf.template` |
| `fake-webapp/` | application sources, `Dockerfile`, description (`fake-webapp/README.md`), tests; only what `docker build` and the generators need is copied to the install directory |
| `fake-webapp/gen/` | the `login.py` and `favicon.py` generators (Python 3, stdlib only); they run on the host and are not part of the image |
| `fake-webapp/docker-compose.yml` | the `fakeapp` service |
| `docker-compose.yml` | the main file (project `escape`): `include` of `nginx/docker-compose.yml`, `fake-webapp/docker-compose.yml` and `data/extensions.compose.yml`; it knows nothing about extensions |
| `.env.example` | settings template; copied to `.env` at install |
| `README.md`, `README.en.md` | this description in Russian and in English |
| `data/` (in the install directory only) | `fakeapp/` (the page and files of the site), `nginx/` (generated config, `locations.d/`, `servers.d/`, `extra-certs.list`, webroot), `letsencrypt/` (certificates), `extensions.compose.yml` (generated), `telegram-web-proxy/` (extension: config, state, saved image): see [Install directory](#install-directory) |

The table lists the source repository. The installation does not run from it: it is copied into the [install directory](#install-directory) (only what runs the system).

## Requirements

- Ubuntu 22.04+ or Debian 12+, root rights (`sudo`).
- Docker with the compose v2.20+ plugin. If Docker is already installed (for example, 3X-UI runs on it), it is used and its settings are not changed. If there is no Docker, Docker CE is installed from `download.docker.com`. If only the compose plugin is missing, the plugin is installed.
- `python3`, `curl`, `iproute2`, `openssl` (installed automatically when missing).
- Free ports 80 and 443 (a host nginx or Xray on 443 must be stopped or moved) and a DNS A/AAAA record of your domain pointing to this server: without it Let's Encrypt will not issue a certificate. Server: 1 CPU and 1 GB of memory are enough.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/dv-proj/escape/main/install.sh | sudo bash -s -- install
```

The script downloads the repository as a tarball (`curl`, no git is needed) into a temporary directory, runs the `install.sh` from it and deletes the temporary directory on exit. Questions are asked in the terminal: first the language, then the [install directory](#install-directory) (default `/opt/escape`), then the rest. `install` copies the project into the install directory and continues from the installed copy (`/opt/escape/install.sh`); nothing else is left of the download. Pass your language and flags after `--`, for example `... | sudo bash -s -- --lang ru --dir /srv/escape install`.

The download is set by environment variables (defaults in parentheses; pass them through `sudo -E` or `sudo VAR=...`): `ESCAPE_REPO_URL` (`https://codeload.github.com/dv-proj/escape`; the archive is `<ESCAPE_REPO_URL>/tar.gz/<ref>`), `ESCAPE_BRANCH` (`main`; a branch, a tag or a commit hash; `FAKEAPP_BRANCH` is a deprecated alias). Running the same one-liner again is an **update**: the code of the install directory is replaced with the downloaded one, `.env` and `data/` are kept (see [Update](#update)).

Another way: clone the repository yourself and run `sudo ./install.sh install` from it. The checkout is only the source: its files are copied into the install directory by the same step, and the checkout itself is never the install directory (naming it as such is refused).

### Message language

The first question of `install` (and of `extensions --with` when run alone in a terminal) is `Language / Язык: 1 - English, 2 - Russian [1]`; English is the default. You can set the choice in advance with the `--lang en|ru` flag or the `FAKEAPP_LANG` environment variable; then the question is skipped. The choice is saved in `.env` (the `FAKEAPP_LANG` key) and applied silently on later runs (including `status`, `logs` and the other commands); the flag and the environment variable take precedence over the value in `.env` and, with `install`, update it. An unknown value (neither `en` nor `ru`) is listed among the problems of the validation phase. Without a terminal and without a language setting English is used. Commands, flags, variable names, paths and the output of Docker, apt and certbot are not translated.

The installation runs in three phases, the same for the core and for every extension:

1. **Collect.** First the language choice, then the install directory, then all questions at once: the domain, the Let's Encrypt e-mail, the site name, description and keywords, then the menu of additional features (extensions) and the extensions' own questions (for example, the outgoing interface). Environment variables and flags replace the questions; without a terminal there are no questions. Nothing is installed or changed.
2. **Validate.** All values are checked together before anything is deployed: the install directory (it is checked as soon as it is known, and the project is copied only after that), the domain name, free ports 80/443, the project files, the outgoing interface and other checks of the extensions. The domain's DNS is checked with a warning (does it point to this server). All problems found are printed as one list; if any of them is serious, the installation stops before deployment starts.
3. **Deploy.** Only now are the packages and Docker installed, `.env` and the configuration written, the stack built and started, the certificate issued and the extensions applied. There are no more questions here.

The extension menu is shown after the questions of the core. Without the menu: `--with id1,id2` (or `--with all`), or the `FAKEAPP_EXTENSIONS` variable with the same value; to install extensions separately from the main installation use `./install.sh extensions --with id`. The list: `./install.sh extensions`. How to add your own extension: [extensions.d/README.md](extensions.d/README.md).

The script asks only these questions:

| Question | `.env` key | Default |
|---|---|---|
| Language: `Language / Язык: 1 - English, 2 - Russian [1]` | `FAKEAPP_LANG` | `en` |
| Install directory (`--dir`, `ESCAPE_DIR`; not stored in `.env`) | none | `/opt/escape`, or the directory of the existing installation (the pointer file) |
| DNS name of the site, for example `app.example.com` (required) | `DOMAIN` | none: the installation does not go on without it |
| E-mail for Let's Encrypt (optional) | `LE_EMAIL` | empty: registration without an e-mail |
| Site name | `APP_NAME` | a random believable one |
| Site description | `APP_DESCRIPTION` | random, matching the name |
| Keywords | `APP_KEYWORDS` | random, matching the name |
| Time zone | `TZ` | the host's time zone |

- **`DOMAIN`** sets nginx `server_name`, the certificate domain and the `canonical` and `og:url` tags (`https://<DOMAIN>`). If it is missing or empty in an existing `.env`, the script asks for it on the next run.
- The nginx ports (`NGINX_HTTP_PORT`, `NGINX_HTTPS_PORT`, 80 and 443 by default), `LE_STAGING` (`1`: the Let's Encrypt test CA, the certificate is not trusted, no rate limits) and the application port inside the network (`FAKEAPP_PORT`, 8080) are not asked: if you need them, set them through environment variables on the first run or edit `.env`. The script checks that the nginx ports are free and names the program that occupies them. Let's Encrypt needs port 80 to validate the domain: with another `NGINX_HTTP_PORT`, forward 80 to it.

The other parameters are generated randomly: `PAGE_SEED` (the look variant), `RANDOM_DATA_SUFFIX`, the request limits (`RATE_LIMIT_RPS`, `RATE_LIMIT_BURST`, `RATE_LIMIT_GLOBAL_RPS`) and the login delays (`LOGIN_DELAY_MIN_MS`, `LOGIN_DELAY_MAX_MS`). Without a terminal no questions are asked: the defaults or the environment variables with the same names are used, for example `DOMAIN=app.example.com LE_EMAIL=me@example.com sudo -E ./install.sh install`. Without `DOMAIN` a non-interactive installation fails with an error.

What `install` does after the checks: it creates a temporary self-signed certificate (so that nginx starts at once), builds and starts the stack, then requests the real certificate with a one-shot certbot container and plugs it into nginx. If the certificate could not be obtained (DNS points elsewhere, port 80 is not reachable from the internet, Let's Encrypt limits), the script prints the cause and a hint, the rest of the installation is not interrupted, and nginx keeps working with the self-signed certificate. Fix the cause and run `sudo ./install.sh renew` (or repeat `install`). Certificates are stored in `data/letsencrypt/`. Renewal: the systemd timer `escape-certbot-renew.timer` (twice a day it runs `<install directory>/install.sh renew`: `certbot renew` and an nginx reload); if systemd is not running, an entry in `/etc/cron.d/escape-certbot` is installed.

A repeated `install` copies the project into the install directory again, rebuilds and restarts the stack and asks no questions (except the language, if it has not been chosen yet, and the directory, if it is not known). It does not change the values in `.env`, it only appends new keys from `.env.example` (and writes the chosen language). It does not touch the existing `login.html` and `favicon.ico` either.

## Install directory

The project never runs from a git checkout. `install` takes the sources (a checkout, or the unpacked download) and **copies an allowlist of them** into the install directory. That directory holds only what runs the system, everything the installation creates lives in it, and everything outside it is listed below.

**Choosing the directory.** The second question of `install` (after the language): default `/opt/escape`; `--dir PATH` or `ESCAPE_DIR` set it without a question (`FAKEAPP_DIR` is a deprecated alias). With an existing installation the default is its directory (from the pointer file, see below). The path is checked first, before anything is copied:

- absolute, only letters, digits and `. _ / + @ : -` (no spaces); not `/` or a system directory (`/usr`, `/etc`, `/var`, `/home`, `/opt`, `/tmp` itself, a user's home, ...);
- it may not exist yet (its nearest existing parent must be writable: run as root), or be empty (or hold only `.env` and `data/` copied from an old installation), or be **an existing installation of this project** (it has the marker file `.escape-install`): then the code is updated and `.env` and `data/` are kept;
- a non-empty directory that is not our installation is a problem with a hint: the old layout (a git checkout such as `/opt/fakeapp`) is never reused or touched, see [Migration from the old layout](#migration-from-the-old-layout); the source checkout the script runs from cannot be the install directory either.

**Layout of the install directory** (`/opt/escape` by default):

```text
/opt/escape/
├── .escape-install        marker: this directory is an installation of the project
├── .env                   settings (mode 600); never overwritten by an update
├── .env.example           template (new keys are appended to .env at an update)
├── install.sh             the entry point of every command
├── docker-compose.yml     the main compose file (project "escape")
├── README.md, README.en.md
├── lib/                   modules of install.sh, lib/lang/ (messages)
├── nginx/                 docker-compose.yml (nginx, certbot), default.conf.template
├── fake-webapp/           build context of the decoy app: Dockerfile, .dockerignore, go.mod,
│                          *.go, docker-compose.yml, gen/login.py, gen/favicon.py (no tests)
├── extensions.d/          extensions: <NN>-<id>.sh, <id>/ (their scripts and lang/)
├── scripts/               standalone tgproxy-*.sh (created by the telegram-web-proxy extension)
└── data/                  ALL runtime data (bind mounts; there are no named Docker volumes)
    ├── fakeapp/           login.html, favicon.ico, your files (read-only in the container)
    ├── nginx/             conf.d/, locations.d/, servers.d/, selfsigned/, webroot/, extra-certs.list
    ├── letsencrypt/       certificates, the ACME account, the renewal config
    ├── extensions.compose.yml   generated: the compose files of installed extensions
    └── telegram-web-proxy/      extension: state.env, telemt/config.toml, docker-compose.yml,
                                 nginx-*.conf, telemt-image.tar
```

There is no `.git*`, `.github`, `tests/`, editor files or `CLAUDE.md`/`AGENTS.md` in it. Everything under `data/` is yours: `install` never deletes or overwrites it. The only exception to "everything is in the install directory" is `FAKEAPP_DATA_DIR` in `.env`, if you set it yourself. The compose project is named `escape` (containers `escape-nginx-1`, `escape-fakeapp-1`, the network `escape_default`), so it does not collide with the old `fakeapp` project.

**Outside the install directory** (only what cannot be inside it; `remove --purge` deletes all of it):

| What | Where |
|---|---|
| pointer to the installation | `/etc/escape/install-dir` (the directory path; written by `install`, so commands work from any directory) |
| the certificate renewal timer | `/etc/systemd/system/escape-certbot-renew.service` and `.timer`, or `/etc/cron.d/escape-certbot` when systemd is not running |
| the outway of the Telegram web proxy (extension) | `/etc/systemd/system/telegram-web-proxy-outway.service`, `-outway-check.service`, `-outway.timer`; `/etc/sysctl.d/90-telegram-web-proxy.conf`; the `ip rule` / `ip -6 rule` entries, routing table 7791, the `TGPROXY-OUTWAY` firewall chains (iptables/ip6tables or the nft table `tgproxy_outway`) |
| Docker | images (`nginx`, `certbot`, `telemt`, the built `fakeapp`), containers and networks managed by Docker; Docker itself and the apt packages are never removed |

**Running commands.** The commands (`start`, `stop`, `status`, `logs`, `renew`, `remove`, `info`, `extensions`) always run the installed copy: `sudo /opt/escape/install.sh status`. Run from another directory (or from a source checkout), `install.sh` finds the installation through `--dir`, `ESCAPE_DIR`, or `/etc/escape/install-dir` and executes the installed `install.sh` with the same arguments; without any of them it stops with a hint. The renewal timer and the extension's units point to the installed copy and its `scripts/`. With several installations on one host pass `--dir` explicitly (the pointer file keeps the last one).

### Update

Run the one-liner again (or `sudo ./install.sh install` from a fresh checkout / download):

1. the project is copied from the new sources into the install directory (the file allowlist; files that exist in the install directory's `lib/`, `nginx/`, `extensions.d/`, `fake-webapp/` but no longer in the sources are deleted, so removed modules disappear);
2. `.env`, `data/`, `scripts/` and everything else you keep there are not touched; new keys of `.env.example` are appended to `.env`;
3. the stack is rebuilt and restarted, the renewal timer and the extensions' scripts are refreshed.

Do not edit the copied code in the install directory: the next update overwrites it. Local changes belong in the source repository.

### Migration from the old layout

Earlier versions ran from a git checkout in `/opt/fakeapp` (data in `data/` there, the extension's scripts in `/opt/fakeapp-tgproxy` or `~user/telegram-web-proxy`, timer `fakeapp-certbot-renew`). The new installation does not detect or change it. To move:

1. Stop the old installation in its directory. If you use the Telegram web proxy, first run its `tgproxy-remove.sh` **without** `--purge` (it removes the container, the outway rules and units and the nginx route, but keeps `data/telegram-web-proxy/` with the secrets, so the link stays the same). Then `sudo ./install.sh remove` (also without `--purge`).
2. Copy the settings and the data into the new directory: `sudo mkdir -p /opt/escape && sudo cp -a /opt/fakeapp/.env /opt/fakeapp/data /opt/escape/`. A directory that holds only `.env` and `data/` is accepted as an install directory.
3. `sudo ./install.sh install` from a fresh checkout, or the one-liner: the code is copied into `/opt/escape`, `.env`, the site files and the certificates are reused, and the stack comes up as the new project `escape`. Ports 80/443 are free again after step 1.
4. Telegram web proxy: choose it in the menu (or `--with telegram-web-proxy`) again: it finds the kept state, rewrites its paths (`scripts/` in the new directory, project `escape`) and installs the same link.
5. When everything works, delete the old checkout and, if left, the old timer: `sudo systemctl disable --now fakeapp-certbot-renew.timer; sudo rm -f /etc/systemd/system/fakeapp-certbot-renew.* /etc/cron.d/fakeapp-certbot`; the old scripts directory (`/opt/fakeapp-tgproxy` or `~user/telegram-web-proxy`) is deleted by `tgproxy-remove.sh --purge` or by hand.

There is no automatic migration.

## Commands

General form: `install.sh [flags] <command>`. Without a command the help is printed (exit code 2). The examples below write `./install.sh`: run it from the install directory (`cd /opt/escape`) or use the full path; from anywhere else the installation is found through `/etc/escape/install-dir` (see [Install directory](#install-directory)).

| Command | Action |
|---|---|
| `sudo ./install.sh install` | install or update (see above); from a source checkout / download it copies the project into the install directory first |
| `./install.sh start` / `stop` / `restart` | start, stop, restart the stack (`start` and `restart` regenerate the nginx config) |
| `./install.sh info` | print the result data again: the random-data URL of the fake app and the web-proxy connection link (also printed as a separate "Result data" block at the end of `install`) |
| `./install.sh status` | container state, the certificate, the renewal timer and a check of `https://<DOMAIN>/` on this server (`curl --resolve` to `127.0.0.1`) |
| `./install.sh logs` | container logs (quit with Ctrl+C) |
| `sudo ./install.sh renew` | renew the certificates and reload the nginx config; request the certificate if there is none yet |
| `./install.sh extensions` | the list of extensions; with `--with id,...` (root) installs them as `install` does |
| `sudo ./install.sh remove [--purge] [-y]` | remove the containers, images and the renewal timer; the install directory, `.env` and `data/` stay. With `--purge` everything the install made is deleted: the extensions' system files, the data (including the certificates), the whole install directory and `/etc/escape/install-dir`. Docker stays |

`start`, `stop`, `restart`, `status` and `logs` need access to Docker: root, `sudo` or the `docker` group. Help: `./install.sh --help` (or `-h`, `help`); in the chosen language: `./install.sh --lang ru --help`.

### Flags

| Flag | Action |
|---|---|
| `-y`, `--yes` | answer "yes" to every confirmation (for `remove`, an unsupported OS and so on); also disables the extension menu |
| `--with IDS` | extensions without the menu: a comma list or `all`; for `install` and `extensions` (also the `FAKEAPP_EXTENSIONS` variable) |
| `--lang en\|ru` | message language (also the `FAKEAPP_LANG` variable) |
| `--dir PATH` | install directory (also `ESCAPE_DIR`; default `/opt/escape`): for `install` the place to install to, for the other commands the installation to work with |
| `--purge` | only for `remove`: delete the data and the install directory as well |
| `-h`, `--help` | help |

### Environment variables

Used when `.env` is created (instead of questions; pass them through `sudo -E` or `sudo VAR=...`): `DOMAIN`, `LE_EMAIL`, `LE_STAGING`, `NGINX_HTTP_PORT`, `NGINX_HTTPS_PORT`, `FAKEAPP_PORT`, `APP_NAME`, `APP_DESCRIPTION`, `APP_KEYWORDS`. Unset `APP_*` values are generated randomly. `TZ` is not read from the environment: the host's time zone is used (or the value typed in answer to the question). The others: `FAKEAPP_LANG` (language), `FAKEAPP_EXTENSIONS` (extensions without the menu), `ESCAPE_DIR` (the install directory; `FAKEAPP_DIR` is a deprecated alias), `ESCAPE_REPO_URL`, `ESCAPE_BRANCH` (downloading through `curl | bash`; `FAKEAPP_BRANCH` is a deprecated alias), `NO_COLOR` (turn colors off). For development: `ESCAPE_TEST_SYNC_ONLY=1` makes `install` run without root, ask the questions, copy the project into the install directory, start the installed copy and stop there before anything is deployed (used to test the copy step; `ESCAPE_POINTER_FILE` replaces `/etc/escape/install-dir` in such tests). The variables of the extensions are described in their sections (`TGPROXY_*`).

### `.env` keys

The file is created from `.env.example` (mode 600). A repeated `install` appends the missing keys and touches nothing else; you may edit the values by hand and apply them with `./install.sh restart`.

| Key | Meaning |
|---|---|
| `FAKEAPP_LANG` | message language, `en` or `ru` |
| `APP_NAME`, `APP_DESCRIPTION`, `APP_KEYWORDS` | name, description and keywords of the decoy site |
| `DOMAIN` | DNS name of the site (required) |
| `RANDOM_DATA_SUFFIX` | suffix of the random data path `/random-<suffix>?size=N` |
| `PAGE_SEED` | seed of the decoy site's look |
| `RATE_LIMIT_RPS`, `RATE_LIMIT_BURST`, `RATE_LIMIT_GLOBAL_RPS` | request limits (per client, burst, global) |
| `LOGIN_DELAY_MIN_MS`, `LOGIN_DELAY_MAX_MS` | delay of the `POST /login` answer |
| `TZ` | container time zone |
| `FAKEAPP_PORT` | application port inside the compose network (8080) |
| `FAKEAPP_DATA_DIR` | optional: another data directory (default `data/fakeapp`) |
| `NGINX_HTTP_PORT`, `NGINX_HTTPS_PORT` | nginx ports on the host (80 and 443) |
| `LOG_MAX_SIZE`, `LOG_MAX_FILE` | container log rotation (Docker json-file): up to `LOG_MAX_FILE` files of `LOG_MAX_SIZE` per container, default `5m` and `3` (15 MB at most). With access logs off this holds well over 3 days; Docker has no rotation by age, so size is the only limit. Applied after `restart` |
| `LE_EMAIL` | e-mail for Let's Encrypt (optional) |
| `LE_STAGING` | `1`: the Let's Encrypt test CA; after switching from `1` to `0` delete `data/letsencrypt` and run `install` |

## nginx in a container

- Image: the official `nginx:stable-alpine`, one container, the access log is disabled (`access_log off`).
- The script generates the config `data/nginx/conf.d/default.conf` from the template `nginx/default.conf.template`: do not edit it by hand, changes are overwritten on `install`, `start` and `restart`. The substitutions come from `.env` (`DOMAIN`, `FAKEAPP_PORT`, `NGINX_HTTPS_PORT`).
- Port 80: the path `/.well-known/acme-challenge/` is served from certbot's webroot, everything else gets a 301 redirect to `https://<DOMAIN>/`.
- Port 443: `http2`, TLS 1.2 and 1.3, `server_name <DOMAIN>`. The `location /` block proxies to `http://fakeapp:<port>`; `X-Real-IP` and `X-Forwarded-For` are overwritten with the client address (`$remote_addr`), `X-Forwarded-Proto` and `Host` are passed on. The application trusts `X-Real-IP`, which is why its port is not published anywhere.
- Before `location /`, the 443 block includes `include /etc/nginx/locations.d/*.conf;`: the directory `data/nginx/locations.d/` is mounted into the container, and extensions put one `.conf` file with a `location` block there.
- At http level the config includes `include /etc/nginx/servers.d/*.conf;` (directory `data/nginx/servers.d/`, also mounted): an extension with a DNS name of its own puts its whole `server` blocks there (`ext_nginx_server_put`), with its own Let's Encrypt certificate (`ext_cert_request`). The names it registers are listed in `data/nginx/extra-certs.list`; `renew` (the timer) renews them together with the certificate of `DOMAIN` and issues the ones still missing. An installation made before `servers.d` existed is migrated by `start`/`restart`/`install`, or by the first extension that needs it (the config is rendered again and the nginx container recreated once, a few seconds without the site).
- Until the real certificate exists, a temporary self-signed one is used (`data/nginx/selfsigned/`). Browsers do not accept it; this is normal until Let's Encrypt issues the certificate.
- Xray or 3X-UI on the same server: nginx now occupies 443, so move them to another port or attach them through an extension (in `location` proxy to their address, for example `http://172.17.0.1:<port>` for a service published on the Docker bridge; the port must not be open to the internet).

Check:

```bash
./install.sh status
curl -sI https://<DOMAIN>/ | head -n1
```

`HTTP/2 200` is expected. Any non-existent path answers with a 302 redirect to `/`. Your real IP should appear in the application log (`./install.sh logs`); if everyone has an address `172.x.x.x` there, nginx does not pass `X-Real-IP`.

## Extensions

Additional features are installed from `extensions.d/` and do not edit the shared files of the stack: an extension adds its compose file to `data/extensions.compose.yml` (`ext_register_compose`) and its `location` to `data/nginx/locations.d/<id>.conf` (`ext_nginx_location_put`), or, for a DNS name of its own, whole `server` blocks to `data/nginx/servers.d/<id>.conf` (`ext_nginx_server_put`) and a certificate of that name (`ext_cert_request`). Details, function signatures and an example: [extensions.d/README.md](extensions.d/README.md).

An extension registers itself with `register_extension ID "Title" FUNCTION` and takes part in the three installation phases through optional hooks: `ext_<id>_collect` (all questions, changes nothing), `ext_<id>_validate` (read-only checks, problems reported with `problem`) and the deploy function (no questions); in a hook name `-` in `<id>` is replaced with `_`. Helper functions: `ext_register_compose`, `ext_unregister_compose`, `ext_nginx_location_put`, `ext_nginx_location_rm`, `ext_nginx_server_put`, `ext_nginx_server_rm`, `ext_cert_request`, `ext_cert_release`, `ext_cert_paths`, `check_domain_dns`, `ext_domain`, `env_value`, `problem`, `ext_compose`, and for messages `t` and `ext_load_lang`. The extension's texts are kept in `extensions.d/<id>/lang/en.sh` and `ru.sh`.

### Telegram web proxy (`telegram-web-proxy`)

The extension `extensions.d/50-telegram-web-proxy.sh` runs a Telegram web proxy based on [TELEMT](https://github.com/telemt/telemt) next to the decoy site (image `ghcr.io/telemt/telemt:3.5.17`, WEB mode). The client opens a link like `tg://webproxy?server=<proxy name>%2F<secret path>&secret=...` and connects to `https://<proxy name>/<secret path>/` over ordinary HTTPS on port 443. nginx gives TELEMT **only** this path (`location ^~ /<path>/` and the exact `location = /<path>`), everything else still goes to `fakeapp`; invalid requests inside the secret path are also redirected by TELEMT to the decoy (`fakeapp`). The `telemt` container publishes no ports: nginx reaches it over the compose network (`telemt:18080`), and `telemt` reaches the decoy at `http://fakeapp:<port>`.

**Proxy name.** The installation asks for the DNS name of the proxy (`TGPROXY_DOMAIN`), the host of the link. Enter keeps the name of the site (`DOMAIN`, as in earlier versions): the secret path is then a `location` in the 443 server of the site (`data/nginx/locations.d/telegram-web-proxy.conf`). A separate name (for example the site on `app.example.org` and the proxy on `p.example.org`) needs its own A/AAAA record pointing to this server (only a warning when it does not resolve yet, like for `DOMAIN`) and gets:

- its own `server` blocks in `data/nginx/servers.d/telegram-web-proxy.conf` (`ext_nginx_server_put`): port 80 answers ACME challenges and redirects to HTTPS; port 443 sends the secret path to TELEMT and **every other path** (including `/`) to the decoy `fakeapp`, with the same headers as `location /` of the site; the site itself (`DOMAIN`) no longer has the secret path;
- its own Let's Encrypt certificate (`ext_cert_request`, certbot webroot, renewed by the timer together with the certificate of the site). Until it is issued nginx serves a temporary self-signed certificate for the name, which Telegram Desktop rejects: a failure is a warning with hints, the rest of the installation goes on, and `sudo ./install.sh renew` (or the timer, or `tgproxy-config.sh cert`) tries again.

The name is stored in `state.env` (`TGPROXY_DOMAIN`). An installation made before this option (no `TGPROXY_DOMAIN` in `state.env`) keeps working with `DOMAIN`; a re-run offers "update", which asks for the name (Enter keeps `DOMAIN`). Changing the name changes the link.

**Requirements.** The stack is installed and running (`DOMAIN` is taken from `.env`, not asked again); `NGINX_HTTPS_PORT=443` (Telegram Desktop accepts only 443); `iproute2`, `openssl`, `python3`, `iptables` or `nft` on the host; access to `ghcr.io` on the first installation. Client: **Telegram Desktop 7.1 or newer** (the WEB proxy type). Mobile clients have not been tested. Resources: the container is limited to `128m` of memory (`TGPROXY_MEM_LIMIT`), takes tens of MB when idle; for a 1 CPU and 1 GB server there is plenty of headroom.

**Installation.** The "Telegram web proxy" menu item (after the questions of the core) at the end of `install`, or without the menu:

```bash
TGPROXY_OUTWAY=eth0 sudo -E ./install.sh extensions --with telegram-web-proxy
```

The installation generates a random secret path (20 characters) and a user secret (32 hex), writes `data/telegram-web-proxy/config.toml` (mode 600, owner is the container uid) and `state.env` (mode 600), attaches the compose file (`ext_register_compose`) and the `location` (`ext_nginx_location_put`; with a separate proxy name the `server` blocks and the certificate instead), sets up the outway, saves the image with `docker save` to `data/telegram-web-proxy/telemt-image.tar` (`TGPROXY_SAVE_IMAGE=0` turns this off) and finally prints the `tg://webproxy?...` link, the outway interface and warnings. The link is taken from the TELEMT log (it prints it at start); if it is no longer in the log, it is computed by the documented format.

Running the extension again on an installed system opens a menu: update (pull the image, rebuild the config, keep the secrets unless they are changed), remove, show the link, change the outway, change the secret path/secret, status. Without a terminal the action is set by environment variables (pass them through `sudo -E` or `sudo VAR=...`):

| Variable | Value |
|---|---|
| `TGPROXY_ACTION` | `install`, `update`, `remove`, `link`, `outway`, `rotate`, `status`. Default: `install`, and `update` on an installed system |
| `TGPROXY_DOMAIN` | the proxy name (host of the link) at `install` and `update`; default: the current one, else `DOMAIN` |
| `TGPROXY_OUTWAY` | the outway interface **name** (`eth0`, `wg0`, ...; only the terminal prompt accepts a list number) or `auto` (the interface of the IPv4 default route, else of the IPv6 one); required for a non-interactive installation |
| `TGPROXY_OUTWAY_FAMILIES` | `4`, `6` or `46`: the address families the outway carries, when the detection does not fit (by default detected from the global addresses and routes of the interface) |
| `TGPROXY_ROTATE` | `path`, `secret` or `all`: change the secret path/secret (with `update` and `rotate`); the old link stops working |
| `TGPROXY_PURGE=1` | with `remove` also delete the config with the secrets and the scripts |
| `TGPROXY_TELEMT_VERSION` | image tag (pinned to `3.5.17` by default); with `update` you can give a new one |
| `TGPROXY_PUBLIC_IP` | public IPv4 or IPv6 address for TELEMT `public_addr`; by default the address from the A, then AAAA record of the proxy name (see below) |
| `TGPROXY_SUBNET` | the `telemt` subnet (by default a free `172.29.x.0/24`, starting from `172.29.77.0/24`) |
| `TGPROXY_SAVE_IMAGE`, `TGPROXY_MEM_LIMIT`, `TGPROXY_SCRIPTS_DIR`, `TGPROXY_FW` | save the image (1/0), memory limit, scripts directory, `iptables` or `nft` |
| `TGPROXY_DRY_RUN=1` | the `ip`, `iptables`, `ip6tables`, `nft`, `sysctl`, `systemctl` commands are only printed, not run (everything else, including Docker, is run) |

**Outway: which interface the Telegram traffic leaves through.** The choice is mandatory. The `telemt` container is attached to two networks: the shared compose network (nginx and the decoy) and its own `<project>-tgproxy` with a fixed subnet; the container's default route goes through the second one. On the host, for **this subnet** (and only for it) the following is created:

- the routing table `7791` with `default via <gateway> dev <outway>` (for `tun`/`wg`/`ppp` without a gateway: `default dev <outway>`), plus a fallback `unreachable default metric 4096`;
- the rule `ip rule add from <subnet> lookup 7791`;
- masquerade `-s <subnet> -o <outway> -j MASQUERADE` and the ban `-s <subnet> ! -o <outway> -j DROP` in the separate chains `TGPROXY-OUTWAY` (iptables: nat and filter, the filter is hooked into `DOCKER-USER`; without iptables: a separate `nft` table `tgproxy_outway`).

**IPv4, IPv6 or both.** The outway may carry only IPv6 (a typical VPN tunnel without an IPv4 address), only IPv4 or both families. The installation detects this from the global addresses of the interface, or, when it has none, from its routes (`ip -4/-6 route show dev <outway>`), and stores it in `state.env` (`OUTWAY_FAMILIES`; `TGPROXY_OUTWAY_FAMILIES=4|6|46` overrides it). Tunnels in the `UNKNOWN` state (`tun`, `wg`, `ppp`) count as up. When the outway has IPv6, the `<project>-tgproxy` network is created dual-stack (`enable_ipv6: true`, a random ULA subnet `fdXX:XXXX:XXXX:XXXX::/64` that is free among the host and Docker networks and is kept in `state.env` as `NET_SUBNET6`), and everything above is repeated for IPv6: `ip -6 rule add from <subnet> lookup 7791`, `default dev <outway>` and `unreachable default` in the same table, masquerade and `DROP` in `ip6tables` (or in the `nft` table `ip6 tgproxy_outway`). The script adds the masquerade itself in its own chain, so `ip6tables: true` in `daemon.json` is not required (without it there is no IPv6 `DOCKER-USER` chain and the rules go to `FORWARD`; `daemon.json` is never edited). IPv6 forwarding needs `net.ipv6.conf.all.forwarding=1`: the script enables it and writes `/etc/sysctl.d/90-telegram-web-proxy.conf` (the file is deleted by `tgproxy-remove.sh`; the script warns when it cannot write or set it). Enabling forwarding stops RA processing on interfaces with `accept_ra=1`, so the script first sets `accept_ra=2` on interfaces that hold a default route learned from RA. A family the outway does not carry is closed for the container (fail-closed): with an IPv6-only outway the container's outgoing IPv4 is dropped (`unreachable` and `DROP`), and `config.toml` gets a `[network]` table with `ipv6 = true` and `prefer = 6` (with both families: `ipv6 = true`, `prefer = 4`; no table for an IPv4-only outway). The container gets addresses of both families, and the default route of each family is checked inside the container (`tgproxy-config.sh status`).

Other containers, the decoy, nginx and the host itself keep their routes unchanged. Examples: `TGPROXY_OUTWAY=eth0` (Telegram traffic goes through the main interface) or `TGPROXY_OUTWAY=wg0` (through WireGuard; the `wg0` interface must be up and its `AllowedIPs` must cover the Telegram addresses, for example `0.0.0.0/0` with `Table = off` so that `wg-quick` does not replace the host's default route). To change: menu → "change outway" or `tgproxy-config.sh outway wg0`. The interface question shows a numbered list (`1) ens3 ...`: state, IPv4 and IPv6 addresses, a mark on the interface of the default route); answer with the number or the name; an invalid answer is rejected and the list is shown again.

**Public address (`public_addr`).** TELEMT uses it in the parameters of the inner relay (the destination address with port 443), not to build the link, so it is always needed (in the TELEMT docs the field is required, type `SocketAddr`). The address is taken in this order: `TGPROXY_PUBLIC_IP`; the address of the proxy name (A record, then AAAA; `getent`, then `dig` or `host` when installed); the default-route address of the host (`ip route get 1.1.1.1`, then `ip -6 route get 2606:4700:4700::1111`); as the last resort `<proxy name>:443` (TELEMT may reject a name instead of an IP). An IPv6 address is written as `[address]:443`. A missing DNS record is only a warning in the validation phase, not an error.

**Fail-closed.** If the outway interface does not exist or is down, only `unreachable` stays in the table (for each family), and `DROP` does not let the subnet's traffic out through any other interface: the container will not reach Telegram, but nothing leaks around the outway; `tgproxy-outway.sh status` prints `BLOCKED (fail-closed)`. The rules survive a reboot: the systemd unit `telegram-web-proxy-outway.service` (oneshot, `RemainAfterExit`, after `docker.service`; on stop it switches to the "block" mode) plus the timer `telegram-web-proxy-outway.timer`, which restores the IPv4 and IPv6 routes every 30 seconds after a VPN restart (an IPv6 tunnel as well). A caveat: right after the host boots, the container may start a few seconds before the unit; in this mode TELEMT opens no outgoing connections while there are no clients. If replies over the outway get lost, check strict `rp_filter` (`net.ipv4.conf.all.rp_filter=2`): the script warns about it.

**Scripts on the host.** The installation copies three self-contained scripts (they need neither `install.sh`, nor the repository, nor the network, except `docker pull` of the image) to `scripts/` of the install directory (`/opt/escape/scripts/`; owner root, mode 755; the directory is changed with `TGPROXY_SCRIPTS_DIR`). The path of `state.env` is written into the copies, and the systemd units of the outway run them. The scripts read `data/telegram-web-proxy/state.env`:

- `tgproxy-config.sh`: `link`, `status`, `outway [interface]` (a numbered list without the argument), `net-setup`, `net-check` (address families and the IPv6 subnet of the telemt network), `rotate path|secret|all`, `render`, `apply` (rebuild the config, load the image, apply the outway and the nginx route: the `location` or the `server` blocks of the proxy name, start the container), `cert` (the Let's Encrypt certificate of a separate proxy name through the certbot service of the project), `restart`, `pull` (`docker pull`, and if the registry is unreachable, `docker load` from the saved tar);
- `tgproxy-outway.sh`: `up`, `block`, `down`, `status`, `list` (numbered), `names`, `resolve`, `families`, `check`, `install-unit`, `remove-unit`; `TGPROXY_DRY_RUN=1` prints the commands of both families;
- `tgproxy-remove.sh [--yes] [--purge]`: removes the `location` or the `server` blocks of the proxy name (nginx reloads its config) and the registration of its certificate (no more renewals), the container, the network, the image, the outway rules and units, and the entry in `data/extensions.compose.yml`. The rest of the stack (nginx, the decoy) keeps running. Without `--purge` the config, `state.env`, the saved image and the certificate of a separate proxy name stay: a reinstall gives the same link and works offline; `--purge` removes them and the scripts in `scripts/` as well (the certificate of `DOMAIN` is never touched).

**Security.**

- The secret path and the secret are part of the credentials: the link must not be published. Changing the path or the secret invalidates the old link. The secrets are kept only in `config.toml`, `state.env` (both 600) and in the link that TELEMT prints to its Docker log (readable only by root and the `docker` group).
- nginx writes no access log for this `location` (it contains client tokens) and passes TELEMT `X-Forwarded-For $remote_addr` (overwrite, not append); TELEMT trusts the header only from the compose network subnet, and port `18080` is not published.
- Container: `read_only`, `cap_drop: ALL`, `no-new-privileges`, memory and process limits, no management API, no native MTProxy listener. Any request to other paths is answered by the decoy.
- TELEMT resolves the address of `fakeapp` once at start: after only `fakeapp` is recreated, restart the proxy (`tgproxy-config.sh restart`; `./install.sh restart` restarts everything at once).
- `./install.sh remove` removes the `telemt` container, but not the outway rules and units: run `tgproxy-remove.sh --purge` first, or use `./install.sh remove --purge`, which calls it (the `ext_telegram_web_proxy_purge` hook) before deleting the data.

## Data directory

`<install directory>/data/fakeapp` (or `FAKEAPP_DATA_DIR`) is mounted into the container **read-only**: the application writes nothing.

| File | Where from | When the application sees changes |
|---|---|---|
| `login.html` | `gen/login.py` (a Go `html/template` template). Required: without it, or with a broken template, the application does not start | after `./install.sh restart` |
| `favicon.ico` | `gen/favicon.py` (the first letter of `APP_NAME`, the look from `PAGE_SEED`) | immediately |
| any other files and subdirectories | you put them there; served at the path `/<path>` | immediately |

Not served:

- hidden files and directories (`.*`);
- `/login.html` itself;
- directories (there is no listing).

A missing path gets a redirect to `/`.

Permissions: the container runs under an unprivileged uid, so files need `r` and directories `r-x` (the usual 644 and 755). `install` sets them itself (`chmod -R a+rX`).

A new look variant:

1. Change `PAGE_SEED` in `.env`.
2. Delete `login.html` and `favicon.ico`.
3. Run `sudo ./install.sh install` again.

## Removal

```bash
sudo ./install.sh remove          # containers, images, the renewal timer; the install directory and the data stay
sudo ./install.sh remove --purge  # and everything else
```

`remove` stops and removes the containers and images and the renewal timer (systemd or `/etc/cron.d/escape-certbot`). The install directory with `.env` and `data/` (certificates included) stays, so `install` brings the same installation back.

`remove --purge` also removes the system files of the extensions (the Telegram web proxy: units, the sysctl file, firewall and routing rules), deletes the data (including `data/letsencrypt`), the **whole install directory** (only if it carries the `.escape-install` marker and is not a system path) and the pointer `/etc/escape/install-dir`, after a confirmation (`-y` skips it). Docker and the installed packages stay. If you changed the ports of Xray or 3X-UI for the sake of this stack, restore them by hand.
