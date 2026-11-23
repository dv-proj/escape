# Расширения установки

Каждое расширение — один файл `extensions.d/<NN>-<id>.sh`. Файлы только добавляются, общий скрипт `install.sh` для этого не правится, поэтому ветки с разными расширениями не конфликтуют при merge.

Файл вызывает `register_extension ID "Название в меню" ФУНКЦИЯ`; функция выполняет установку в фазе развёртывания (скрипт уже запущен от root, доступны `info`, `ok`, `warn`, `die`, `$APP_DIR`, `env_get`/`env_set` и функции `ext_*` из раздела ниже). Имена функций начинайте с `ext_<id>_`.

```bash
# extensions.d/50-example.sh
register_extension example "Пример дополнительного функционала" ext_example_install

ext_example_install() {
    info "делаю что-то полезное"
}
```

Порядок пунктов меню — по имени файла (`NN` задаёт порядок). Файлы `*.sample` не загружаются.

## Каталоги: SRC_DIR, CODE_DIR, APP_DIR

Проект не работает из git-клона: `install.sh` копирует белый список файлов (`lib/`, `nginx/`, `fake-webapp/` без тестов, `extensions.d/` целиком, `docker-compose.yml`, `.env.example`, README) из **исходников** (`SRC_DIR`: клон или распакованная загрузка) в **каталог установки** (`APP_DIR`, по умолчанию `/opt/escape`) и продолжает работу из установленной копии. Файлы расширения (`extensions.d/<NN>-<id>.sh`, `extensions.d/<id>/…`) копируются вместе со всем остальным; чего нет в исходниках, при обновлении из каталога установки удаляется.

- `APP_DIR` — каталог установки; расширения загружаются только из установленной копии, поэтому в хуках и функции развёртывания `$APP_DIR` — это он, а `$CODE_DIR` (каталог запущенного `install.sh`, оттуда читаются модули, `lang/` и файлы расширения) равен `$APP_DIR`. Ссылайтесь на свой код как `$CODE_DIR/extensions.d/<id>/…`, на данные как `$DATA_DIR/<id>/` (то есть `$APP_DIR/data/<id>/`): весь рабочий state расширения — внутри `data/`, а не рядом с кодом и не в других местах хоста.
- Пути всегда строятся от `APP_DIR`, жёстких путей вроде `/opt/...` в коде и сообщениях быть не должно. Самостоятельные скрипты (как `tgproxy-*.sh`) копируйте в `scripts/` каталога установки (`$APP_DIR/scripts`, с возможностью переопределить переменной окружения расширения) и «запекайте» в них путь к своему state.
- Всё, что расширение вынуждено создать вне `APP_DIR` (юниты systemd, sysctl, правила файрвола), перечислите в README и удалите в хуке `ext_<id>_purge` (необязательный; вызывается из `install.sh remove --purge` до остановки стека, должен быть идемпотентным; ошибка хука — предупреждение, а не отмена).
- Именованных томов Docker не используйте: данные кладите в bind-монтирования под `data/`, чтобы `remove --purge` удалял всё, что создано установкой.

## Фазы установки и хуки

Установка идёт тремя фазами (см. «Установка» в [README.md](../README.md)), и расширение участвует в каждой из них:

| Фаза | Функция расширения | Что можно делать |
|---|---|---|
| 1. Сбор | `ext_<id>_collect` (необязательно) | задавать **все** вопросы расширения (`read`, меню), читать переменные окружения и флаги; ответы сохранять в глобальных переменных. Ничего не устанавливать и не менять на диске и в системе |
| 2. Проверка | `ext_<id>_validate` (необязательно) | проверять ответы и состояние хоста только на чтение; о каждой фатальной проблеме сообщать `problem "текст"` (сообщения выводятся списком все сразу, установка прекращается до развёртывания), о нестрашном: `warn`. Хук не должен вызывать `die` |
| 3. Развёртывание | функция из `register_extension` | всё остальное: устанавливать, писать файлы, запускать контейнеры. Вопросов не задавать |
| Удаление | `ext_<id>_purge` (необязательно) | при `remove --purge`: убрать всё, что расширение создало вне `APP_DIR` (юниты, sysctl, правила), пока стек ещё работает |

В имени хука `-` из `<id>` заменяется на `_` (`telegram-web-proxy` даёт `ext_telegram_web_proxy_collect`). Расширение без хуков работает как раньше: хуки необязательны. Хуки вызываются в основном процессе скрипта, поэтому ответы фазы 1 видны в функциях фаз 2 и 3. В фазе проверки Docker, `.env` и пакеты установки могут ещё отсутствовать (новая установка): значения настроек берите через `env_value КЛЮЧ` (из `.env`, а если его ещё нет, из собранных ответов), а проверки, которым нужен Docker, делайте в функции развёртывания. Внутри хука проверки `set -e` не действует (он вызывается как `хук || …`), поэтому проверяйте коды возврата сами.

```bash
# extensions.d/50-example.sh
register_extension example "Пример" ext_example_install

ext_example_collect() {
    EXAMPLE_PORT="${EXAMPLE_PORT:-}"
    if [[ -z "$EXAMPLE_PORT" && -t 0 ]]; then
        read -r -p "Порт примера [3000]: " EXAMPLE_PORT || die "$(t common.no_input)"
    fi
    EXAMPLE_PORT="${EXAMPLE_PORT:-3000}"
}

ext_example_validate() {
    [[ "$EXAMPLE_PORT" =~ ^[0-9]+$ ]] || problem "EXAMPLE_PORT must be a number (got '$EXAMPLE_PORT')"
    ! port_in_use "$EXAMPLE_PORT" || problem "port $EXAMPLE_PORT is busy"
}

ext_example_install() {
    info "deploying on port $EXAMPLE_PORT"   # без вопросов
}
```

## Контракт расширения

База (`docker-compose.yml`) не содержит ничего про конкретные расширения. Расширение подключает себя само, через функции-помощники из `install.sh` (они доступны в файле расширения и в его функциях):

| Функция | Что делает |
|---|---|
| `ext_register_compose <id> <файл-compose>` | добавляет compose-файл расширения в стек: пересоздаёт `data/extensions.compose.yml` (список `include:` с абсолютными путями; без расширений там `services: {}`). Файл должен существовать; повторный вызов с тем же `id` заменяет запись |
| `ext_unregister_compose <id>` | убирает запись `id` из `data/extensions.compose.yml`. Контейнеры сначала остановите сами (`ext_compose rm -sf <сервис>`) |
| `ext_nginx_location_put <id>` | читает со stdin блок `location` и пишет его в `data/nginx/locations.d/<id>.conf`; если nginx запущен, проверяет конфиг (`nginx -t`) и перечитывает его (`nginx -s reload`). Если проверка не прошла, файл откатывается и скрипт завершается с ошибкой |
| `ext_nginx_location_rm <id>` | удаляет `data/nginx/locations.d/<id>.conf` и перечитывает конфиг |
| `ext_nginx_server_put <id> [<имя>]` | для расширения со своим DNS-именем: читает со stdin блоки `server` целиком (уровень http, свои `listen 80`/`listen 443 ssl` и `server_name`) и пишет их в `data/nginx/servers.d/<id>.conf.in`, из которого собирается `<id>.conf` (его и подключает nginx: `include /etc/nginx/servers.d/*.conf;`). С `<имя>` подстановки `@SSL_CERT@` и `@SSL_KEY@` заменяются путями сертификата этого имени: Let's Encrypt, если он уже выпущен, иначе временный самоподписанный (`data/nginx/selfsigned/<имя>/`); сборка повторяется при `renew`, `start`, `restart`, поэтому после выпуска сертификата nginx переходит на него сам. Затем `nginx -t` и перечитывание; при ошибке оба файла откатываются и скрипт завершается с ошибкой. Если работающий nginx ещё без каталога `servers.d` (установка старой версии), конфиг собирается заново и контейнер nginx однократно пересоздаётся |
| `ext_nginx_server_rm <id>` | удаляет `data/nginx/servers.d/<id>.conf` и `.conf.in` и перечитывает конфиг |
| `ext_nginx_stream_put <id>` | маршруты TLS-фронта (блок `stream` на порту HTTPS хоста): читает со stdin строки `ИМЯ ХОСТ:ПОРТ` (`;` в конце и комментарии `#` допустимы; имя точное или `*.example.org` / `.example.org`) и пишет их в `data/nginx/stream.d/<id>.map`. Соединения с таким SNI фронт передаёт, не расшифровывая, на `ХОСТ:ПОРТ` (обычно сервис compose; имя разрешается при каждом соединении через DNS Docker, поэтому nginx запускается и перечитывается, даже когда сервис остановлен) с заголовком PROXY protocol v1, остальные имена идут в HTTPS-сервер. Нельзя заявить `DOMAIN`, имена из `extra-certs.list` и `server_name` блоков `servers.d`, кроме тех, что принадлежат самому расширению <id> (имя со своим сертификатом и server-блоком, которое расширение направляет в свой inbound); одинаковые имена двух расширений nginx отвергает. Затем `nginx -t` и перечитывание (контейнер nginx без фронта однократно пересоздаётся); при ошибке файл откатывается и скрипт завершается с ошибкой |
| `ext_nginx_stream_rm <id>` | удаляет `data/nginx/stream.d/<id>.map` и перечитывает конфиг |
| `ext_cert_request <id> <имя>` | регистрирует сертификат `<имя>` за расширением (одно имя на `id`, повторный вызов заменяет; список в `data/nginx/extra-certs.list`) и получает его у Let's Encrypt тем же certbot webroot, что и сертификат `DOMAIN` (порт 80 отвечает на проверку для любого имени); затем собирает `servers.d` заново и перечитывает nginx. Имя, равное `DOMAIN`, ничего не требует. Код возврата 1, если выпустить не удалось (с подсказками); имя остаётся зарегистрированным, и `renew` (таймер) повторяет попытку. Зарегистрированные имена продлеваются вместе с `DOMAIN` |
| `ext_cert_release <id> [--delete]` | снимает регистрацию (продление прекращается); файлы сертификата остаются, с `--delete` удаляются (сертификат `DOMAIN` и имя, зарегистрированное другим расширением, не удаляются никогда) |
| `ext_cert_paths <имя>` | печатает `ПУТЬ_СЕРТИФИКАТА ПУТЬ_КЛЮЧА` внутри контейнера nginx для `<имя>` (Let's Encrypt или самоподписанный) |
| `check_domain_dns <имя>` | проверка DNS, как для `DOMAIN` (только предупреждения); для фазы проверки |
| `ext_domain` | печатает `DOMAIN` из `.env` |
| `env_value <КЛЮЧ>` | значение из `.env`, а до его создания (фазы 1–2 новой установки) из собранных ответов |
| `problem <текст>` | записывает фатальную проблему (фазы 1–2); все проблемы выводятся вместе, установка прекращается до развёртывания |
| `t <КЛЮЧ> [аргументы]` | текст сообщения на языке пользователя (формат `printf`, `%s`), см. раздел «Языки» ниже |
| `ext_load_lang <id>` | загружает `extensions.d/<id>/lang/en.sh` и файл выбранного языка; вызывайте в начале каждого хука и функции развёртывания |
| `ext_compose <аргументы>` | `docker compose` проекта (все подключённые файлы, `.env` проекта): `ext_compose up -d --build --wait <сервис>` |

`<id>` — как у `register_extension`: `[a-z0-9][a-z0-9_-]*`. Файл `data/nginx/locations.d/<id>.conf` подключается в `server` на 443 **до** `location /` (`include /etc/nginx/locations.d/*.conf;`), поэтому достаточно блока `location`. Из контейнера nginx сервисы стека доступны по имени сервиса в сети compose (`proxy_pass http://myservice:1234;`). Заголовки `X-Real-IP`, `X-Forwarded-For` и `X-Forwarded-Proto` расширение задаёт само, если они нужны.

HTTPS-сервер слушает порт 443 **внутри контейнера** с `proxy_protocol`: снаружи (порт `NGINX_HTTPS_PORT` хоста) соединения принимает TLS-фронт и передаёт их с заголовком PROXY, а `real_ip_header proxy_protocol` делает `$remote_addr` настоящим адресом клиента. Блоки `server` в `servers.d` пишут, как и раньше, `listen 443 ssl;` (опция `proxy_protocol` у сокета общая). Файлы `servers.d/*.conf` подключаются на уровне `http`, поэтому там же можно объявить и директивы уровня http расширения (`limit_req_zone`, `map`, `set_real_ip_from` для своего отправителя PROXY protocol), как это делает `xray-3xui`.

```bash
# extensions.d/50-example.sh
register_extension example "Пример" ext_example_install

ext_example_install() {
    ext_register_compose example "$APP_DIR/extensions.d/example/docker-compose.yml"
    ext_compose up -d --build --wait example
    ext_nginx_location_put example <<EOF_LOC
location /example/ {
    proxy_pass http://example:3000/;
    proxy_set_header Host \$host;
}
EOF_LOC
    info "https://$(ext_domain)/example/"
}
```

Расширение со своим DNS-именем (например, `p.example.org` рядом с сайтом на `app.example.org`) кладёт не `location`, а свои блоки `server`:

```bash
ext_nginx_server_put example example.org <<'EOF_SRV'
server {
    listen 80;
    server_name example.org;
    location ^~ /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 https://example.org$request_uri; }
}
server {
    listen 443 ssl;
    http2 on;
    server_name example.org;
    ssl_certificate     @SSL_CERT@;
    ssl_certificate_key @SSL_KEY@;
    location / { proxy_pass http://example:3000; }
}
EOF_SRV
ext_cert_request example example.org || warn "сертификат будет выпущен при renew"
```

Каталог `data/` есть только в каталоге установки (и не попадает в git: `.gitignore`), общие файлы стека расширения не правят.

## Языки

Все тексты для пользователя (вопросы, подсказки, проблемы, предупреждения, ошибки, итоговая сводка) выводятся через `t КЛЮЧ [аргументы]` из `lib/i18n.sh`. Язык выбирает пользователь (`--lang en|ru`, переменная `FAKEAPP_LANG`, ключ `FAKEAPP_LANG` в `.env` или вопрос в начале `install`); без выбора используется английский. Имена команд, флагов, переменных окружения и путей не переводятся, как и вывод Docker, apt и certbot.

Тексты лежат в файлах `lib/lang/en.sh` и `lib/lang/ru.sh` (ядро) и, если расширению нужны свои, в `extensions.d/<id>/lang/en.sh` и `extensions.d/<id>/lang/ru.sh`. Формат файла: одна строка на сообщение, формат `printf` (`%s`, `%d`; настоящий знак процента пишется `%%`), без обратных косых черт:

```bash
# extensions.d/example/lang/en.sh
MSG["example.q_port"]="Example port"
MSG["example.busy"]="port %s is busy"
MSG["example.title"]="Example extra feature"   # необязательно: название в меню
```

Правила:

- Ключи расширения начинайте с `<id>.` (или с короткого своего префикса): все файлы грузятся в один массив `MSG`. Ключ `<id>.title`, если он есть, заменяет название из `register_extension` в меню и в списке `./install.sh extensions`.
- Английский файл загружается всегда, файл выбранного языка поверх него: пропущенное в `ru.sh` сообщение выводится по-английски, неизвестный ключ выводится как есть.
- Вызовите `ext_load_lang <id>` в начале `ext_<id>_collect`, `ext_<id>_validate` и функции развёртывания, затем пишите `info "$(t example.busy "$port")"`, `problem "$(t example.busy "$port")"`, `die "$(t example.busy "$port")"`.
- Набор ключей в `en.sh` и `ru.sh` должен совпадать, число `%s`/`%d` в обоих языках тоже. Проверка (в том числе того, что каждый `t КЛЮЧ` из кода есть в английском файле): `tests/check-i18n.sh`.
- Самостоятельные скрипты расширения (как `tgproxy-*.sh`, `xray-*.sh`) остаются на английском: они работают без `install.sh` и `lib/`.

## Общий скрипт outway

`extensions.d/telegram-web-proxy/tgproxy-outway.sh` (маршрутизация собственной сети контейнера через выбранный интерфейс, fail-closed) может использовать любое расширение: все имена, которые он создаёт, берутся из `state.env` расширения (`ROUTE_TABLE`, `RULE_PRIO`, `OUTWAY_CHAIN`, `OUTWAY_NFT_TABLE`, `OUTWAY_UNIT`, `OUTWAY_SYSCTL_NAME`, `OUTWAY_COMMENT`, `OUTWAY_LABEL`, `OUTWAY_TITLE`; без них — имена `telegram-web-proxy`) (контейнер не должен публиковать порты на хосте: входящее идёт через TLS-фронт по общей сети compose). `xray-3xui` копирует его в `scripts/xray-outway.sh`, заменяя переменные окружения `TGPROXY_*` на `XRAY_*` и вписывая путь к своему `state.env`. Номера таблиц: `7791` (telegram-web-proxy), `7792` (xray-3xui); новому расширению берите следующий.
