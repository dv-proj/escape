# Расширения установки

Каждое расширение — один файл `extensions.d/<NN>-<id>.sh`. Файлы только добавляются, общий скрипт `fakeapp.sh` для этого не правится, поэтому ветки с разными расширениями не конфликтуют при merge.

Файл вызывает `register_extension ID "Название в меню" ФУНКЦИЯ`; функция выполняет установку (скрипт уже запущен от root, доступны `info`, `ok`, `warn`, `die`, `$APP_DIR`, `env_get`/`env_set` и функции `ext_*` из раздела ниже). Имена функций начинайте с `ext_<id>_`.

```bash
# extensions.d/50-example.sh
register_extension example "Пример дополнительного функционала" ext_example_install

ext_example_install() {
    info "делаю что-то полезное"
}
```

Порядок пунктов меню — по имени файла (`NN` задаёт порядок). Файлы `*.sample` не загружаются.

## Контракт расширения

База (`docker-compose.yml`) не содержит ничего про конкретные расширения. Расширение подключает себя само, через функции-помощники из `fakeapp.sh` (они доступны в файле расширения и в его функциях):

| Функция | Что делает |
|---|---|
| `ext_register_compose <id> <файл-compose>` | добавляет compose-файл расширения в стек: пересоздаёт `data/extensions.compose.yml` (список `include:` с абсолютными путями; без расширений там `services: {}`). Файл должен существовать; повторный вызов с тем же `id` заменяет запись |
| `ext_unregister_compose <id>` | убирает запись `id` из `data/extensions.compose.yml`. Контейнеры сначала остановите сами (`ext_compose rm -sf <сервис>`) |
| `ext_nginx_location_put <id>` | читает со stdin блок `location` и пишет его в `data/nginx/locations.d/<id>.conf`; если nginx запущен, проверяет конфиг (`nginx -t`) и перечитывает его (`nginx -s reload`). Если проверка не прошла, файл откатывается и скрипт завершается с ошибкой |
| `ext_nginx_location_rm <id>` | удаляет `data/nginx/locations.d/<id>.conf` и перечитывает конфиг |
| `ext_domain` | печатает `DOMAIN` из `.env` |
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
