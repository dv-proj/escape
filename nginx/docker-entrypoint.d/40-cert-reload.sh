#!/bin/sh
# Started by the official nginx image entrypoint before nginx itself.
# Spawns a background loop that reloads nginx when the TLS certificate or key
# changes (acme.sh renewals write into the shared certs directory). This avoids
# mounting the docker socket into the acme container.
set -eu

CERT_DIR="${CERT_RELOAD_DIR:-/etc/nginx/certs}"
INTERVAL="${CERT_RELOAD_INTERVAL:-300}"

case "$INTERVAL" in
    '' | *[!0-9]*)
        echo "$0: invalid CERT_RELOAD_INTERVAL '$INTERVAL', using 300" >&2
        INTERVAL=300
        ;;
esac

stamp() {
    # mtime+size of both files; empty output if they are missing.
    stat -c '%Y:%s' "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" 2>/dev/null | tr '\n' ' ' || true
}

watch_certs() {
    last="$(stamp)"
    while sleep "$INTERVAL"; do
        cur="$(stamp)"
        [ "$cur" = "$last" ] && continue
        # The files may be mid-write; give acme.sh a moment, then validate.
        sleep 5
        cur="$(stamp)"
        if nginx -t -q 2>/dev/null; then
            echo "$(date -u '+%Y/%m/%d %H:%M:%S') [notice] cert-reload: certificate changed, reloading nginx"
            nginx -s reload || true
            last="$cur"
        else
            echo "$(date -u '+%Y/%m/%d %H:%M:%S') [warn] cert-reload: certificate changed but 'nginx -t' failed; will retry" >&2
        fi
    done
}

watch_certs </dev/null &
echo "$0: watching $CERT_DIR every ${INTERVAL}s for certificate changes"
