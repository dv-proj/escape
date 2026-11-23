# English messages (printf formats; a literal % is written %%). Same key set as the other language.
# shellcheck shell=bash disable=SC2034
MSG["app.cant_create"]="cannot create %s"
MSG["app.favicon_fail"]="favicon.ico generation failed"
MSG["app.file_generated"]="%s generated"
MSG["app.file_kept"]="%s exists; kept"
MSG["app.https_down"]="%s does not answer (see: ./install.sh logs)"
MSG["app.https_ok"]="%s answers (nginx -> fakeapp, trusted certificate)"
MSG["app.https_untrusted"]="%s answers, but the certificate is not trusted yet (temporary self-signed or LE_STAGING=1)"
MSG["app.login_fail"]="login.html generation failed"
MSG["app.missing_file"]="%s missing in %s"
MSG["app.not_readable"]="could not make every file in %s readable for the container"
MSG["app.project_ok"]="project: %s"
MSG["app.readable"]="%s is readable for the container (mounted read-only)"
MSG["app.sum_cert"]="Certificate: %s"
MSG["app.sum_files"]="Files      : %s (login.html: ./install.sh restart after editing; other files are served as is)"
MSG["app.sum_name"]="App name   : %s"
MSG["app.sum_nginx"]="nginx      : %s/conf.d/default.conf is generated (do not edit); extensions add locations in %s/locations.d/"
MSG["app.sum_random"]="Random data: https://%s%s/random-%s?size=1000 (0-500000 bytes)"
MSG["app.sum_renew"]="Renewal    : %s"
MSG["app.sum_site"]="Site       : https://%s%s/ (nginx container on ports %s/%s; the app is internal: http://fakeapp:%s)"
MSG["certs.cron_ok"]="renewal cron entry installed: %s"
MSG["certs.dns_mismatch"]="%s resolves to %s, which is not an address of this host (NAT, or the A record points elsewhere): check it, or the Let's Encrypt certificate will fail"
MSG["certs.dns_noresolve"]="%s does not resolve to an IPv4 address (no A record yet?): the Let's Encrypt certificate cannot be issued until it does"
MSG["certs.dns_ok"]="%s resolves to this host (%s)"
MSG["certs.failed"]="could not obtain a certificate for %s; nginx keeps serving the temporary self-signed one"
MSG["certs.hint1"]="check that: the DNS A/AAAA record of %s points to this server;"
MSG["certs.hint2"]="            port 80 is reachable from the internet (firewall, cloud security group) and is served by this stack;"
MSG["certs.hint3"]="            Let's Encrypt rate limits are not hit (try LE_STAGING=1 for tests)."
MSG["certs.issued"]="certificate issued for %s"
MSG["certs.reload_fail"]="nginx did not reload (see: ./install.sh logs)"
MSG["certs.reloaded"]="nginx reloaded with the new certificate"
MSG["certs.renew_fail"]="certbot renew failed"
MSG["certs.renew_reload_fail"]="nginx did not reload"
MSG["certs.renewed"]="certificates checked, nginx reloaded"
MSG["certs.requesting"]="requesting a certificate for %s from Let's Encrypt"
MSG["certs.retry"]="then retry with: sudo ./install.sh renew   (or re-run install)"
MSG["certs.selfsigned_fail"]="cannot create the temporary self-signed certificate (openssl)"
MSG["certs.selfsigned_ok"]="temporary self-signed certificate created for %s"
MSG["certs.staging_suffix"]=" (staging)"
MSG["certs.staging_warn"]="LE_STAGING=1: the certificate will not be trusted by browsers"
MSG["certs.state_cron"]="cron entry %s"
MSG["certs.state_none"]="not installed (run: sudo ./install.sh install)"
MSG["certs.state_timer"]="systemd timer %s (%s)"
MSG["certs.sum_le"]="Let's Encrypt%s, expires %s"
MSG["certs.sum_self"]="temporary self-signed (no Let's Encrypt certificate yet: sudo ./install.sh renew)"
MSG["certs.timer_fail"]="could not enable %s; using %s instead"
MSG["certs.timer_ok"]="renewal timer installed: %s (systemctl list-timers %s)"
MSG["certs.unknown"]="unknown"
MSG["cmd.confirm_purge"]="Remove the containers, their images, the renewal timer and the data (%s)?"
MSG["cmd.confirm_remove"]="Stop and remove the containers, their images and the renewal timer (data and certificates are kept)?"
MSG["cmd.delete_fail"]="could not fully delete %s"
MSG["cmd.finished"]="Install finished."
MSG["cmd.lang_needs_value"]="--lang needs a value"
MSG["cmd.no_env"]="%s not found; run: sudo ./install.sh install"
MSG["cmd.one_command"]="only one command allowed (got '%s' and '%s')"
MSG["cmd.purge_only"]="--purge only applies to 'remove'"
MSG["cmd.refresh_warn"]="could not refresh the nginx config in %s (need root?); using the existing one"
MSG["cmd.rm_done"]=".env, the project directory and Docker were kept"
MSG["cmd.rm_kept"]="the data (%s) and .env were kept (use --purge to delete the data)"
MSG["cmd.rm_skip_down"]="docker or %s not available; skipping 'docker compose down'"
MSG["cmd.status_cert"]="Certificate: %s"
MSG["cmd.status_renew"]="Renewal    : %s"
MSG["cmd.step_cert"]="Obtaining the Let's Encrypt certificate"
MSG["cmd.step_data"]="Preparing the data directory and the nginx config"
MSG["cmd.step_docker"]="Checking Docker and docker compose"
MSG["cmd.step_env"]="Preparing .env"
MSG["cmd.step_prereqs"]="Installing prerequisites (%s)"
MSG["cmd.step_renew"]="Renewing the certificates"
MSG["cmd.step_rm_containers"]="Removing the containers and the images"
MSG["cmd.step_rm_data"]="Deleting the data"
MSG["cmd.step_rm_timer"]="Removing the renewal timer"
MSG["cmd.step_stack"]="Building and starting nginx and fakeapp"
MSG["cmd.step_summary"]="summary"
MSG["cmd.step_timer"]="Installing the certificate renewal timer"
MSG["cmd.suspicious"]="refusing to delete suspicious path '%s'"
MSG["cmd.unknown_arg"]="unknown argument '%s' (see --help)"
MSG["cmd.with_needs_value"]="--with needs a value"
MSG["common.aborted"]="aborted"
MSG["common.all_valid"]="all values are valid"
MSG["common.assume_yes"]="%s -> yes (--yes)"
MSG["common.need_root"]="'%s' must be run as root (try: sudo ./install.sh %s)"
MSG["common.no_input"]="no input"
MSG["common.no_terminal"]="%s (no terminal; re-run with --yes to accept)"
MSG["common.phase"]="### Phase %s/3: %s"
MSG["common.problems_found"]="%d problem(s) found; nothing was changed:"
MSG["common.step"]="==> [%d/%d] %s"
MSG["common.step_failed"]="step \"%s\" failed (exit %d) at %s line %s: %s"
MSG["common.wait_timeout"]="timed out after %ss waiting for %s"
MSG["common.yn"]="[y/N]"
MSG["env.added_key"]="added missing %s to %s"
MSG["env.cannot_generate"]="cannot generate %s"
MSG["env.creating"]="creating %s"
MSG["env.default_invalid"]="default for %s is invalid: expected %s"
MSG["env.domain_bad_fix"]="DOMAIN in %s is not a valid DNS name; fix it and re-run install"
MSG["env.domain_missing"]="DOMAIN in %s is missing or not a DNS name (got '%s'); set it and re-run install"
MSG["env.domain_set"]="DOMAIN set in %s"
MSG["env.empty_generated"]="generated .env has an empty value for %s"
MSG["env.from_default"]="%s (default): %s"
MSG["env.from_environment"]="%s (from environment): %s"
MSG["env.generator_empty"]="generator for %s returned nothing"
MSG["env.invalid_email"]="invalid e-mail address"
MSG["env.invalid_from_env"]="%s from the environment is invalid: expected %s"
MSG["env.invalid_value"]="invalid value; expected %s"
MSG["env.lang_saved"]="FAKEAPP_LANG=%s saved in %s"
MSG["env.missing_no_default"]="%s is missing in %s and has no default; add it manually"
MSG["env.no_template"]="template not found: %s"
MSG["env.no_value"]="no value for %s"
MSG["env.port_range"]="%s in %s must be 1-65535 (got '%s')"
MSG["env.q_app_desc"]="Decoy site description"
MSG["env.q_app_kw"]="Decoy site keywords"
MSG["env.q_app_name"]="Decoy site name"
MSG["env.q_domain"]="DNS name of the site (its A record must point to this server), e.g. app.example.com"
MSG["env.q_email"]="E-mail for Let's Encrypt expiry notices (empty: none)"
MSG["env.q_tz"]="Time zone"
MSG["env.required_noterm"]="%s is required (set it in the environment; no terminal to ask)"
MSG["env.reusing"]="%s exists; reusing it (no questions asked)"
MSG["env.written"]="%s written (mode 600)"
MSG["ext.bad_chars"]="%s: unsupported characters in '%s'"
MSG["ext.bad_choice"]="bad choice '%s'"
MSG["ext.bad_id"]="%s: bad id '%s'"
MSG["ext.compose_not_found"]="%s: compose file not found: '%s'"
MSG["ext.compose_registered"]="compose file registered for '%s': %s"
MSG["ext.compose_unregistered"]="compose file unregistered for '%s'"
MSG["ext.empty_location"]="%s: empty location for '%s'"
MSG["ext.location_ok"]="nginx location '%s' installed: %s"
MSG["ext.location_removed"]="nginx location '%s' removed"
MSG["ext.menu_prompt"]="Install which? numbers separated by spaces, 'all' or empty for none: "
MSG["ext.menu_title"]="Additional features:"
MSG["ext.nginx_after_rm"]="nginx did not accept the config after removing '%s'"
MSG["ext.nginx_not_running"]="nginx is not running; the locations are used at its next start"
MSG["ext.nginx_rejected"]="nginx rejected the location '%s' (rolled back); see the message above"
MSG["ext.none"]="no extensions installed (see extensions.d/README.md)"
MSG["ext.step"]="Extension: %s"
MSG["ext.unknown"]="unknown extension '%s' (see: ./install.sh extensions)"
MSG["ext.validate_failed"]="extension '%s': validation failed"
MSG["hint.01"]="0 or 1"
MSG["hint.domain"]="a DNS name like app.example.com"
MSG["hint.email"]="an e-mail address"
MSG["hint.port"]="a port 1-65535"
MSG["hint.text"]="1-200 characters, no quotes, \$, backticks or backslashes"
MSG["hint.tz"]="an IANA zone like Europe/Berlin"
MSG["i18n.bad_lang"]="unknown language '%s' (from %s); use en or ru"
MSG["lbl.error"]="error"
MSG["lbl.ok"]="ok"
MSG["lbl.warning"]="warning"
MSG["nginx.by_holder"]=" by '%s'"
MSG["nginx.cert_le"]="Let's Encrypt certificate"
MSG["nginx.cert_self"]="temporary self-signed certificate"
MSG["nginx.http_port_warn"]="NGINX_HTTP_PORT=%s: Let's Encrypt validates on port 80 only; forward it here or issuing the certificate fails"
MSG["nginx.port_busy"]="port %s is already in use%s (another nginx / Xray / 3X-UI?); stop it or move it to another port, check with: ss -ltnp 'sport = :%s'. The nginx of this stack needs ports %s and %s (NGINX_HTTP_PORT / NGINX_HTTPS_PORT in %s)"
MSG["nginx.ports_free"]="ports %s and %s are free for nginx"
MSG["nginx.rendered"]="nginx config rendered: %s (%s)"
MSG["phase.collect"]="Collecting settings (questions only, nothing is changed)"
MSG["phase.deploy"]="Deploying"
MSG["phase.validate"]="Validating"
MSG["system.cant_enable_docker"]="could not enable docker.service"
MSG["system.compose_manual_io"]="cannot install the compose plugin for docker.io; install Docker Compose v2 manually"
MSG["system.compose_missing"]="the docker compose plugin is missing: installing it"
MSG["system.compose_na"]="docker compose is not available"
MSG["system.compose_old"]="docker compose %s is too old (need 2.20+); update docker-compose-plugin"
MSG["system.continue_anyway"]="Continue anyway using the %s Docker repository?"
MSG["system.daemon_start"]="the Docker daemon does not answer; starting docker.service"
MSG["system.daemon_unreachable"]="cannot talk to the Docker daemon (not running, or no permission: try sudo)"
MSG["system.desc_daemon"]="the Docker daemon"
MSG["system.docker_found"]="docker found: %s"
MSG["system.docker_missing"]="docker is not installed: installing Docker CE from download.docker.com"
MSG["system.docker_not_apt"]="docker is installed but not from apt (snap, binary?); install the Docker Compose v2 plugin manually"
MSG["system.docker_not_found"]="docker not found; run: sudo ./install.sh install"
MSG["system.fetch_key"]="fetching the Docker repository key"
MSG["system.installing_prereqs"]="installing prerequisites: %s"
MSG["system.no_apt"]="apt-get not found (only Debian/Ubuntu are supported)"
MSG["system.no_base"]="no Debian/Ubuntu base detected; the Docker apt repository cannot be configured"
MSG["system.no_codename"]="cannot determine the distribution codename"
MSG["system.no_osrel"]="/etc/os-release not found: unsupported system"
MSG["system.no_systemd"]="systemctl not found (systemd is required)"
MSG["system.prereqs_ok"]="prerequisites already installed (%s)"
MSG["system.unsupported"]="%s is not supported (need Ubuntu 22.04+ or Debian 12+)"
MSG["usage"]="$(cat <<'EOF_MSG'
Usage: ./install.sh [options] <command>

Deploys a docker compose stack: nginx in a container (ports 80 and 443 of the
host, TLS with a Let's Encrypt certificate for DOMAIN) in front of the decoy
web application (fake-webapp), which is reachable only inside the compose
network. Target systems: Ubuntu 22.04+ and Debian 12+.

Commands:
  install   Idempotent setup (root/sudo) in three phases: collect every answer
            (questions only), validate all values at once, then deploy. It
            reuses the system Docker (installs Docker CE only when docker is
            missing, the compose plugin when it is missing), creates .env
            (asks for the language, the DNS name of the site, the Let's
            Encrypt e-mail, the site name, description and keywords; the rest
            is generated), generates the missing login.html and favicon.ico
            and the nginx config, builds and starts the stack, obtains the
            certificate (certbot, webroot) and installs the renewal timer.
            Re-running rebuilds and restarts it; existing .env values and
            files in the data directory are kept.
  start     Start the stack (docker compose up -d --wait).
  stop      Stop the stack.
  restart   Restart the stack (e.g. after editing login.html).
  status    Show the container state, the certificate and check
            https://DOMAIN/ on this host (curl --resolve to 127.0.0.1).
  logs      Follow the container logs (Ctrl+C to quit).
  renew     Renew the certificates and reload nginx (run by the timer; issues
            the certificate when there is none yet). root/sudo.
  extensions  List additional features (extensions.d/); with --with ID,...
            install them.
  remove    Remove the stack, its images and the renewal timer (root/sudo).
            With --purge also delete the data directories (login.html,
            favicon.ico and your static files; the nginx config and the
            certificates). .env, the project and Docker are kept.

Options:
  -y, --yes   Assume "yes" for every confirmation.
  --with IDS  Extensions to install without the menu (comma list or "all");
              also FAKEAPP_EXTENSIONS. Used by install and extensions.
  --lang L    Language of the messages: en or ru (also FAKEAPP_LANG, saved in
              .env as FAKEAPP_LANG). Without it install asks first
              (default: English).
  --purge     With `remove`: also delete the data directories.
  -h, --help  Show this help.

Environment (used when install creates .env, without prompting):
  DOMAIN, LE_EMAIL, LE_STAGING, NGINX_HTTP_PORT, NGINX_HTTPS_PORT, FAKEAPP_PORT,
  APP_NAME, APP_DESCRIPTION, APP_KEYWORDS, FAKEAPP_LANG
              Unset APP_* values are generated at random (offered as defaults
              when interactive). Without a terminal every prompt uses its
              default, except DOMAIN, which is required.

Notes:
  * Ports 80 and 443 must be free (stop the host nginx / Xray first).
  * The site config is generated into data/nginx/ (do not edit it); extensions
    add locations as data/nginx/locations.d/<id>.conf (extensions.d/README.md).
  * start/stop/restart/status/logs need access to Docker (root, sudo or the
    docker group).
EOF_MSG
)"
