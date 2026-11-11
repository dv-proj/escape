# escape: сайт-обманка (fake-webapp) в rootless Docker

Проект разворачивает три контейнера: `fakeapp` — правдоподобную страницу входа в веб-сервис (Go, `fake-webapp/`), `nginx` — TLS-прокси на портах 80/443 перед ним и `certbot` — получение и продление сертификата Let's Encrypt. Контейнеры работают в rootless Docker **текущего пользователя**: новые пользователи не создаются, проект, `.env` и данные остаются в каталоге, откуда запущен скрипт.

## Состав

| Файл | Назначение |
|---|---|
| `fake-webapp/` | исходники приложения, `Dockerfile`, описание (`fake-webapp/README.md`) |
| `fake-webapp/gen/` | генераторы `login.py` и `favicon.py` (Python 3, только stdlib); запускаются на хосте, в образ не входят |
| `fake-webapp/docker-compose.yml` | сервис `fakeapp`; подключается в любой compose-проект через `include` |
| `nginx/` | TLS-прокси и получение сертификатов: `Dockerfile` (nginx), `Dockerfile.certbot`, `entrypoint.sh` (nginx), `certbot.sh` (цикл certbot) |
| `nginx/docker-compose.yml` | сервисы `nginx` и `certbot`; подключается через `include` |
| `webproxy/` | Telegram WEB-proxy на Telemt: `docker-compose.yml`, конфиг, описание (`webproxy/README.md`); включается настройкой `WEBPROXY_SUBDOMAIN` |
| `docker-compose.yml` | основной файл: `include` для `fake-webapp/docker-compose.yml`, `nginx/docker-compose.yml` и `webproxy/docker-compose.yml` |
| `.env.example` | шаблон настроек (копируется в `.env` при установке) |
| `vpn.sh` | установка и управление |

Подключение в другой проект:

```yaml
include:
  - fake-webapp/docker-compose.yml
```

Все параметры — в одном файле: корневой `.env` основного проекта. Из него compose подставляет переменные и в `fakeapp`, и в остальные сервисы, в том числе подключённые через `include`. Относительные пути внутри `fake-webapp/docker-compose.yml` отсчитываются от `fake-webapp/`.

## Каталог данных

`./data/fakeapp` основного проекта (или `FAKEAPP_DATA_DIR`) монтируется в контейнер **только для чтения**: приложение ничего не пишет.

| Файл | Откуда | Когда приложение видит изменения |
|---|---|---|
| `login.html` | `gen/login.py` (шаблон Go `html/template`), обязателен: без него или с битым шаблоном приложение не стартует | после перезапуска |
| `favicon.ico` | `gen/favicon.py` (первая буква `APP_NAME`, оформление из `PAGE_SEED`) | сразу |
| любые другие файлы и подкаталоги | кладёте сами; отдаются по пути `/<путь>` | сразу |

Не отдаются: скрытые файлы и каталоги (`.*`), сам `/login.html`, каталоги (без листинга). Отсутствующий путь — редирект на `/`.

Права: контейнер работает от непривилегированного uid, для ваших файлов это «прочие». Нужны `r` на файлах и `r-x` на каталогах (обычные 644/755). Владелец файлов — вы, правите их напрямую. `vpn.sh install` создаёт каталог от вашего имени, генерирует недостающие `login.html` и `favicon.ico` (существующие не трогает) и выполняет `chmod -R a+rX`. При подключении через `include` без `vpn.sh` сделайте то же вручную:

```bash
mkdir -p data/fakeapp
```

```bash
python3 fake-webapp/gen/login.py --seed "$PAGE_SEED" --out data/fakeapp/login.html
```

```bash
python3 fake-webapp/gen/favicon.py --seed "$PAGE_SEED" --name="$APP_NAME" --out data/fakeapp/favicon.ico
```

```bash
chmod -R a+rX data/fakeapp
```

Новый вариант оформления: смените `PAGE_SEED`, удалите `login.html` и `favicon.ico` и снова запустите `sudo ./vpn.sh install`.

## Требования

- Ubuntu 24.04+ или Debian 12+, обычный пользователь с правом `sudo`.
- Проект склонирован этим пользователем (каталог принадлежит ему).
- `python3` (ставится `install`, если его нет).
- Порты 80 и 443 TCP хоста свободны и доступны снаружи (для выдачи сертификата Let's Encrypt нужен порт 80, и `DOMAIN` должен указывать на этот хост).

## Команды

```bash
sudo ./vpn.sh install
```

Ставит Docker CE и rootless-расширения, настраивает rootless Docker и lingering для пользователя, вызвавшего `sudo`, создает `.env` (имя/описание сайта предлагаются случайные, DNS-имя сайта `DOMAIN` — необязательное, без протокола: приложение получает `https://<DOMAIN>` для `canonical`/`og:url`, а без имени эти теги не выводятся), готовит каталог данных и генерирует недостающие `login.html`/`favicon.ico`, собирает и запускает `fakeapp`, `nginx` и `certbot`. Если `DOMAIN` — DNS-имя, спрашивает `ACME_EMAIL` (необязательный e-mail аккаунта Let's Encrypt; пустой — аккаунт без e-mail; можно передать через окружение). Повторный запуск не меняет значения в `.env` (только дописывает новые ключи). Запуск от «голого» root без `sudo` отклоняется: rootless Docker под root невозможен.

Сетевые шаги: понижает `net.ipv4.ip_unprivileged_port_start` до 80 (rootless Docker публикует 80/443); открывает 80/443 TCP в файрволе — `ufw`, если он активен, `firewalld`, если запущен, иначе правила iptables/ip6tables в INPUT, и только если INPUT не открыт полностью. Правила сохраняются через `netfilter-persistent`, если он установлен; иначе выводится предупреждение, что они не постоянные. Файрвол облачного провайдера открывайте отдельно. Всего шагов установки: 11.

```bash
./vpn.sh webproxy user add|del|list|link <name>
```

Пользователи Telegram WEB-proxy (см. «Telegram WEB-proxy»).

```bash
./vpn.sh start
```

```bash
./vpn.sh stop
```

```bash
sudo ./vpn.sh remove
```

Удаляет контейнеры и собранные образы; том с сертификатами сохраняется. С `--purge` — также тома Docker, включая сертификаты (`tls-certs`), каталог данных, rootless Docker пользователя (со **всеми** его образами и контейнерами), lingering и файлы sysctl/AppArmor. Каталог проекта, `.env` и пакеты не удаляются. `-y` отвечает «да» на все вопросы.

## Сеть

Перед приложением стоит контейнер `nginx` на портах хоста 80 и 443 TCP. По умолчанию весь трафик идёт в `fakeapp`, nginx ставит `X-Real-IP` (по нему считается лимит запросов):

- порт 80: `/.well-known/acme-challenge/` отдаётся из общего каталога certbot (неизвестные пути — в `fakeapp`); остальное — редирект на https, если задан `DOMAIN`, иначе проксируется в `fakeapp`;
- порт 443: TLS, сертификат из тома `tls-certs`, пока его нет — самоподписанный. nginx проверяет сертификат каждые 60 с и перезагружается сам при изменении.

`fakeapp` слушает порт `FAKEAPP_PORT` (по умолчанию 8080) внутри контейнера, публикуется на `FAKEAPP_BIND:FAKEAPP_PORT` хоста (по умолчанию `127.0.0.1:8080`), и nginx проксирует на `fakeapp:FAKEAPP_PORT` — порт задаётся одной переменной в `.env` (кроме 80 и 443, их занимает nginx); для прямой публикации задайте `FAKEAPP_BIND=0.0.0.0`. Файрвол: `install` открывает 80/443 TCP (см. «Команды»).

## TLS-сертификаты

Если `DOMAIN` — DNS-имя, `certbot` получает сертификат Let's Encrypt по HTTP-01 (через порт 80) и продлевает его: проверка раз в 12 ч, после ошибки повтор через 15 мин. Если `DOMAIN` пустой или это IP-адрес, сертификат не запрашивается, nginx использует самоподписанный.

- `ACME_EMAIL` — необязательный e-mail аккаунта;
- `ACME_STAGING=1` — тестовый сервер Let's Encrypt (сертификат браузеры не доверяют, лимиты выше); возврат к `0` заменит тестовый сертификат на боевой при следующем старте;
- `TLS_CERTS_VOLUME` — имя тома (по умолчанию `tls-certs`).

Сертификаты лежат в томе в виде `/etc/letsencrypt`: `live/<DOMAIN>/fullchain.pem`, `live/<DOMAIN>/privkey.pem`. Другой проект может использовать их, подключив том как внешний:

```yaml
services:
  xray:
    volumes:
      - tls-certs:/etc/letsencrypt:ro
volumes:
  tls-certs:
    external: true
```

Если задан `TLS_CERTS_VOLUME`, в примере используйте это имя.

## Telegram WEB-proxy

Необязательный прокси Telegram (WEB-транспорт) на [Telemt](https://github.com/telemt/telemt), образ `ghcr.io/telemt/telemt:3.5.17`. Работает в Telegram Desktop 7.1.3+ и в Android-клиенте (бета); стабильного клиента для iOS нет. Звонки через прокси не работают.

Прокси отвечает по HTTPS на поддомене `<WEBPROXY_SUBDOMAIN>.<DOMAIN>` через nginx, порт 443. Отдельный порт MTProxy не открывается.

Включение: `DOMAIN` должен быть DNS-именем. `sudo ./vpn.sh install` спрашивает метку поддомена (пусто — функция выключена) и публичный IPv4 этого хоста. Создайте A-запись `<метка>.<DOMAIN>` на этот адрес. Для поддомена выдаётся отдельный сертификат Let's Encrypt.

Поведение:

- весь поддомен уходит в Telemt;
- любой некорректный запрос (неверный secret, неизвестный путь, порт 80) получает редирект 302 на `https://<DOMAIN>` с тем же путём;
- журнал доступа на поддомене выключен: параметр `?bridge=` в запросе является учётными данными;
- постквантовая группа X25519MLKEM768 в TLS по умолчанию включена (`TLS_PQ=1`). Если Android-клиент WEB-proxy не подключается (telegramdesktop/tproxy-server#16), поставьте `TLS_PQ=0`: останутся только классические группы. Настройка действует на все имена порта 443 сразу, nginx не умеет задавать её для отдельного имени.

Пользователи (до 32):

```bash
./vpn.sh webproxy user add <name>
./vpn.sh webproxy user del <name>
./vpn.sh webproxy user list
./vpn.sh webproxy user link <name>
```

По умолчанию (`WEBPROXY_RELOAD=hot`) Telemt сам перечитывает конфиг: новый пользователь работает сразу, сессии удалённого закрываются, остальные клиенты не отключаются. `WEBPROXY_RELOAD=recreate` вместо этого пересоздаёт контейнер, и переподключаются все.

Ссылка имеет вид `tg://webproxy?server=<поддомен>&secret=dd<32 hex>`. Последнего пользователя удалить нельзя. Чтобы выключить функцию, очистите `WEBPROXY_SUBDOMAIN` в `.env` и снова запустите `sudo ./vpn.sh install`.

Данные: список пользователей и сгенерированный `telemt/config.toml` лежат в `data/webproxy` (каталог 0700, файлы 0600).

## Настройки

См. комментарии в `.env.example` и таблицу переменных в `fake-webapp/README.md`. После правки `login.html` перезапустите контейнер: `./vpn.sh stop && ./vpn.sh start`.
