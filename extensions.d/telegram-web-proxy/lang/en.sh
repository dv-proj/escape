# English messages (printf formats; a literal % is written %%). Same key set as the other language.
# shellcheck shell=bash disable=SC2034
MSG["telegram-web-proxy.title"]="Telegram web proxy (TELEMT, tg://webproxy link, selectable outgoing interface)"
MSG["tgp.auto_no_route"]="TGPROXY_OUTWAY=auto: the host has no default route; name the interface"
MSG["tgp.auto_picked"]="outway (auto, interface of the default route): %s"
MSG["tgp.bad_iface"]="'%s' is not a usable interface (see the list above)"
MSG["tgp.bad_rotate"]="bad TGPROXY_ROTATE '%s' (path|secret|all)"
MSG["tgp.bad_version"]="bad TGPROXY_TELEMT_VERSION '%s'"
MSG["tgp.choose_outway"]="choose the outgoing interface: TGPROXY_OUTWAY=<interface> (or auto = the interface of the default route)"
MSG["tgp.client_info"]="Telegram Desktop 7.1+ is required (the WEB proxy type); other clients cannot use this link"
MSG["tgp.dir_spaces"]="scripts directory with spaces is not supported: '%s'"
MSG["tgp.invalid_outway"]="invalid outway '%s'"
MSG["tgp.link_hint"]="Link (open it in Telegram Desktop 7.1 or newer):"
MSG["tgp.manage_info"]="Manage without the repository: %s/tgproxy-config.sh (link, status, outway, rotate) and tgproxy-remove.sh"
MSG["tgp.menu_head"]="The Telegram web proxy is installed (outway: %s)."
MSG["tgp.menu_items"]="$(cat <<'EOF_MSG'
  1) update (pull the image, rebuild the config, restart; optional rotation)
  2) remove
  3) show link
  4) change outway (outgoing interface)
  5) rotate secret path / secret
  6) status
  0) cancel
EOF_MSG
)"
MSG["tgp.menu_prompt"]="Choose: "
MSG["tgp.need_tool"]="'%s' is required (apt install iproute2 openssl python3 coreutils libc-bin)"
MSG["tgp.no_collect"]="telegram-web-proxy: the collect phase did not run"
MSG["tgp.no_domain"]="DOMAIN is not known (no %s yet); run: sudo ./install.sh install"
MSG["tgp.no_ip_for_domain"]="cannot resolve an IPv4 address for %s; set TGPROXY_PUBLIC_IP"
MSG["tgp.no_iproute"]="iproute2 is not installed yet: the interface is checked once the prerequisites are installed"
MSG["tgp.no_project_net"]="the project network of the stack does not exist: start the stack first (./install.sh start)"
MSG["tgp.no_project_subnet"]="cannot determine the IPv4 subnet of the project network"
MSG["tgp.no_subnet"]="no usable subnet for the telemt network"
MSG["tgp.not_installed"]="the Telegram web proxy is not installed (TGPROXY_ACTION=%s); use TGPROXY_ACTION=install"
MSG["tgp.nothing_done"]="nothing done"
MSG["tgp.outway_done"]="outway: %s"
MSG["tgp.outway_info"]="Outgoing interface (outway): %s; status: %s/tgproxy-outway.sh status"
MSG["tgp.outway_intro"]="The outgoing interface carries only the telemt container traffic to Telegram:"
MSG["tgp.outway_problem"]="outway '%s': %s"
MSG["tgp.path_spaces"]="the project path must not contain spaces: '%s'"
MSG["tgp.port_warn"]="NGINX_HTTPS_PORT is %s: Telegram Desktop requires port 443 for web proxies"
MSG["tgp.q_outway"]="Outgoing interface%s: "
MSG["tgp.q_purge"]="Also delete the config and the secrets (data/telegram-web-proxy)? Otherwise a reinstall restores the same link."
MSG["tgp.q_remove"]="Remove the Telegram web proxy (the rest of the stack keeps running)?"
MSG["tgp.q_rotate"]="Rotate: path, secret or all [all]: "
MSG["tgp.q_rotate_all"]="Also rotate the secret path and the user secret (the old link stops working)?"
MSG["tgp.ready"]="Telegram web proxy is ready"
MSG["tgp.scripts_ok"]="standalone scripts installed in %s (tgproxy-config.sh, tgproxy-outway.sh, tgproxy-remove.sh)"
MSG["tgp.secret_warn"]="the secret path is part of the credential: keep the link private; rotating the path or the secret invalidates old links"
MSG["tgp.set_rotate"]="set TGPROXY_ROTATE=path|secret|all"
MSG["tgp.unhealthy"]="telemt did not become healthy (see the log above); fix the cause and re-run, or remove it"
MSG["tgp.unknown_action"]="unknown TGPROXY_ACTION '%s' (install|update|remove|link|outway|rotate|status)"
