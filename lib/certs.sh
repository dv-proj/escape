# lib/certs.sh - TLS certificates: temporary self-signed, Let's Encrypt via certbot, renewal timer.
# Sourced by install.sh (see the source list there): functions and variable
# defaults only, nothing runs at source time.
# shellcheck shell=bash

RENEW_UNIT="fakeapp-certbot-renew"
RENEW_CRON=/etc/cron.d/fakeapp-certbot

# ensure_selfsigned DOMAIN: temporary certificate so that nginx can start
# before Let's Encrypt has issued the real one (kept while it matches DOMAIN).
ensure_selfsigned() {
    local domain=$1 dir="$NGINX_DATA/selfsigned"
    mkdir -p "$dir"
    if [[ -s "$dir/fullchain.pem" && -s "$dir/privkey.pem" ]] &&
        openssl x509 -in "$dir/fullchain.pem" -noout -checkhost "$domain" 2>/dev/null | grep -q 'does match'; then
        return 0
    fi
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$domain" \
        -addext "subjectAltName=DNS:$domain" \
        -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" 2>/dev/null ||
        die "$(t certs.selfsigned_fail)"
    chmod 600 "$dir/privkey.pem"
    info "$(t certs.selfsigned_ok "$domain")"
}

# have_le_cert DOMAIN: a Let's Encrypt certificate for DOMAIN exists.
have_le_cert() {
    [[ -s "$LE_DIR/live/$1/fullchain.pem" && -s "$LE_DIR/live/$1/privkey.pem" ]]
}

# issue_certificate: Let's Encrypt via the one-shot certbot container
# (webroot). Returns 1 with a hint on failure; callers carry on.
issue_certificate() {
    local domain email
    domain="$(site_domain)"
    email="$(env_get "$APP_DIR/.env" LE_EMAIL)"
    local -a args=(certonly --webroot -w /var/www/acme -d "$domain" --cert-name "$domain"
        --non-interactive --agree-tos --keep-until-expiring)
    if [[ -n "$email" ]]; then
        args+=(--email "$email" --no-eff-email)
    else
        args+=(--register-unsafely-without-email)
    fi
    [[ "$(env_or_default LE_STAGING 0)" != 1 ]] || {
        args+=(--staging)
        warn "$(t certs.staging_warn)"
    }
    info "$(t certs.requesting "$domain")"
    if ! compose run --rm -T certbot "${args[@]}" >&2; then
        warn "$(t certs.failed "$domain")"
        info "$(t certs.hint1 "$domain")"
        info "$(t certs.hint2)"
        info "$(t certs.hint3)"
        info "$(t certs.retry)"
        return 1
    fi
    ok "$(t certs.issued "$domain")"
    render_nginx_conf
    if nginx_reload; then
        ok "$(t certs.reloaded)"
    else
        warn "$(t certs.reload_fail)"
        return 1
    fi
}

# renew_certificates: the work of the timer: renew, then reload nginx.
renew_certificates() {
    local domain
    domain="$(site_domain)"
    if ! have_le_cert "$domain"; then
        issue_certificate
        return
    fi
    compose run --rm -T certbot renew --quiet >&2 || {
        warn "$(t certs.renew_fail)"
        return 1
    }
    render_nginx_conf
    nginx_reload || {
        warn "$(t certs.renew_reload_fail)"
        return 1
    }
    ok "$(t certs.renewed)"
}

# install_renew_timer: systemd timer (twice a day) running `install.sh renew`;
# /etc/cron.d entry when systemd is not running.
install_renew_timer() {
    local script="$APP_DIR/install.sh"
    if [[ -d /run/systemd/system ]]; then
        cat >"/etc/systemd/system/$RENEW_UNIT.service" <<UNIT
[Unit]
Description=Renew Let's Encrypt certificates of the fakeapp stack
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart="$script" renew
UNIT
        cat >"/etc/systemd/system/$RENEW_UNIT.timer" <<UNIT
[Unit]
Description=Renew Let's Encrypt certificates of the fakeapp stack twice a day

[Timer]
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
        systemctl daemon-reload
        if systemctl enable --now "$RENEW_UNIT.timer" >/dev/null 2>&1; then
            ok "$(t certs.timer_ok "$RENEW_UNIT.timer" "$RENEW_UNIT.timer")"
            rm -f "$RENEW_CRON"
            return 0
        fi
        warn "$(t certs.timer_fail "$RENEW_UNIT.timer" "$RENEW_CRON")"
    fi
    printf '# Renew Let'"'"'s Encrypt certificates of the fakeapp stack (installed by install.sh).\n17 3,15 * * * root "%s" renew >/dev/null 2>&1\n' "$script" >"$RENEW_CRON"
    chmod 644 "$RENEW_CRON"
    ok "$(t certs.cron_ok "$RENEW_CRON")"
}

# remove_renew_timer: remove the systemd timer and the cron entry.
remove_renew_timer() {
    if [[ -f "/etc/systemd/system/$RENEW_UNIT.timer" ]]; then
        systemctl disable --now "$RENEW_UNIT.timer" >/dev/null 2>&1 || true
    fi
    rm -f "/etc/systemd/system/$RENEW_UNIT.timer" "/etc/systemd/system/$RENEW_UNIT.service" "$RENEW_CRON"
    [[ ! -d /run/systemd/system ]] || systemctl daemon-reload 2>/dev/null || true
}

renew_timer_state() {
    if [[ -f "/etc/systemd/system/$RENEW_UNIT.timer" ]]; then
        t certs.state_timer "$RENEW_UNIT.timer" "$(systemctl is-active "$RENEW_UNIT.timer" 2>/dev/null || true)"
    elif [[ -f "$RENEW_CRON" ]]; then
        t certs.state_cron "$RENEW_CRON"
    else
        t certs.state_none
    fi
}

# cert_summary: one line about the certificate nginx serves.
cert_summary() {
    local domain f end
    domain="$(site_domain)"
    if have_le_cert "$domain"; then
        end="$(openssl x509 -in "$LE_DIR/live/$domain/fullchain.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
        t certs.sum_le "$([[ "$(env_or_default LE_STAGING 0)" != 1 ]] || t certs.staging_suffix)" "${end:-$(t certs.unknown)}"
    else
        t certs.sum_self
    fi
}

# validate_domain_dns: phase 2: DOMAIN should resolve to this host, or Let's
# Encrypt cannot validate it. Only warnings: DNS may still be propagating, or
# the host sits behind NAT; the install continues with a self-signed certificate.
validate_domain_dns() {
    local domain addrs local_addrs a
    domain="$(env_value DOMAIN)"
    valid_domain "$domain" || return 0
    addrs="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if [[ -z "$addrs" ]]; then
        warn "$(t certs.dns_noresolve "$domain")"
        return 0
    fi
    command -v ip >/dev/null 2>&1 || return 0
    local_addrs="$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
    for a in $addrs; do
        grep -qxF "$a" <<<"$local_addrs" && {
            ok "$(t certs.dns_ok "$domain" "$a")"
            return 0
        }
    done
    addrs="$(tr '\n' ' ' <<<"$addrs")"
    warn "$(t certs.dns_mismatch "$domain" "${addrs% }")"
}
