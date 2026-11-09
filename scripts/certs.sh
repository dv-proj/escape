#!/usr/bin/env bash
# TLS certificate management for the VPN stack (acme.sh + Let's Encrypt).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat <<'EOF'
Usage: scripts/certs.sh <command>

Manage the TLS certificate in $DATA_DIR/certs (fullchain.pem, privkey.pem),
shared by nginx (read-only) and xui (read-only), written by the acme service.

Commands:
  bootstrap   Create a self-signed placeholder certificate for $DOMAIN if no
              certificate exists yet, so nginx can start before the first
              ACME issuance. Runs openssl in a throwaway container; the stack
              does not need to be running. Also creates the data directories.
  issue       Register the ACME account ($ACME_EMAIL), issue a certificate for
              $DOMAIN via HTTP-01 (webroot served by nginx on port 80) and
              install it into the certs directory, then reload nginx.
              Idempotent: an existing valid certificate is kept (acme.sh skips
              issuance until renewal is due). Requires running nginx and acme
              services and DNS for $DOMAIN pointing to this host.
  renew       Force renewal of the certificate for $DOMAIN, reinstall it and
              reload nginx. Requires running nginx and acme services.
  status      Show the installed certificate (subject, issuer, validity) and,
              if the acme service is running, acme.sh's certificate list.
  help        Show this help.

Environment (.env at the repo root, or ENV_FILE=path):
  DOMAIN        (all commands)
  ACME_EMAIL    (issue)
  ACME_SERVER   (issue; default: letsencrypt; letsencrypt_test = staging)
  DATA_DIR      (default: ./data)
  ACME_IMAGE    (bootstrap, status)

Background renewal: the acme container runs acme.sh's cron job (daemon mode);
renewed certificates are re-installed automatically and nginx reloads itself
when the files change (nginx/docker-entrypoint.d/40-cert-reload.sh).
EOF
}

CERT_FILE=fullchain.pem
KEY_FILE=privkey.pem

# Data directories and the placeholder certificate are created from inside a
# container so that they are owned by container root: the host user under
# rootless docker, root under rootful docker. The services run with
# cap_drop: ALL (no CAP_DAC_OVERRIDE), so ownership matters.
# shellcheck disable=SC2016  # the script below is expanded by the container shell
BOOTSTRAP_SCRIPT='
set -eu
mkdir -p /data/certs /data/acme /data/xui /data/webroot
chmod 700 /data/certs /data/acme /data/xui
chmod 755 /data/webroot
if [ -s /data/certs/fullchain.pem ] && [ -s /data/certs/privkey.pem ]; then
    echo exists
    exit 0
fi
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 30 -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" \
    -keyout /data/certs/privkey.pem -out /data/certs/fullchain.pem >/dev/null 2>&1
chmod 600 /data/certs/privkey.pem
chmod 644 /data/certs/fullchain.pem
echo created
'

cmd_bootstrap() {
    require_vars DOMAIN
    local data out
    data="$(data_dir)"
    mkdir -p "$data"
    out="$(docker run --rm --network none -e DOMAIN -v "$data:/data" \
        --entrypoint /bin/sh "$ACME_IMAGE" -c "$BOOTSTRAP_SCRIPT")" ||
        die "failed to prepare $data (is docker running and $ACME_IMAGE pullable?)"
    case "$out" in
        *exists*) log "certificate already present in $data/certs; nothing to do" ;;
        *created*) log "placeholder certificate for $DOMAIN written to $data/certs (replace it with: scripts/certs.sh issue)" ;;
        *) die "unexpected bootstrap output: $out" ;;
    esac
}

acme() {
    compose exec -T acme acme.sh "$@"
}

reload_nginx() {
    if compose exec -T nginx nginx -t -q && compose exec -T nginx nginx -s reload; then
        log "nginx reloaded"
    else
        die "nginx rejected the new configuration/certificate; see: docker compose logs nginx"
    fi
}

install_cert() {
    log "installing certificate into the certs directory"
    acme --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "/certs/$CERT_FILE" \
        --key-file "/certs/$KEY_FILE" >/dev/null ||
        die "acme.sh --install-cert failed for $DOMAIN"
}

cmd_issue() {
    require_vars DOMAIN ACME_EMAIL
    require_running nginx acme
    log "registering ACME account $ACME_EMAIL at $ACME_SERVER"
    acme --register-account -m "$ACME_EMAIL" --server "$ACME_SERVER" >/dev/null ||
        die "ACME account registration failed"

    log "issuing certificate for $DOMAIN (HTTP-01 webroot)"
    local rc=0
    acme --issue -d "$DOMAIN" --webroot /webroot --server "$ACME_SERVER" \
        --keylength ec-256 || rc=$?
    case "$rc" in
        0) log "certificate issued" ;;
        2) log "certificate exists and is not due for renewal; keeping it" ;;
        *) die "acme.sh --issue failed (exit $rc). Check that DNS for $DOMAIN points here and port 80 is reachable." ;;
    esac
    install_cert
    reload_nginx
}

cmd_renew() {
    require_vars DOMAIN
    require_running nginx acme
    log "forcing renewal of the certificate for $DOMAIN"
    acme --renew -d "$DOMAIN" --ecc --force ||
        die "acme.sh --renew failed for $DOMAIN (was it issued with: scripts/certs.sh issue?)"
    install_cert
    reload_nginx
}

cmd_status() {
    require_vars DOMAIN
    local certs
    certs="$(data_dir certs)"
    log "installed certificate ($certs/$CERT_FILE):"
    # Read from a container: the directory is owned by container root.
    docker run --rm --network none --entrypoint openssl -v "$certs:/certs:ro" "$ACME_IMAGE" \
        x509 -in "/certs/$CERT_FILE" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null ||
        warn "no readable certificate at $certs/$CERT_FILE (run: scripts/certs.sh bootstrap)"
    if service_running acme; then
        log "acme.sh certificates:"
        acme --list || warn "acme.sh --list failed"
    else
        warn "acme service is not running; skipping acme.sh --list"
    fi
}

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        -h | --help | help)
            usage
            return 0
            ;;
        bootstrap | issue | renew | status) ;;
        *)
            usage >&2
            die "unknown command: $cmd"
            ;;
    esac
    need_cmd docker
    load_env
    "cmd_$cmd"
}

main "$@"
