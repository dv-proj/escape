# escape: сайт-обманка fake-webapp рядом с Xray / 3X-UI

Инструмент разворачивает на сервере с уже установленными Xray или 3X-UI один Docker-контейнер `fakeapp`. Это правдоподобная страница входа в веб-сервис (Go, исходники в `fake-webapp/`). Её видят обычные посетители и активные зонды, которые заходят на ваш домен без ключа VPN.

Контейнер слушает только `127.0.0.1:<порт>` по обычному HTTP. TLS, сертификаты и маршрутизацию по-прежнему делают ваш nginx и Xray: fake-webapp просто ставится в nginx как upstream «для всего остального» (см. раздел [«Подключение к nginx»](#подключение-к-nginx)). Скрипт **не трогает** nginx, Xray, 3X-UI, сертификаты и файрвол.

## Состав

| Файл | Назначение |
|---|---|
| `fakeapp.sh` | установка и управление |
| `fake-webapp/` | исходники приложения, `Dockerfile`, описание (`fake-webapp/README.md`) |
| `fake-webapp/gen/` | генераторы `login.py` и `favicon.py` (Python 3, только stdlib); запускаются на хосте, в образ не входят |
| `fake-webapp/docker-compose.yml` | сервис `fakeapp` |
| `docker-compose.yml` | основной файл (проект `fakeapp`): `include` для `fake-webapp/docker-compose.yml` |
| `.env.example` | шаблон настроек; при установке копируется в `.env` |

## Требования

- Ubuntu 22.04+ или Debian 12+, права root (`sudo`).
- Docker с плагином compose v2.20+. Если Docker уже стоит (например, на нём работает 3X-UI), используется он, его настройки не меняются. Если Docker нет, ставится Docker CE из `download.docker.com`. Если нет только плагина compose, ставится плагин.
- `python3`, `curl`, `iproute2` (ставятся автоматически, если их нет).
- nginx, через который сайт будет доступен снаружи: обычно он уже стоит рядом с Xray или 3X-UI.

## Установка

```bash
git clone <url-репозитория> /opt/fakeapp
```

```bash
cd /opt/fakeapp && sudo ./fakeapp.sh install
```

Скрипт задаёт только эти вопросы:

| Вопрос | Ключ `.env` | По умолчанию |
|---|---|---|
| Название сайта | `APP_NAME` | случайное правдоподобное |
| Описание сайта | `APP_DESCRIPTION` | случайное, в тон названию |
| Ключевые слова | `APP_KEYWORDS` | случайные, в тон названию |
| DNS-имя сайта без протокола (необязательно) | `DOMAIN` | пусто |
| Локальный порт приложения | `FAKEAPP_PORT` | первый свободный порт начиная с 8080 |
| Часовой пояс | `TZ` | часовой пояс хоста |

- **`DOMAIN`** нужен только для тегов `canonical` и `og:url` (`https://<DOMAIN>`). Сертификат для него скрипт не запрашивает.
- **`FAKEAPP_PORT`** не должен совпадать с портами Xray, панели 3X-UI и nginx. Скрипт проверяет, что порт свободен.

Остальные параметры генерируются случайно: `PAGE_SEED` (вариант оформления), `RANDOM_DATA_SUFFIX`, лимиты запросов и задержки входа. Без терминала вопросы не задаются: берутся значения по умолчанию или переменные окружения с теми же именами, например `APP_NAME=... DOMAIN=... sudo -E ./fakeapp.sh install`.

Повторный `install` пересобирает и перезапускает контейнер. Значения в `.env` он не меняет, только дописывает новые ключи из `.env.example`. Существующие `login.html` и `favicon.ico` тоже не трогает.

После установки скрипт печатает адрес upstream, например `http://127.0.0.1:8080`. Дальше подключите его к nginx.

## Команды

| Команда | Действие |
|---|---|
| `sudo ./fakeapp.sh install` | установка или обновление (см. выше) |
| `./fakeapp.sh start` / `stop` / `restart` | запуск, остановка, перезапуск контейнера |
| `./fakeapp.sh status` | состояние контейнера и проверка `http://127.0.0.1:<порт>/` |
| `./fakeapp.sh logs` | журнал контейнера |
| `./fakeapp.sh snippet` | готовый блок `location /` для nginx с вашим портом |
| `sudo ./fakeapp.sh remove [--purge] [-y]` | удалить контейнер и образ; с `--purge` также каталог данных. `.env`, проект и Docker остаются |

Для `start`, `stop`, `restart`, `status` и `logs` нужен доступ к Docker: root, `sudo` или группа `docker`.

## Подключение к nginx

### Принцип

1. Xray, панель 3X-UI и подписки остаются на своих секретных путях (или на fallback, см. варианты ниже).
2. Всё остальное, начиная с корня `/`, nginx проксирует в fake-webapp.
3. nginx **обязательно** перезаписывает `X-Real-IP` реальным адресом клиента. По нему приложение считает лимит запросов, а заголовку от клиента приложение верит. Поэтому порт приложения не должен быть доступен снаружи (`FAKEAPP_BIND=127.0.0.1`, по умолчанию).

Сначала сохраните блок `location /` в отдельный файл:

```bash
sudo ./fakeapp.sh snippet | sudo tee /etc/nginx/snippets/fake-webapp.conf
```

Получится примерно такое (порт берётся из `.env`):

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_connect_timeout 5s;
    proxy_read_timeout 60s;
}
```

Потом подключите его строкой `include snippets/fake-webapp.conf;` в нужный `server { }`. Выберите вариант по тому, кто у вас принимает порт 443.

> В `server { }` может уже быть свой `location /`, например `root /var/www/html` из стандартного конфига. Удалите его: два `location /` в одном сервере nginx не примет. Префиксные `location` с более длинными путями (пути Xray и панели) имеют приоритет над `/`, порядок строк не важен. Исключение: regex-локации (`location ~ ...`) проверяются раньше префиксных.

### Вариант A: TLS на 443 принимает nginx (Xray за ним на WebSocket или gRPC)

Inbound'ы Xray слушают `127.0.0.1` без TLS, nginx раздаёт их по секретным путям. Всё остальное получает fake-webapp.

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name example.com;

    # Продление сертификата certbot (webroot); если используете другой способ, уберите.
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$host$request_uri; }
}

server {
    # nginx >= 1.25.1: "listen 443 ssl;" и отдельной строкой "http2 on;"
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    # Xray: VLESS/VMess/Trojan + WebSocket, inbound на 127.0.0.1:10000, path /ws-a1b2c3
    location /ws-a1b2c3 {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 1h;
    }

    # Xray: gRPC, inbound на 127.0.0.1:10001, serviceName grpc-d4e5f6
    location /grpc-d4e5f6/ {
        grpc_pass grpc://127.0.0.1:10001;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
    }

    # Панель 3X-UI: в настройках панели IP 127.0.0.1, порт 2053, URI path /panel-x7y8z9/
    location /panel-x7y8z9/ {
        proxy_pass http://127.0.0.1:2053;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Всё остальное: сайт-обманка
    include snippets/fake-webapp.conf;
}
```

Если в вашем конфиге уже есть `location` для Xray, панели или подписок, оставьте их как есть и замените только `location /`.

### Вариант B: на 443 Xray VLESS + TCP + TLS с fallback'ами

Xray сам принимает TLS. Соединения без ключа VLESS он отправляет на fallback. Пусть fallback ведёт в nginx на `127.0.0.1` с PROXY protocol: так nginx узнает реальный IP клиента.

В 3X-UI: inbound VLESS → транспорт TCP (RAW) → Security TLS. В TLS укажите ALPN `h2,http/1.1`. В разделе Fallbacks добавьте две записи:

| SNI | ALPN | Path | Dest | xVer |
|---|---|---|---|---|
| | | | `8001` | `1` |
| | `h2` | | `8002` | `1` |

В JSON Xray это выглядит так:

```json
"fallbacks": [
  { "dest": 8001, "xver": 1 },
  { "alpn": "h2", "dest": 8002, "xver": 1 }
]
```

nginx (например, `/etc/nginx/conf.d/fake-webapp.conf`):

```nginx
server {
    listen 127.0.0.1:8001 proxy_protocol;
    # nginx >= 1.25.1: вынесите 8002 в отдельный server с "http2 on;"
    listen 127.0.0.1:8002 http2 proxy_protocol;
    server_name _;

    # Адрес клиента берётся из PROXY protocol, который присылает Xray.
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    include snippets/fake-webapp.conf;
}
```

### Вариант C: на 443 Xray VLESS + REALITY, «маскировка под себя»

REALITY пересылает чужие соединения на target. Вместо чужого сайта target может быть ваш nginx на `127.0.0.1` с настоящим сертификатом вашего домена. Тогда зонд, пришедший на 443 с вашим SNI, увидит fake-webapp с валидным сертификатом.

В 3X-UI: inbound VLESS → TCP (RAW) → Security Reality:

- **Target (Dest):** `127.0.0.1:8443`;
- **Xver:** `1`;
- **SNI (serverNames):** `example.com` (ваш домен; его A-запись должна указывать на этот сервер).

Сертификат для `example.com` получите заранее, например `certbot certonly --webroot` через сервер на порту 80 из варианта A.

```nginx
server {
    # REALITY требует от target TLS 1.3 и h2.
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;   # nginx >= 1.25.1: без http2 здесь + "http2 on;"
    server_name example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    ssl_protocols TLSv1.3;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    include snippets/fake-webapp.conf;
}
```

Если nginx уже делит порт 443 по SNI через `stream { ... ssl_preread ... }`, направьте имя сайта-обманки на `server` из варианта A (или C), а в нём замените `location /` на `include snippets/fake-webapp.conf;`. Если stream передаёт соединения с `proxy_protocol on`, добавьте `set_real_ip_from` и `real_ip_header` как в вариантах B и C.

### Применение и проверка

```bash
sudo nginx -t && sudo systemctl reload nginx
```

```bash
curl -sI https://example.com/ | head -n1
```

Ожидается `HTTP/2 200` (или `HTTP/1.1 200`). Любой несуществующий путь отвечает редиректом 302 на `/`. Пути Xray и панели должны работать как раньше. Если клиенты VPN перестали подключаться, проверьте, что их `location` или fallback не перекрыты.

Ваш реальный IP должен появиться в журнале контейнера (`./fakeapp.sh logs`). Если там у всех адрес `127.0.0.1`, значит nginx не передаёт `X-Real-IP` или (в вариантах B и C) не настроен `real_ip_header proxy_protocol`.

### nginx в Docker-контейнере

Для nginx внутри контейнера `127.0.0.1` означает сам контейнер. Возможны два решения:

- запустить nginx с `network_mode: host`;
- опубликовать приложение на адресе моста Docker: в `.env` задать `FAKEAPP_BIND=172.17.0.1` (адрес `docker0`), выполнить `sudo ./fakeapp.sh install` и проксировать на `http://172.17.0.1:<порт>`. Порт не должен быть открыт в интернет: проверьте файрвол.

## Каталог данных

`./data/fakeapp` (или `FAKEAPP_DATA_DIR`) монтируется в контейнер **только для чтения**: приложение ничего не пишет.

| Файл | Откуда | Когда приложение видит изменения |
|---|---|---|
| `login.html` | `gen/login.py` (шаблон Go `html/template`). Обязателен: без него или с битым шаблоном приложение не стартует | после `./fakeapp.sh restart` |
| `favicon.ico` | `gen/favicon.py` (первая буква `APP_NAME`, оформление из `PAGE_SEED`) | сразу |
| любые другие файлы и подкаталоги | кладёте сами; отдаются по пути `/<путь>` | сразу |

Не отдаются:

- скрытые файлы и каталоги (`.*`);
- сам `/login.html`;
- каталоги (листинга нет).

Отсутствующий путь даёт редирект на `/`.

Права: контейнер работает от непривилегированного uid, поэтому нужны права `r` на файлах и `r-x` на каталогах (обычные 644 и 755). `install` выставляет их сам (`chmod -R a+rX`).

Новый вариант оформления:

1. Смените `PAGE_SEED` в `.env`.
2. Удалите `login.html` и `favicon.ico`.
3. Снова выполните `sudo ./fakeapp.sh install`.

## Удаление

```bash
sudo ./fakeapp.sh remove --purge
```

Удаляет контейнер, образ и каталог данных. Docker, `.env` и каталог проекта остаются. Удалите `include snippets/fake-webapp.conf;` (и fallback или target в Xray, если меняли) и перезагрузите nginx.
