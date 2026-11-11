# webproxy

Optional Telegram web proxy ([Telemt](https://github.com/telemt/telemt), WEB
transport) behind the nginx TLS front.

- Enabled by `WEBPROXY_SUBDOMAIN` in `.env` (full name
  `<WEBPROXY_SUBDOMAIN>.<DOMAIN>`, DNS must point at this host) with
  `COMPOSE_PROFILES=webproxy` (set by `vpn.sh`).
- nginx gets a separate Let's Encrypt certificate for the subdomain and
  proxies the whole vhost to Telemt (`http://WEBPROXY_TELEMT_IP:18080`) over the
  `webproxy` network (`WEBPROXY_SUBNET`, `WEBPROXY_NGINX_IP`,
  `WEBPROXY_TELEMT_IP`). Nothing is published by the Telemt container.
- Config: `${WEBPROXY_DATA_DIR:-data/webproxy}/telemt/config.toml` (0600, owned
  by the host user that runs Docker). It must listen on `0.0.0.0:18080`, trust
  `X-Forwarded-For` only from `WEBPROXY_NGINX_IP`, and use
  `http://<WEBPROXY_NGINX_IP>:8081` as the decoy upstream (nginx redirects
  every such request to `https://<DOMAIN>`).
- The access log is off for the subdomain: the `?bridge=` query is a credential.
