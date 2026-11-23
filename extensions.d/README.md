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

## Фазы установки и хуки

Установка идёт тремя фазами (см. «Установка» в [README.md](../README.md)), и расширение участвует в каждой из них:

| Фаза | Функция расширения | Что можно делать |
|---|---|---|
| 1. Сбор | `ext_<id>_collect` (необязательно) | задавать **все** вопросы расширения (`read`, меню), читать переменные окружения и флаги; ответы сохранять в глобальных переменных. Ничего не устанавливать и не менять на диске и в системе |
| 2. Проверка | `ext_<id>_validate` (необязательно) | проверять ответы и состояние хоста только на чтение; о каждой фатальной проблеме сообщать `problem "текст"` (сообщения выводятся списком все сразу, установка прекращается до развёртывания), о нестрашном: `warn`. Хук не должен вызывать `die` |
| 3. Развёртывание | функция из `register_extension` | всё остальное: устанавливать, писать файлы, запускать контейнеры. Вопросов не задавать |

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
| `ext_domain` | печатает `DOMAIN` из `.env` |
| `env_value <КЛЮЧ>` | значение из `.env`, а до его создания (фазы 1–2 новой установки) из собранных ответов |
| `problem <текст>` | записывает фатальную проблему (фазы 1–2); все проблемы выводятся вместе, установка прекращается до развёртывания |
| `t <КЛЮЧ> [аргументы]` | текст сообщения на языке пользователя (формат `printf`, `%s`), см. раздел «Языки» ниже |
| `ext_load_lang <id>` | загружает `extensions.d/<id>/lang/en.sh` и файл выбранного языка; вызывайте в начале каждого хука и функции развёртывания |
| `ext_compose <аргументы>` | `docker compose` проекта (все подключённые файлы, `.env` проекта): `ext_compose up -d --build --wait <сервис>` |

`<id>` — как у `register_extension`: `[a-z0-9][a-z0-9_-]*`. Файл `data/nginx/locations.d/<id>.conf` подключается в `server` на 443 **до** `location /` (`include /etc/nginx/locations.d/*.conf;`), поэтому достаточно блока `location`. Из контейнера nginx сервисы стека доступны по имени сервиса в сети compose (`proxy_pass http://myservice:1234;`). Заголовки `X-Real-IP`, `X-Forwarded-For` и `X-Forwarded-Proto` расширение задаёт само, если они нужны.

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

Каталог `data/` не попадает в git (`.gitignore`), общие файлы стека расширения не правят.

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
- Самостоятельные скрипты расширения (как `tgproxy-*.sh`) остаются на английском: они работают без `install.sh` и `lib/`.
