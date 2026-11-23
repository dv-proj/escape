# escape: сайт-обманка fake-webapp за nginx в Docker

Инструмент разворачивает на сервере Docker-стек: контейнер `nginx` принимает HTTPS на 443 и отдаёт сайт-обманку `fakeapp`. Это правдоподобная страница входа в веб-сервис (Go, исходники в `fake-webapp/`). Её видят обычные посетители и активные зонды, которые заходят на ваш домен без ключа VPN.

nginx публикует порты 80 и 443 хоста, получает сертификат Let's Encrypt для вашего домена (certbot, метод webroot) и сам продлевает его. `fakeapp` наружу не публикуется: он доступен только внутри сети compose как `http://fakeapp:<порт>`. Дополнительные сервисы (расширения) подключаются к этому стеку отдельными файлами и добавляют свои `location` в nginx (см. [«Расширения»](#расширения)). Скрипт **не трогает** Xray, 3X-UI и файрвол.

## Состав

| Файл | Назначение |
|---|---|
| `fakeapp.sh` | установка и управление |
| `extensions.d/` | расширения установки (по файлу на расширение); `extensions.d/telegram-web-proxy/`: скрипты расширения Telegram web proxy |
| `nginx/` | `docker-compose.yml` (сервисы `nginx` и одноразовый `certbot`) и шаблон конфигурации `default.conf.template` |
| `fake-webapp/` | исходники приложения, `Dockerfile`, описание (`fake-webapp/README.md`) |
| `fake-webapp/gen/` | генераторы `login.py` и `favicon.py` (Python 3, только stdlib); запускаются на хосте, в образ не входят |
| `fake-webapp/docker-compose.yml` | сервис `fakeapp` |
| `docker-compose.yml` | основной файл (проект `fakeapp`): `include` для `nginx/docker-compose.yml`, `fake-webapp/docker-compose.yml` и `data/extensions.compose.yml`; про расширения в нём ничего нет |
| `.env.example` | шаблон настроек; при установке копируется в `.env` |
| `data/` (не в git) | `fakeapp/` (страница и файлы сайта), `nginx/` (сгенерированный конфиг, `locations.d/`, webroot), `letsencrypt/` (сертификаты), `extensions.compose.yml` (генерируется), `telegram-web-proxy/` (расширение: конфиг и состояние) |

## Требования

- Ubuntu 22.04+ или Debian 12+, права root (`sudo`).
- Docker с плагином compose v2.20+. Если Docker уже стоит (например, на нём работает 3X-UI), используется он, его настройки не меняются. Если Docker нет, ставится Docker CE из `download.docker.com`. Если нет только плагина compose, ставится плагин.
- `python3`, `curl`, `iproute2`, `openssl` (ставятся автоматически, если их нет).
- Свободные порты 80 и 443 (nginx на хосте или Xray на 443 нужно остановить или перенести) и DNS-запись A/AAAA вашего домена, указывающая на этот сервер: без неё Let's Encrypt сертификат не выдаст. Сервер: 1 CPU и 1 ГБ памяти достаточно.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/dv-proj/escape/main/fakeapp.sh | sudo bash -s -- install
```

Скрипт сам клонирует проект в `/opt/fakeapp` (переменные `FAKEAPP_DIR`, `FAKEAPP_REPO`, `FAKEAPP_BRANCH`) и продолжает установку оттуда; вопросы задаются в терминале. Дальнейшее управление: `cd /opt/fakeapp && ./fakeapp.sh <команда>`.

В конце установки показывается меню дополнительных функций (расширений). Без меню: `--with id1,id2` или `FAKEAPP_EXTENSIONS=all`; список: `./fakeapp.sh extensions`. Как добавить своё расширение: [extensions.d/README.md](extensions.d/README.md).

Скрипт задаёт только эти вопросы:

| Вопрос | Ключ `.env` | По умолчанию |
|---|---|---|
| DNS-имя сайта, например `app.example.com` (обязательно) | `DOMAIN` | нет: без него установка не идёт дальше |
| E-mail для Let's Encrypt (необязательно) | `LE_EMAIL` | пусто: регистрация без e-mail |
| Название сайта | `APP_NAME` | случайное правдоподобное |
| Описание сайта | `APP_DESCRIPTION` | случайное, в тон названию |
| Ключевые слова | `APP_KEYWORDS` | случайные, в тон названию |
| Часовой пояс | `TZ` | часовой пояс хоста |

- **`DOMAIN`** задаёт `server_name` nginx, домен сертификата и теги `canonical` и `og:url` (`https://<DOMAIN>`). Если в существующем `.env` его нет или он пуст, скрипт спросит при следующем запуске.
- Порты nginx (`NGINX_HTTP_PORT`, `NGINX_HTTPS_PORT`, по умолчанию 80 и 443), `LE_STAGING` (`1`: тестовый CA Let's Encrypt, сертификат не доверенный, без лимитов) и порт приложения внутри сети (`FAKEAPP_PORT`, 8080) не спрашиваются: при необходимости задайте их переменными окружения при первом запуске или правьте `.env`. Скрипт проверяет, что 80 и 443 свободны, и называет программу, которая их занимает.

Остальные параметры генерируются случайно: `PAGE_SEED` (вариант оформления), `RANDOM_DATA_SUFFIX`, лимиты запросов и задержки входа. Без терминала вопросы не задаются: берутся значения по умолчанию или переменные окружения с теми же именами, например `DOMAIN=app.example.com LE_EMAIL=me@example.com sudo -E ./fakeapp.sh install`. Без `DOMAIN` установка без терминала завершится ошибкой.

Что делает `install` после проверок: создаёт временный самоподписанный сертификат (чтобы nginx стартовал сразу), собирает и запускает стек, затем запрашивает настоящий сертификат одноразовым контейнером certbot и подставляет его в nginx. Если сертификат получить не удалось (DNS указывает не сюда, порт 80 недоступен из интернета, лимиты Let's Encrypt), скрипт печатает причину и подсказку, остальная установка не прерывается, nginx работает с самоподписанным сертификатом. Исправьте причину и выполните `sudo ./fakeapp.sh renew` (или повторите `install`). Сертификаты хранятся в `data/letsencrypt/`. Продление: systemd-таймер `fakeapp-certbot-renew.timer` (дважды в сутки запускает `./fakeapp.sh renew`: `certbot renew` и перезагрузка nginx); если systemd не запущен, ставится запись в `/etc/cron.d/fakeapp-certbot`.

Повторный `install` пересобирает и перезапускает стек. Значения в `.env` он не меняет, только дописывает новые ключи из `.env.example`. Существующие `login.html` и `favicon.ico` тоже не трогает.

## Команды

| Команда | Действие |
|---|---|
| `sudo ./fakeapp.sh install` | установка или обновление (см. выше) |
| `./fakeapp.sh start` / `stop` / `restart` | запуск, остановка, перезапуск стека (`start` и `restart` заново генерируют конфигурацию nginx) |
| `./fakeapp.sh status` | состояние контейнеров, сертификат, таймер продления и проверка `https://<DOMAIN>/` на этом сервере (`curl --resolve` на `127.0.0.1`) |
| `./fakeapp.sh logs` | журналы контейнеров |
| `sudo ./fakeapp.sh renew` | продлить сертификаты и перечитать конфигурацию nginx; если сертификата ещё нет, запросить его |
| `./fakeapp.sh extensions` | список расширений |
| `sudo ./fakeapp.sh remove [--purge] [-y]` | удалить контейнеры, образы и таймер продления; с `--purge` также `data/fakeapp`, `data/nginx` и `data/letsencrypt` (включая сертификаты). `.env`, проект и Docker остаются |

Для `start`, `stop`, `restart`, `status` и `logs` нужен доступ к Docker: root, `sudo` или группа `docker`. Команды `snippet` больше нет: блок для своего nginx не нужен.

## nginx в контейнере

- Образ: официальный `nginx:stable-alpine`, один контейнер, журнал доступа отключён (`access_log off`).
- Конфигурацию `data/nginx/conf.d/default.conf` генерирует скрипт из шаблона `nginx/default.conf.template`: вручную её не правьте, изменения затираются при `install`, `start` и `restart`. Подстановки берутся из `.env` (`DOMAIN`, `FAKEAPP_PORT`, `NGINX_HTTPS_PORT`).
- Порт 80: путь `/.well-known/acme-challenge/` отдаёт webroot certbot'а, всё остальное получает редирект 301 на `https://<DOMAIN>/`.
- Порт 443: `http2`, TLS 1.2 и 1.3, `server_name <DOMAIN>`. Блок `location /` проксирует в `http://fakeapp:<порт>`, при этом `X-Real-IP` и `X-Forwarded-For` перезаписываются адресом клиента (`$remote_addr`), передаются `X-Forwarded-Proto` и `Host`. Приложение верит `X-Real-IP`, поэтому его порт нигде не публикуется.
- Перед `location /` в блок 443 подключается `include /etc/nginx/locations.d/*.conf;`: каталог `data/nginx/locations.d/` смонтирован в контейнер, расширения кладут туда по одному `.conf` с блоком `location`.
- Пока настоящего сертификата нет, используется временный самоподписанный (`data/nginx/selfsigned/`). Браузеры его не принимают, это нормально до выдачи Let's Encrypt.
- Xray или 3X-UI на этом же сервере: 443 теперь занимает nginx, поэтому перенесите их на другой порт или подключите расширением (в `location` проксируйте на их адрес, например `http://172.17.0.1:<порт>` для сервиса, опубликованного на мосту Docker; порт при этом не должен быть открыт в интернет).

Проверка:

```bash
./fakeapp.sh status
curl -sI https://<DOMAIN>/ | head -n1
```

Ожидается `HTTP/2 200`. Любой несуществующий путь отвечает редиректом 302 на `/`. Ваш реальный IP должен появиться в журнале приложения (`./fakeapp.sh logs`); если там у всех адрес `172.x.x.x`, значит nginx не передаёт `X-Real-IP`.

## Расширения

Дополнительные функции ставятся из `extensions.d/` и не правят общие файлы стека: расширение добавляет свой compose-файл в `data/extensions.compose.yml` (`ext_register_compose`) и свой `location` в `data/nginx/locations.d/<id>.conf` (`ext_nginx_location_put`). Подробности, сигнатуры функций и пример: [extensions.d/README.md](extensions.d/README.md).

### Telegram web proxy (`telegram-web-proxy`)

Расширение `extensions.d/50-telegram-web-proxy.sh` поднимает рядом с сайтом-обманкой веб-прокси Telegram на базе [TELEMT](https://github.com/telemt/telemt) (образ `ghcr.io/telemt/telemt:3.5.17`, режим WEB). Клиент открывает ссылку вида `tg://webproxy?server=<DOMAIN>%2F<секретный путь>&secret=...` и ходит на `https://<DOMAIN>/<секретный путь>/` по обычному HTTPS на 443. nginx отдаёт TELEMT **только** этот путь (`location ^~ /<путь>/` и точный `location = /<путь>`), всё остальное по-прежнему уходит в `fakeapp`; неверные запросы внутри секретного пути TELEMT тоже перенаправляет в обманку (`fakeapp`). Контейнер `telemt` не публикует порты: nginx достучится до него по сети compose (`telemt:18080`), `telemt` до обманки по `http://fakeapp:<порт>`.

**Требования.** Стек установлен и запущен (`DOMAIN` берётся из `.env`, повторно не спрашивается); `NGINX_HTTPS_PORT=443` (Telegram Desktop принимает только 443); `iproute2`, `openssl`, `python3`, `iptables` или `nft` на хосте; доступ к `ghcr.io` при первой установке. Клиент: **Telegram Desktop 7.1 или новее** (тип прокси WEB). Мобильные клиенты не проверялись. Ресурсы: контейнер ограничен `128m` памяти (`TGPROXY_MEM_LIMIT`), в простое занимает десятки МБ; для сервера 1 CPU и 1 ГБ запас большой.

**Установка.** Пункт меню «Telegram web proxy» в конце `install`, либо без меню:

```bash
TGPROXY_OUTWAY=eth0 sudo -E ./fakeapp.sh extensions --with telegram-web-proxy
```

Установка генерирует случайный секретный путь (20 символов) и секрет пользователя (32 hex), пишет `data/telegram-web-proxy/config.toml` (режим 600, владелец uid контейнера) и `state.env` (режим 600), подключает compose-файл (`ext_register_compose`) и `location` (`ext_nginx_location_put`), настраивает outway, сохраняет образ командой `docker save` в `data/telegram-web-proxy/telemt-image.tar` (`TGPROXY_SAVE_IMAGE=0` отключает) и в конце печатает ссылку `tg://webproxy?...`, интерфейс outway и предупреждения. Ссылку берёт из журнала TELEMT (он печатает её при старте); если в журнале её уже нет, вычисляет по документированному формату.

Повторный запуск расширения на установленной системе открывает меню: обновить (скачать образ, пересобрать конфиг, сохранить секреты, если их не меняют), удалить, показать ссылку, сменить outway, сменить секретный путь/секрет, статус. Без терминала действие задаётся переменными окружения (передавайте их через `sudo -E` или `sudo VAR=...`):

| Переменная | Значение |
|---|---|
| `TGPROXY_ACTION` | `install`, `update`, `remove`, `link`, `outway`, `rotate`, `status`. По умолчанию: `install`, а на установленной системе `update` |
| `TGPROXY_OUTWAY` | интерфейс outway (`eth0`, `wg0`, ...) или `auto` (интерфейс маршрута по умолчанию); обязательна при установке без терминала |
| `TGPROXY_ROTATE` | `path`, `secret` или `all`: сменить секретный путь/секрет (при `update` и `rotate`); старая ссылка перестаёт работать |
| `TGPROXY_PURGE=1` | при `remove` удалить ещё и конфиг с секретами и скрипты |
| `TGPROXY_TELEMT_VERSION` | тег образа (по умолчанию закреплён `3.5.17`); при `update` можно указать новый |
| `TGPROXY_PUBLIC_IP` | публичный IPv4 (`public_addr` TELEMT); по умолчанию A-запись `DOMAIN` |
| `TGPROXY_SUBNET` | подсеть `telemt` (по умолчанию свободная `172.29.x.0/24`, начиная с `172.29.77.0/24`) |
| `TGPROXY_SAVE_IMAGE`, `TGPROXY_MEM_LIMIT`, `TGPROXY_SCRIPTS_DIR`, `TGPROXY_FW` | сохранять образ (1/0), лимит памяти, каталог скриптов, `iptables` или `nft` |
| `TGPROXY_DRY_RUN=1` | команды `ip`, `iptables`, `nft`, `systemctl` только печатаются, а не выполняются (остальное, включая Docker, выполняется) |

**Outway: через какой интерфейс уходит трафик к Telegram.** Выбор обязателен. Контейнер `telemt` включён в две сети: общую сеть compose (nginx и обманка) и собственную `<проект>-tgproxy` с фиксированной подсетью; маршрут по умолчанию контейнера идёт через вторую. На хосте для **этой подсети** (и только для неё) создаётся:

- таблица маршрутизации `7791` с `default via <шлюз> dev <outway>` (для `tun`/`wg`/`ppp` без шлюза: `default dev <outway>`), плюс запасной `unreachable default metric 4096`;
- правило `ip rule add from <подсеть> lookup 7791`;
- маскарад `-s <подсеть> -o <outway> -j MASQUERADE` и запрет `-s <подсеть> ! -o <outway> -j DROP` в отдельных цепочках `TGPROXY-OUTWAY` (iptables: nat и filter, фильтр подключён в `DOCKER-USER`; без iptables: отдельная таблица `nft` `tgproxy_outway`).

Остальные контейнеры, обманка, nginx и сам хост маршрутов не меняют. Примеры: `TGPROXY_OUTWAY=eth0` (трафик Telegram идёт через основной интерфейс) или `TGPROXY_OUTWAY=wg0` (через WireGuard; интерфейс `wg0` должен быть поднят, а его `AllowedIPs` должны покрывать адреса Telegram, например `0.0.0.0/0` с `Table = off`, чтобы `wg-quick` не подменял маршрут по умолчанию хоста). Сменить: меню → «change outway» или `tgproxy-config.sh outway wg0`.

**Fail-closed.** Если интерфейс outway не существует или выключен, в таблице остаётся только `unreachable`, а `DROP` не пускает трафик подсети ни через какой другой интерфейс: к Telegram контейнер не достучится, но в обход outway ничего не утечёт; `tgproxy-outway.sh status` пишет `BLOCKED (fail-closed)`. Правила переживают перезагрузку: systemd-юнит `telegram-web-proxy-outway.service` (oneshot, `RemainAfterExit`, после `docker.service`; при остановке переходит в режим «блокировать») плюс таймер `telegram-web-proxy-outway.timer`, который каждые 30 секунд восстанавливает маршрут после перезапуска VPN. Нюанс: сразу после загрузки хоста контейнер может стартовать на несколько секунд раньше юнита; в этом режиме TELEMT не открывает исходящих соединений, пока нет клиентов. Если ответы по outway теряются, проверьте строгий `rp_filter` (`net.ipv4.conf.all.rp_filter=2`): скрипт предупреждает об этом.

**Скрипты на хосте.** Установка копирует три самодостаточных скрипта (им не нужны `fakeapp.sh`, репозиторий и сеть; кроме `docker pull` образа) в `/opt/fakeapp-tgproxy/`, а если установку запустили через `sudo` обычного пользователя, то в `~пользователь/telegram-web-proxy/` (владелец root, права 755; каталог меняется через `TGPROXY_SCRIPTS_DIR`). Скрипты читают `data/telegram-web-proxy/state.env`:

- `tgproxy-config.sh`: `link`, `status`, `outway [интерфейс]`, `rotate path|secret|all`, `render`, `apply` (заново собрать конфиг, подгрузить образ, применить outway и `location`, запустить контейнер), `restart`, `pull` (`docker pull`, а при недоступности реестра `docker load` из сохранённого tar);
- `tgproxy-outway.sh`: `up`, `block`, `down`, `status`, `list`, `check`, `install-unit`, `remove-unit`; `TGPROXY_DRY_RUN=1` печатает команды;
- `tgproxy-remove.sh [--yes] [--purge]`: удаляет `location` (nginx перечитывается), контейнер, сеть, образ, правила outway и юниты, запись в `data/extensions.compose.yml`. Остальной стек (nginx, обманка) продолжает работать. Без `--purge` конфиг, `state.env` и сохранённый образ остаются: переустановка даст ту же ссылку и работает офлайн; `--purge` удаляет и их, и скрипты.

**Безопасность.**

- Секретный путь и секрет входят в учётные данные: ссылку нельзя публиковать. Смена пути или секрета делает старую ссылку недействительной. Секреты лежат только в `config.toml`, `state.env` (оба 600) и в ссылке, которую TELEMT печатает в свой журнал Docker (читается только root и группой `docker`).
- nginx не пишет журнал доступа для этого `location` (в нём есть токены клиента) и передаёт TELEMT `X-Forwarded-For $remote_addr` (перезапись, не добавление); TELEMT доверяет заголовку только от подсети сети compose, и порт `18080` наружу не публикуется.
- Контейнер: `read_only`, `cap_drop: ALL`, `no-new-privileges`, лимиты памяти и процессов, без API управления, без нативного слушателя MTProxy. Любые обращения к другим путям отвечает обманка.
- Адрес `fakeapp` TELEMT разрешает один раз при старте: после пересоздания только `fakeapp` перезапустите прокси (`tgproxy-config.sh restart`; `./fakeapp.sh restart` перезапускает всё сразу).
- `./fakeapp.sh remove` убирает контейнер `telemt`, но не правила outway и юниты: сначала выполните `tgproxy-remove.sh --purge`.

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

Удаляет контейнеры, образы, таймер продления (systemd или `/etc/cron.d/fakeapp-certbot`), а также каталоги данных `data/fakeapp`, `data/nginx` и `data/letsencrypt` (сертификаты тоже). Без `--purge` данные и сертификаты остаются. Docker, `.env` и каталог проекта остаются в любом случае. Если у Xray или 3X-UI были изменены порты ради этого стека, верните их вручную.
