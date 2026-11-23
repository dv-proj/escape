# lib/nginx.sh - nginx config rendering, the nginx data directory, host port checks.
# data/nginx/servers.d/ holds whole server blocks of extensions (their own
# names, see ext_nginx_server_put): <id>.conf.in is the source written by the
# extension, <id>.conf the rendered file nginx includes at http level.
# data/nginx/stream.d/ holds the SNI routes (<id>.map) and upstreams (<id>.conf)
# of the TLS front (stream block, see ext_nginx_stream_put).
#
# Ports: the host HTTPS port (NGINX_HTTPS_PORT) is published to the TLS front
# (container port NGINX_FRONT_PORT, conf.d/front.stream); the HTTPS server
# listens on container port 443 with the PROXY protocol and is not published.
# Sourced by install.sh (see the source list there): functions and variable
# defaults only, nothing runs at source time.
# shellcheck shell=bash

# Container port of the TLS front (stream); nginx/docker-compose.yml publishes it.
NGINX_FRONT_PORT=4443

# port_in_use PORT: something listens on TCP PORT of the host (any address).
port_in_use() {
    ss -Hltn "sport = :$1" 2>/dev/null | grep -q .
}

# valid_free_port VALUE: a port 1024-65535 that nothing listens on yet.
valid_free_port() {
    valid_port "$1" && (($1 >= 1024)) && ! port_in_use "$1"
}

# first_free_port FROM: the first free port >= FROM (FROM itself if none found).
first_free_port() {
    local p
    for ((p = $1; p < $1 + 200 && p <= 65535; p++)); do
        port_in_use "$p" || {
            printf '%s' "$p"
            return 0
        }
    done
    printf '%s' "$1"
}

nginx_http_port() {
    local p
    p="$(env_or_default NGINX_HTTP_PORT 80)"
    valid_port "$p" || die "$(t env.port_range NGINX_HTTP_PORT "$APP_DIR/.env" "$p")"
    printf '%s' "$p"
}

nginx_https_port() {
    local p
    p="$(env_or_default NGINX_HTTPS_PORT 443)"
    valid_port "$p" || die "$(t env.port_range NGINX_HTTPS_PORT "$APP_DIR/.env" "$p")"
    printf '%s' "$p"
}

# port_holder PORT: the program listening on TCP PORT (needs root for others' sockets).
port_holder() {
    ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -n1 | sed 's/^users:(("//; s/"$//' || true
}

# stack_running SERVICE: the compose service has a running container.
stack_running() {
    [[ -n "$(compose ps -q "$1" 2>/dev/null)" ]]
}

# nginx_running_here: an nginx container of this project is running. Looks at
# docker directly (no compose wrapper: that one creates files in data/), so it
# is safe in the validate phase; false when docker is missing or not running.
nginx_running_here() {
    command -v docker >/dev/null 2>&1 || return 1
    [[ -n "$(docker ps -q --filter "label=com.docker.compose.service=nginx" \
        --filter "label=com.docker.compose.project.working_dir=$APP_DIR" 2>/dev/null)" ]]
}

# validate_ports: phase 2: the nginx host ports (80/443) must be free, or
# already ours. Problems are recorded; invalid port values are reported by
# validate_env and skipped here.
validate_ports() {
    local port holder http https bad=0
    http="$(env_or_default NGINX_HTTP_PORT 80)"
    https="$(env_or_default NGINX_HTTPS_PORT 443)"
    valid_port "$http" && valid_port "$https" || return 0
    for port in "$http" "$https"; do
        if port_in_use "$port" && ! nginx_running_here; then
            holder="$(port_holder "$port")"
            bad=1
            problem "$(t nginx.port_busy "$port" "${holder:+$(t nginx.by_holder "$holder")}" "$port" "$http" "$https" "$APP_DIR/.env")"
        fi
    done
    ((bad)) || ok "$(t nginx.ports_free "$http" "$https")"
    [[ "$http" == 80 ]] || warn "$(t nginx.http_port_warn "$http")"
}

# render_nginx_conf [TEMPLATE OUT]: fill nginx/default.conf.template from .env
# (default OUT: data/nginx/conf.d/default.conf). The Let's Encrypt certificate
# is used when it exists, else the temporary self-signed one.
render_nginx_conf() {
    local tpl="${1:-$APP_DIR/nginx/default.conf.template}"
    local out="${2:-$NGINX_DATA/conf.d/default.conf}"
    local domain port https_port cert key suffix content tmp
    domain="$(site_domain)"
    port="$(fakeapp_port)"
    https_port="$(nginx_https_port)"
    suffix=""
    [[ "$https_port" == 443 ]] || suffix=":$https_port"
    if have_le_cert "$domain"; then
        cert="/etc/letsencrypt/live/$domain/fullchain.pem"
        key="/etc/letsencrypt/live/$domain/privkey.pem"
    else
        cert=/etc/nginx/selfsigned/fullchain.pem
        key=/etc/nginx/selfsigned/privkey.pem
    fi
    [[ -f "$tpl" ]] || die "$(t env.no_template "$tpl")"
    content="$(<"$tpl")"
    content="${content//@DOMAIN@/$domain}"
    content="${content//@FAKEAPP_PORT@/$port}"
    content="${content//@HTTPS_PORT_SUFFIX@/$suffix}"
    content="${content//@SSL_CERT@/$cert}"
    content="${content//@SSL_KEY@/$key}"
    mkdir -p "$(dirname "$out")"
    tmp="$(mktemp "$out.XXXXXX")"
    printf '%s\n' "$content" >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$out"
    # The default call (no TEMPLATE) renders the TLS front (stream block) next to it.
    [[ -n "${1:-}" ]] || render_stream_conf
}

# render_stream_conf [TEMPLATE OUT]: fill nginx/stream.conf.template (default
# OUT: data/nginx/conf.d/front.stream, included by the stream block of nginx.conf).
render_stream_conf() {
    local tpl="${1:-$APP_DIR/nginx/stream.conf.template}"
    local out="${2:-$NGINX_DATA/conf.d/front.stream}"
    local content tmp
    [[ -f "$tpl" ]] || die "$(t env.no_template "$tpl")"
    content="$(<"$tpl")"
    content="${content//@FRONT_PORT@/$NGINX_FRONT_PORT}"
    mkdir -p "$(dirname "$out")" "$NGINX_DATA/stream.d"
    tmp="$(mktemp "$out.XXXXXX")"
    printf '%s\n' "$content" >"$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$out"
}

# render_ext_servers: render every data/nginx/servers.d/<id>.conf.in into
# <id>.conf. A first line "# cert-domain: NAME" selects the certificate that
# replaces @SSL_CERT@ / @SSL_KEY@ (Let's Encrypt when issued, else the
# temporary self-signed one of NAME, see ext_cert_paths).
render_ext_servers() {
    local dir="$NGINX_DATA/servers.d" src out name cert key content tmp
    [[ -d "$dir" ]] || return 0
    for src in "$dir"/*.conf.in; do
        [[ -f "$src" ]] || continue
        out="${src%.in}"
        content="$(<"$src")"
        name="$(sed -n '1s/^# cert-domain: \([A-Za-z0-9.-]*\)$/\1/p' "$src")"
        if [[ -n "$name" ]]; then
            read -r cert key < <(ext_cert_paths "$name")
            content="${content//@SSL_CERT@/$cert}"
            content="${content//@SSL_KEY@/$key}"
        fi
        tmp="$(mktemp "$out.XXXXXX")"
        printf '%s\n' "$content" >"$tmp"
        chmod 644 "$tmp"
        mv -f "$tmp" "$out"
    done
}

# prepare_nginx_dir: data/nginx/{conf.d,locations.d,servers.d,stream.d,webroot,selfsigned},
# the temporary certificate and the rendered configs (base, TLS front, servers.d).
prepare_nginx_dir() {
    local d owner
    owner="$(project_owner)"
    mkdir -p "$NGINX_DATA/conf.d" "$NGINX_DATA/locations.d" "$NGINX_DATA/servers.d" "$NGINX_DATA/stream.d" "$NGINX_DATA/webroot" "$NGINX_DATA/selfsigned" "$LE_DIR"
    ensure_selfsigned "$(site_domain)"
    render_nginx_conf
    render_ext_servers
    chmod -R a+rX "$NGINX_DATA/conf.d" "$NGINX_DATA/locations.d" "$NGINX_DATA/servers.d" "$NGINX_DATA/stream.d" "$NGINX_DATA/webroot"
    for d in "$DATA_DIR" "$NGINX_DATA" "$NGINX_DATA/conf.d" "$NGINX_DATA/locations.d" "$NGINX_DATA/servers.d" "$NGINX_DATA/stream.d" "$NGINX_DATA/webroot"; do
        chown "$owner" "$d" 2>/dev/null || true
    done
    ok "$(t nginx.rendered "$NGINX_DATA/conf.d/default.conf" "$(have_le_cert "$(site_domain)" && t nginx.cert_le || t nginx.cert_self)")"
}

# nginx_front_ready: the running nginx container has the TLS front (the main
# config with the stream block and data/nginx/stream.d mounted). A container
# created before the front existed publishes the HTTPS server directly, which no
# longer works with the PROXY protocol listener of the rendered config: it is
# recreated once with the current compose file (a few seconds without the site).
# Nothing to do when nginx is not running (its next start uses the new files).
nginx_front_ready() {
    stack_running nginx || return 0
    compose exec -T nginx sh -c 'test -d /etc/nginx/stream.d && grep -qF "conf.d/*.stream" /etc/nginx/nginx.conf' >/dev/null 2>&1 && return 0
    [[ -f "$NGINX_DATA/conf.d/front.stream" ]] || render_nginx_conf
    mkdir -p "$NGINX_DATA/stream.d"
    chmod a+rX "$NGINX_DATA/stream.d" 2>/dev/null || true
    info "$(t nginx.recreate_front)"
    compose up -d --wait nginx </dev/null >&2
}

# nginx_reload: test the config in the running container and reload it.
nginx_reload() {
    nginx_front_ready || return 1
    compose exec -T nginx nginx -t >/dev/null 2>&1 || {
        compose exec -T nginx nginx -t >&2 || true
        return 1
    }
    compose exec -T nginx nginx -s reload >/dev/null 2>&1
}
