# Russian messages (printf formats; a literal % is written %%). Same key set as the other language.
# shellcheck shell=bash disable=SC2034
MSG["telegram-web-proxy.title"]="Telegram web proxy (TELEMT, ссылка tg://webproxy, выбор исходящего интерфейса)"
MSG["tgp.auto_no_route"]="TGPROXY_OUTWAY=auto: на хосте нет маршрута по умолчанию; укажите интерфейс явно"
MSG["tgp.auto_picked"]="outway (auto, интерфейс маршрута по умолчанию): %s"
MSG["tgp.bad_iface"]="'%s' нельзя использовать как интерфейс (см. список выше)"
MSG["tgp.bad_rotate"]="неверный TGPROXY_ROTATE '%s' (path|secret|all)"
MSG["tgp.bad_version"]="неверный TGPROXY_TELEMT_VERSION '%s'"
MSG["tgp.choose_outway"]="выберите исходящий интерфейс: TGPROXY_OUTWAY=<интерфейс> (или auto: интерфейс маршрута по умолчанию)"
MSG["tgp.client_info"]="нужен Telegram Desktop 7.1+ (тип прокси WEB); другие клиенты эту ссылку использовать не смогут"
MSG["tgp.dir_spaces"]="каталог скриптов с пробелами не поддерживается: '%s'"
MSG["tgp.invalid_outway"]="недопустимый outway '%s'"
MSG["tgp.link_hint"]="Ссылка (откройте её в Telegram Desktop 7.1 или новее):"
MSG["tgp.manage_info"]="Управление без репозитория: %s/tgproxy-config.sh (link, status, outway, rotate) и tgproxy-remove.sh"
MSG["tgp.menu_head"]="Telegram web proxy уже установлен (outway: %s)."
MSG["tgp.menu_items"]="$(cat <<'EOF_MSG'
  1) обновить (скачать образ, пересобрать конфигурацию, перезапустить; можно сменить секреты)
  2) удалить
  3) показать ссылку
  4) сменить outway (исходящий интерфейс)
  5) сменить секретный путь и секрет
  6) состояние
  0) отмена
EOF_MSG
)"
MSG["tgp.menu_prompt"]="Выберите: "
MSG["tgp.need_tool"]="нужна утилита '%s' (apt install iproute2 openssl python3 coreutils libc-bin)"
MSG["tgp.no_collect"]="telegram-web-proxy: фаза сбора не выполнялась"
MSG["tgp.no_domain"]="DOMAIN неизвестен (файла %s ещё нет); выполните: sudo ./install.sh install"
MSG["tgp.no_ip_for_domain"]="не удалось определить IPv4-адрес для %s; задайте TGPROXY_PUBLIC_IP"
MSG["tgp.no_iproute"]="iproute2 ещё не установлен: интерфейс будет проверен после установки необходимых пакетов"
MSG["tgp.no_project_net"]="сеть проекта не существует: сначала запустите стек (./install.sh start)"
MSG["tgp.no_project_subnet"]="не удалось определить IPv4-подсеть сети проекта"
MSG["tgp.no_subnet"]="не удалось подобрать подсеть для сети telemt"
MSG["tgp.not_installed"]="Telegram web proxy не установлен (TGPROXY_ACTION=%s); используйте TGPROXY_ACTION=install"
MSG["tgp.nothing_done"]="ничего не сделано"
MSG["tgp.outway_done"]="outway: %s"
MSG["tgp.outway_info"]="Исходящий интерфейс (outway): %s; состояние: %s/tgproxy-outway.sh status"
MSG["tgp.outway_intro"]="Через исходящий интерфейс идёт только трафик контейнера telemt к Telegram:"
MSG["tgp.outway_problem"]="outway '%s': %s"
MSG["tgp.path_spaces"]="путь к проекту не должен содержать пробелов: '%s'"
MSG["tgp.port_warn"]="NGINX_HTTPS_PORT равен %s: Telegram Desktop принимает веб-прокси только на порту 443"
MSG["tgp.q_outway"]="Исходящий интерфейс%s: "
MSG["tgp.q_purge"]="Удалить также конфигурацию и секреты (data/telegram-web-proxy)? Иначе после переустановки ссылка будет прежней."
MSG["tgp.q_remove"]="Удалить Telegram web proxy (остальной стек продолжит работать)?"
MSG["tgp.q_rotate"]="Что сменить: path (путь), secret (секрет) или all (всё) [all]: "
MSG["tgp.q_rotate_all"]="Сменить также секретный путь и секрет пользователя (старая ссылка перестанет работать)?"
MSG["tgp.ready"]="Telegram web proxy готов"
MSG["tgp.scripts_ok"]="самостоятельные скрипты установлены в %s (tgproxy-config.sh, tgproxy-outway.sh, tgproxy-remove.sh)"
MSG["tgp.secret_warn"]="секретный путь входит в учётные данные: не публикуйте ссылку; после смены пути или секрета старые ссылки перестают работать"
MSG["tgp.set_rotate"]="задайте TGPROXY_ROTATE=path|secret|all"
MSG["tgp.unhealthy"]="telemt не перешёл в рабочее состояние (см. журнал выше); устраните причину и запустите снова или удалите расширение"
MSG["tgp.unknown_action"]="неизвестное значение TGPROXY_ACTION '%s' (install|update|remove|link|outway|rotate|status)"
