#!/bin/sh
# certbot loop: obtain the Let's Encrypt certificates for $DOMAIN and
# $WEBPROXY_DOMAIN, one certificate each (HTTP-01, webroot shared with nginx),
# and renew them when due. `certonly
# --keep-until-expiring` does both: it issues a missing certificate and renews
# one that expires within 30 days, otherwise it does nothing.
#
# Each certificate lands in /etc/letsencrypt/live/<name>/ on the shared
# volume; nginx notices the change and reloads by itself.
set -u

DOMAIN="${DOMAIN:-}"
# Web-proxy subdomain: WEBPROXY_DOMAIN, else WEBPROXY_SUBDOMAIN.DOMAIN; active
# only when DOMAIN is set too. It gets its own, separate certificate.
WEBPROXY_DOMAIN="${WEBPROXY_DOMAIN:-}"
if [ -z "$WEBPROXY_DOMAIN" ] && [ -n "$DOMAIN" ] && [ -n "${WEBPROXY_SUBDOMAIN:-}" ]; then
    WEBPROXY_DOMAIN="$WEBPROXY_SUBDOMAIN.$DOMAIN"
fi
ACME_EMAIL="${ACME_EMAIL:-}"
ACME_STAGING="${ACME_STAGING:-0}"
WEBROOT=/var/www/acme
CHECK_INTERVAL="${CERT_RENEW_INTERVAL:-43200}" # 12h between successful runs
RETRY_INTERVAL="${CERT_RETRY_INTERVAL:-900}"   # 15m after a failure

log() { echo "certbot-loop: $*" >&2; }

idle() {
    log "$*"
    while :; do sleep 86400; done
}

[ -n "$DOMAIN" ] || idle "DOMAIN is not set: no certificate is requested (nginx serves a self-signed one)"
case "$DOMAIN" in
    *:*) is_ip=1 ;;        # IPv6 address
    *[!0-9.]*) is_ip=0 ;;  # DNS name
    *) is_ip=1 ;;          # IPv4 address
esac
[ "$is_ip" = 0 ] || idle "DOMAIN=$DOMAIN is an IP address: no certificate is requested (nginx serves a self-signed one)"

NAMES="$DOMAIN"
[ -z "$WEBPROXY_DOMAIN" ] || NAMES="$DOMAIN $WEBPROXY_DOMAIN"

# run_certbot NAME: issue/renew the certificate of one name. A staging
# certificate is replaced once after switching ACME_STAGING back to 0.
run_certbot() {
    name="$1"
    set -- certonly --webroot -w "$WEBROOT" -d "$name" --cert-name "$name" \
        --non-interactive --agree-tos --keep-until-expiring
    if [ -n "$ACME_EMAIL" ]; then
        set -- "$@" --email "$ACME_EMAIL" --no-eff-email
    else
        set -- "$@" --register-unsafely-without-email
    fi
    force=""
    if [ "$ACME_STAGING" = 1 ]; then
        set -- "$@" --test-cert
    elif grep -qs 'acme-staging' "/etc/letsencrypt/renewal/$name.conf"; then
        log "existing certificate for $name is a staging one; requesting a production certificate"
        force=--force-renewal
    fi
    # shellcheck disable=SC2086 # $force is empty or a single flag
    certbot "$@" $force
}

mkdir -p "$WEBROOT"
# Give nginx a moment to start serving the challenge directory.
sleep 5
while :; do
    # A failure for one name must not block the others.
    failed=0
    for name in $NAMES; do
        run_certbot "$name" || {
            failed=1
            log "certbot failed for $name (check that it points here and port 80 is reachable)"
        }
    done
    if [ "$failed" = 0 ]; then
        sleep "$CHECK_INTERVAL"
    else
        log "retrying in ${RETRY_INTERVAL}s"
        sleep "$RETRY_INTERVAL"
    fi
done
