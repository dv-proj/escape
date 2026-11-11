#!/bin/sh
# nginx entrypoint: install the TLS certificates into /tmp/tls, start a watcher
# that reloads nginx when a certificate changes, then run nginx.
#
# Certificate source: /etc/letsencrypt/live/<name>/{fullchain,privkey}.pem on
# the shared volume (written by the certbot service). Until it exists (or
# without DOMAIN) a self-signed certificate is used, so port 443 is always up.
#
# Two names are handled, each with its own certificate: DOMAIN (the decoy site,
# installed in /tmp/tls) and, when active, WEBPROXY_DOMAIN (the Telegram
# web-proxy subdomain, installed in /tmp/tls/webproxy).
set -eu

DOMAIN="${DOMAIN:-}"
# Web-proxy subdomain: WEBPROXY_DOMAIN, else WEBPROXY_SUBDOMAIN.DOMAIN. Active
# only when DOMAIN and the subdomain are both set.
WEBPROXY_DOMAIN="${WEBPROXY_DOMAIN:-}"
if [ -z "$WEBPROXY_DOMAIN" ] && [ -n "$DOMAIN" ] && [ -n "${WEBPROXY_SUBDOMAIN:-}" ]; then
    WEBPROXY_DOMAIN="$WEBPROXY_SUBDOMAIN.$DOMAIN"
fi
[ -n "$DOMAIN" ] || WEBPROXY_DOMAIN=""
WEBPROXY_NGINX_IP="${WEBPROXY_NGINX_IP:-172.30.53.2}"
WEBPROXY_TELEMT_IP="${WEBPROXY_TELEMT_IP:-172.30.53.3}"
TLS=/tmp/tls
WTLS=/tmp/tls/webproxy
CONF=/tmp/nginx
INTERVAL="${CERT_CHECK_INTERVAL:-60}"
FAKEAPP_PORT="${FAKEAPP_PORT:-8080}"
TLS_PQ="${TLS_PQ:-1}"

log() { echo "tls-entrypoint: $*" >&2; }

mkdir -p "$TLS" "$CONF"
chmod 700 "$TLS"

case "$FAKEAPP_PORT" in
    '' | *[!0-9]*) log "FAKEAPP_PORT must be a number (got '$FAKEAPP_PORT')"; exit 1 ;;
esac
if [ "$FAKEAPP_PORT" -lt 1 ] || [ "$FAKEAPP_PORT" -gt 65535 ]; then
    log "FAKEAPP_PORT must be 1-65535 (got $FAKEAPP_PORT)"
    exit 1
fi
# TLS key exchange groups (http level: OpenSSL keeps the groups of the
# default server after SNI selects another one, so this applies to every name).
# 1: OpenSSL defaults, post-quantum hybrid X25519MLKEM768 first. 0: classic
# groups only; the Android Telegram WEB-proxy client fails the handshake when
# X25519MLKEM768 is selected (telegramdesktop/tproxy-server#16).
case "$TLS_PQ" in
    1) : >"$CONF/tls-groups.conf" ;;
    0) echo 'ssl_ecdh_curve X25519:prime256v1:secp384r1;' >"$CONF/tls-groups.conf" ;;
    *) log "TLS_PQ must be 0 or 1 (got '$TLS_PQ')"; exit 1 ;;
esac

echo "set \$fakeapp_upstream http://fakeapp:$FAKEAPP_PORT;" >"$CONF/fakeapp-upstream.conf"

# Plain-HTTP default: redirect to https when a real name is configured,
# otherwise serve fakeapp on port 80 as well.
if [ -n "$DOMAIN" ]; then
    echo 'location / { return 301 https://$host$request_uri; }' >"$CONF/http-default.conf"
else
    echo 'location / { include /etc/nginx/snippets/fakeapp.conf; }' >"$CONF/http-default.conf"
fi

# is_ipv4 STR: four dot-separated numbers 0-255.
is_ipv4() {
    case "$1" in
        '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
    esac
    oldifs="$IFS"
    IFS=.
    # shellcheck disable=SC2086 # split on dots
    set -- $1
    IFS="$oldifs"
    [ "$#" -eq 4 ] || return 1
    for octet in "$@"; do
        [ "${#octet}" -le 3 ] && [ "$octet" -le 255 ] || return 1
    done
}

# Web-proxy (Telemt) server blocks, generated into /tmp/nginx. Both files stay
# empty when the feature is off.
: >"$CONF/webproxy-http.conf"
: >"$CONF/webproxy-https.conf"
if [ -n "$WEBPROXY_DOMAIN" ]; then
    is_ipv4 "$WEBPROXY_NGINX_IP" || { log "WEBPROXY_NGINX_IP must be an IPv4 address (got '$WEBPROXY_NGINX_IP')"; exit 1; }
    is_ipv4 "$WEBPROXY_TELEMT_IP" || { log "WEBPROXY_TELEMT_IP must be an IPv4 address (got '$WEBPROXY_TELEMT_IP')"; exit 1; }
    case "$WEBPROXY_DOMAIN" in
        *[!A-Za-z0-9.-]*) log "WEBPROXY_DOMAIN may contain only letters, digits, dots and hyphens (got '$WEBPROXY_DOMAIN')"; exit 1 ;;
    esac
    mkdir -p "$WTLS"
    chmod 700 "$WTLS"

    # Port 80: the ACME challenge from the shared webroot, everything else
    # goes to the decoy site (the base domain).
    cat >"$CONF/webproxy-http.conf" <<EOF
server {
    listen 80;
    server_name $WEBPROXY_DOMAIN;
    access_log off;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type text/plain;
        # Unknown challenge paths get the same redirect as everything else.
        try_files \$uri @base;
    }

    location @base {
        return 302 https://$DOMAIN\$request_uri;
    }

    location / {
        return 302 https://$DOMAIN\$request_uri;
    }
}
EOF

    # Port 443: the whole vhost goes to Telemt (splitting paths would bypass
    # its decoy policy). The IP literal needs no resolver, and nginx starts
    # even while the webproxy container is down (requests then get 502).
    cat >"$CONF/webproxy-https.conf" <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name $WEBPROXY_DOMAIN;

    ssl_certificate $WTLS/fullchain.pem;
    ssl_certificate_key $WTLS/privkey.pem;

    # No access log: the ?bridge= query string is a credential.
    access_log off;

    client_max_body_size 4m;

    location / {
        proxy_pass http://$WEBPROXY_TELEMT_IP:18080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        # Overwrite (not append): Telemt trusts exactly one address here.
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_connect_timeout 5s;
        # Must exceed Telemt's 25s long-poll.
        proxy_read_timeout 90s;
        proxy_send_timeout 90s;
        proxy_next_upstream off;
    }
}

# Decoy upstream of Telemt: every invalid request it gets (wrong bridge,
# unknown path, /api/v1 without a session) is sent to the real site. Not
# published; reachable only from the webproxy network.
server {
    listen 8081;
    server_name _;
    access_log off;

    location / {
        return 302 https://$DOMAIN\$request_uri;
    }
}
EOF
fi

# cert_state NAME: hash of the Let's Encrypt certificate and key of NAME, or
# "self-signed" when there is none yet.
cert_state() {
    live="/etc/letsencrypt/live/$1"
    if [ -n "$1" ] && [ -r "$live/fullchain.pem" ] && [ -r "$live/privkey.pem" ]; then
        cat "$live/fullchain.pem" "$live/privkey.pem" | sha256sum | cut -d' ' -f1
    else
        echo self-signed
    fi
}

# make_self_signed NAME DIR: self-signed certificate (SAN = NAME) in DIR.
make_self_signed() {
    [ -s "$2/self.crt" ] && [ -s "$2/self.key" ] && return 0
    name="${1:-localhost}"
    case "$name" in
        *:*) san="IP:$name" ;;          # IPv6 address
        *[!0-9.]*) san="DNS:$name" ;;   # DNS name
        *) san="IP:$name" ;;            # IPv4 address
    esac
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -days 825 -subj "/CN=$name" -addext "subjectAltName=$san" \
        -keyout "$2/self.key" -out "$2/self.crt" 2>/dev/null
}

# install_cert NAME DIR STATE: copy the matching certificate into DIR
# atomically.
install_cert() {
    if [ "$3" = self-signed ]; then
        make_self_signed "$1" "$2"
        cp "$2/self.crt" "$2/fullchain.pem.new"
        cp "$2/self.key" "$2/privkey.pem.new"
    else
        cp "/etc/letsencrypt/live/$1/fullchain.pem" "$2/fullchain.pem.new"
        cp "/etc/letsencrypt/live/$1/privkey.pem" "$2/privkey.pem.new"
    fi
    chmod 600 "$2/privkey.pem.new"
    mv -f "$2/fullchain.pem.new" "$2/fullchain.pem"
    mv -f "$2/privkey.pem.new" "$2/privkey.pem"
}

state="$(cert_state "$DOMAIN")"
install_cert "$DOMAIN" "$TLS" "$state"
if [ "$state" = self-signed ] && [ -z "$DOMAIN" ]; then
    log "using a self-signed certificate (DOMAIN is not set)"
elif [ "$state" = self-signed ]; then
    log "using a self-signed certificate until the Let's Encrypt one for $DOMAIN appears"
else
    log "using the Let's Encrypt certificate for $DOMAIN"
fi

wstate=""
if [ -n "$WEBPROXY_DOMAIN" ]; then
    wstate="$(cert_state "$WEBPROXY_DOMAIN")"
    install_cert "$WEBPROXY_DOMAIN" "$WTLS" "$wstate"
    if [ "$wstate" = self-signed ]; then
        log "using a self-signed certificate until the Let's Encrypt one for $WEBPROXY_DOMAIN appears"
    else
        log "using the Let's Encrypt certificate for $WEBPROXY_DOMAIN"
    fi
fi

watch_cert() {
    while sleep "$INTERVAL"; do
        new="$(cert_state "$DOMAIN")"
        wnew=""
        [ -z "$WEBPROXY_DOMAIN" ] || wnew="$(cert_state "$WEBPROXY_DOMAIN")"
        [ "$new" != "$state" ] || [ "$wnew" != "$wstate" ] || continue
        [ "$new" = "$state" ] || install_cert "$DOMAIN" "$TLS" "$new"
        [ "$wnew" = "$wstate" ] || install_cert "$WEBPROXY_DOMAIN" "$WTLS" "$wnew"
        if nginx -t -q 2>/dev/null && nginx -s reload; then
            state="$new"
            wstate="$wnew"
            log "certificate changed; nginx reloaded"
        else
            log "the new certificate was rejected (nginx -t); retrying in ${INTERVAL}s"
        fi
    done
}
watch_cert &

exec nginx -g 'daemon off;'
