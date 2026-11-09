# escape: личный VPN, замаскированный под обычный сайт

Скрипт разворачивает на VPS стек из 3X-UI (Xray), nginx, acme.sh и сайта-обманки. Всё работает в rootless Docker от отдельного пользователя `vpn`.

## 1. Назначение и как это выглядит снаружи

Цель: личный VPN, который для российской DPI (ТСПУ) и для активных проб выглядит как обычный сайт на вашем домене с настоящим сертификатом Let's Encrypt.

- Браузер или сканер, открывший `https://DOMAIN/`, видит правдоподобную страницу входа в веб-сервис (имя берется из `APP_NAME`).
- Порт панели наружу не опубликован. Панель, как и XHTTP-вход, доступна только по секретному пути.
- Клиенты VPN подключаются через VLESS+REALITY на 443/tcp (основной вариант) или через VLESS+XHTTP поверх TLS (запасные варианты).

## 2. Архитектура

```
                    Интернет
                       |
   +-------------------+--------------------------+
   |                   |                          |
 TCP 443             UDP 443                    TCP 80
   |                   |                          |
   v                   v                          v
+---------------+   +----------------------------------+
| xui (Xray)    |   | nginx                            |
| VLESS+REALITY |   |  80:   ACME HTTP-01 + 301 на https|
+---+-------+---+   |  443/udp: HTTP/3 (QUIC)          |
    |       |       |  8443/tcp: TLS + PROXY protocol  |
    |       |       +----------------------------------+
    |       | не-REALITY трафик (браузер, зонд,    ^
    |       | VLESS+XHTTP+TLS) без изменений       |
    |       | + PROXY protocol -> nginx:8443 ------+
    |       v
    |   валидный клиент REALITY -> проксируется Xray
    v
 (интернет)

nginx (8443/tcp и 443/udp) маршрутизирует по пути:
   /<XHTTP_PATH>/  -> xui:10000   (XHTTP, h2c, grpc_pass)
   /<PANEL_PATH>/  -> xui:2053    (панель 3X-UI)
   всё остальное   -> fakeapp:8080 (сайт-обманка)
```

Реальный сертификат отдает nginx. REALITY использует его как «цель» (self-steal): зонд, не прошедший проверку, получает от nginx настоящий сайт вашего домена.

| Контейнер | Образ | Роль |
|---|---|---|
| `xui` | `ghcr.io/mhsanaei/3x-ui` | 3X-UI + Xray. Публикует 443/tcp. Входы: `reality` (443) и `xhttp` (10000, только внутри сети) |
| `nginx` | `nginx:*-alpine` (с HTTP/3) | 80/tcp (ACME + редирект), 443/udp (HTTP/3), 8443/tcp (внутренний TLS с PROXY protocol). Перечитывает сертификат при его смене |
| `acme` | `neilpang/acme.sh` | Выпуск и автопродление Let's Encrypt (HTTP-01) |
| `fakeapp` | собирается из `fake-webapp/` | Сайт-обманка на Go |

Сайт-обманка (`fakeapp`): `GET /` отдает страницу входа, `POST /login` всегда отвечает 401, а после 3 попыток за минуту для одного логина отвечает 429. `GET /random-<RANDOM_DATA_SUFFIX>?size=N` возвращает до 500000 случайных байт. Общий лимит 10 запросов в секунду, остальные пути перенаправляются на `/`.

## 3. Требования

- VPS с Ubuntu 24.04+ или Debian 12+, доступ root.
- Домен с A-записью на IP сервера (скрипт сверяет DNS и предупреждает о расхождении).
- Открытые порты: 80/tcp, 443/tcp, 443/udp.

Скрипт не настраивает файрвол. Если используете ufw (по желанию):

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
```

## 4. Быстрый старт

```bash
git clone <URL-репозитория> escape
cd escape
sudo ./vpn.sh deploy
```

`deploy` идемпотентен. Он делает следующее:

1. Ставит пакеты, создает пользователя `vpn` (по умолчанию), включает lingering, настраивает sysctl `net.ipv4.ip_unprivileged_port_start=80` (`/etc/sysctl.d/99-vpn-rootless.conf`), ставит rootless Docker.
2. Копирует проект в `~vpn/vpn-stack` (`VPN_DIR`).
3. Создает `.env`, если его нет. Спрашивает `DOMAIN`, `ACME_EMAIL`, `APP_NAME`, `APP_DESCRIPTION`, `APP_KEYWORDS`, `PANEL_USERNAME`. Генерирует `PANEL_PATH`, `XHTTP_PATH`, `PANEL_PASSWORD`, `RANDOM_DATA_SUFFIX`, ключи REALITY, `REALITY_SHORT_ID` и `CLIENT_UUID`.
4. Создает временный самоподписанный сертификат, запускает стек и выпускает сертификат Let's Encrypt.
5. Настраивает панель и создает входы `reality` и `xhttp`.

В конце выводятся URL панели, логин, пароль и три ссылки `vless://`. Повторный запуск обновляет файлы и перезапускает стек, секреты не пересоздаются. Существующий `$VPN_DIR/.env` используется как есть, вопросов нет.

Неинтерактивный режим:

```bash
sudo DOMAIN=vpn.example.com ACME_EMAIL=me@example.com APP_NAME=Notely \
  ./vpn.sh -y deploy
```

Если `DOMAIN`, `ACME_EMAIL`, `APP_NAME` (а также `APP_DESCRIPTION`, `APP_KEYWORDS`, `PANEL_USERNAME`) заданы в окружении, вопросы не задаются. Без терминала остальные вопросы получают значения по умолчанию. Флаг `-y` подтверждает все вопросы (предупреждение об ОС, несовпадение DNS, отключение запущенного rootful Docker, remove/purge). Переменные `VPN_USER` (по умолчанию `vpn`) и `VPN_DIR` позволяют изменить пользователя и каталог.

## 5. Команды

### vpn.sh

| Команда | Права | Действие |
|---|---|---|
| `deploy` | root | Полная установка и обновление (см. выше) |
| `start` | root или `vpn` | `docker compose up -d --wait` |
| `stop` | root или `vpn` | `docker compose stop` |
| `restart` | root или `vpn` | stop + start |
| `status` | root или `vpn` | Состояние контейнеров и сертификата |
| `links` | root или `vpn` | URL панели, логин/пароль и ссылки клиентов |
| `remove` | root | Удалить контейнеры и собранные образы |
| `remove --purge` | root | Дополнительно удалить данные, rootless Docker, пользователя и sysctl-файл |

Опции: `-y/--yes`, `--purge`, `-h/--help`.

### Вспомогательные скрипты

Обычно вызывать их вручную не нужно. Они запускаются из каталога проекта (`~vpn/vpn-stack`) от пользователя `vpn`, которому нужен доступ к его Docker-сокету. Самый простой способ:

У пользователя `vpn` оболочка `nologin`, поэтому `sudo -u vpn -i` не сработает. Запустите bash явно:

```bash
sudo -u vpn -H bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock
cd ~/vpn-stack
```

Затем:

```bash
scripts/certs.sh status      # сертификат и список acme.sh
scripts/certs.sh issue       # выпуск (идемпотентно)
scripts/certs.sh renew       # принудительное продление
scripts/xui.sh links         # ссылки клиентов
scripts/xui.sh configure-panel   # логин/пароль/порт/путь панели из .env
scripts/xui.sh provision     # создать входы reality и xhttp, если их нет
scripts/xui.sh genkeys       # напечатать новые ключи (ничего не записывает)
```

`certs.sh` также умеет `bootstrap` (самоподписанный сертификат-заглушка). Подробности: `scripts/certs.sh help`, `scripts/xui.sh help`.

## 6. Конфигурация (.env)

Файл лежит в `$VPN_DIR/.env` (права 600). Шаблон: `.env.example`.

| Переменная | Тип | Значение по умолчанию / смысл |
|---|---|---|
| `DOMAIN` | вручную | Публичный домен |
| `ACME_EMAIL` | вручную | E-mail для Let's Encrypt |
| `ACME_SERVER` | по умолчанию | `letsencrypt` или `letsencrypt_test` (staging) |
| `APP_NAME`, `APP_DESCRIPTION`, `APP_KEYWORDS` | вручную | Вид сайта-обманки (`Notely`, ...) |
| `RANDOM_DATA_SUFFIX` | сгенерировано | Суффикс адреса случайных данных сайта-обманки (hex, 8-12 символов) |
| `TZ` | по умолчанию | Часовой пояс контейнеров (`Europe/Amsterdam`) |
| `PANEL_PATH` | сгенерировано | Секретный путь панели |
| `PANEL_USERNAME` | вручную/`admin` | Логин панели |
| `PANEL_PASSWORD` | сгенерировано | Пароль панели |
| `PANEL_PORT` | по умолчанию | `2053` (внутри сети) |
| `XHTTP_PATH` | сгенерировано | Секретный путь XHTTP |
| `XHTTP_PORT` | по умолчанию | `10000` (внутри сети) |
| `NGINX_TLS_PORT` | по умолчанию | `8443` (цель REALITY, внутри сети) |
| `REALITY_PRIVATE_KEY`, `REALITY_PUBLIC_KEY` | сгенерировано | Ключи x25519 |
| `REALITY_SHORT_ID` | сгенерировано | 8-16 hex-символов |
| `CLIENT_UUID` | сгенерировано | UUID клиента (общий для обоих входов) |
| `DATA_DIR` | по умолчанию | `./data` (БД панели, сертификаты, состояние acme.sh) |
| `DOCKER_SUBNET` | по умолчанию | `172.30.53.0/24`; nginx доверяет PROXY protocol только из этой подсети |
| `XUI_IMAGE`, `NGINX_IMAGE`, `ACME_IMAGE` | по умолчанию | Закрепленные версии образов |

Как менять значения после установки: отредактируйте `$VPN_DIR/.env` (не файл в клонированном репозитории, повторный `deploy` его не использует, если `.env` в `VPN_DIR` уже есть), затем:

- Данные сайта-обманки (`APP_*`, `TZ`) и пути/порты nginx: `vpn.sh restart` (контейнеры пересоздаются по `docker compose up`).
- Логин, пароль или путь панели: `scripts/xui.sh configure-panel` (он сам перезапускает xui), затем `vpn.sh restart`, чтобы nginx получил новый `PANEL_PATH`.
- `XHTTP_PATH`: исправьте путь во входе `xhttp` в панели и перезапустите стек. Клиентам нужны новые ссылки.
- Ключи REALITY, `REALITY_SHORT_ID`, `CLIENT_UUID`: `provision` не меняет существующие входы (создает их, только если нет входов с такими именами). Обновите значения в панели вручную или удалите входы `reality`/`xhttp` и запустите `scripts/xui.sh provision`. Клиенты должны получить новые ссылки (`vpn.sh links`).

## 7. Варианты использования

Все три ссылки печатаются командой `./vpn.sh links` (или `scripts/xui.sh links`). Один и тот же `CLIENT_UUID` работает на обоих входах.

### A) VLESS + REALITY (Vision): основной

Когда использовать: по умолчанию, это самый быстрый и устойчивый вариант. Работает по TCP 443.

Формат ссылки:

```
vless://UUID@DOMAIN:443?encryption=none&security=reality&sni=DOMAIN&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&spx=%2F&type=tcp&flow=xtls-rprx-vision#имя
```

Поля клиента:

| Поле | Значение |
|---|---|
| Address | `DOMAIN` |
| Port | `443` |
| UUID | `CLIENT_UUID` |
| Flow | `xtls-rprx-vision` |
| Security | `reality` |
| SNI | `DOMAIN` |
| Fingerprint | `chrome` |
| Public key | `REALITY_PUBLIC_KEY` |
| Short ID | `REALITY_SHORT_ID` |
| SpiderX | `/` |
| Network | `tcp` |

Почему устойчив к активным пробам: схема self-steal. Целью REALITY служит собственный nginx с настоящим сертификатом вашего домена (`xver=1`, PROXY protocol). Любой, кто не знает ключ и short id (браузер, сканер), получает от nginx настоящий TLS с настоящим сертификатом и видит сайт-обманку, а не чужой домен с подозрительными расхождениями.

### B) VLESS + XHTTP поверх TLS (h2) через nginx: запасной

Когда использовать: если REALITY блокируется или замедляется. Клиент подключается к 443/tcp как обычный TLS-клиент, Xray передает такое соединение на nginx, а nginx по секретному пути отправляет его в XHTTP-вход.

```
vless://UUID@DOMAIN:443?encryption=none&security=tls&sni=DOMAIN&alpn=h2&fp=chrome&type=xhttp&host=DOMAIN&path=%2FXHTTP_PATH%2F&mode=auto#имя-xhttp
```

Поля: Security `tls`, SNI `DOMAIN`, ALPN `h2`, Network `xhttp`, Host `DOMAIN`, Path `/XHTTP_PATH/` (см. точную строку в `links`), Mode `auto`, Flow пустой. Нужен настоящий сертификат Let's Encrypt: в Xray 26 убран `allowInsecure`, а самоподписанный сертификат-заглушка клиент отвергнет. Поэтому дождитесь успешного выпуска сертификата.

### C) VLESS + XHTTP поверх HTTP/3 (QUIC, UDP 443)

Когда использовать: если UDP на 443 не режется. Ссылка отличается от B значением `alpn=h3`:

```
vless://UUID@DOMAIN:443?encryption=none&security=tls&sni=DOMAIN&alpn=h3&fp=chrome&type=xhttp&host=DOMAIN&path=%2FXHTTP_PATH%2F&mode=auto#имя-xhttp-h3
```

Трафик идет по UDP 443 прямо в nginx, минуя REALITY. Оговорка: в России QUIC часто ограничивают или режут, поэтому это опция, а не основной вариант. Нужен клиент с поддержкой XHTTP поверх QUIC.

### D) XHTTP через CDN (например, Cloudflare): вручную, для продвинутых

Скрипты это не настраивают. Идея: DNS-запись домена идет через CDN в режиме proxy, CDN принимает HTTPS от клиента и пересылает запросы на ваш nginx (443, путь `/XHTTP_PATH/`), откуда они попадают в XHTTP-вход. IP сервера при этом скрыт.

Ограничения:

- REALITY на 443/tcp конфликтует с хостом, проксируемым CDN, для того же домена: CDN подключится к Xray на 443 и не пройдет проверку REALITY. Рекомендуется отдельный поддомен для CDN, который идет в том же стеке (нужно добавить его в `server_name` и в сертификат).
- CDN должен поддерживать стриминг (HTTP/2 к origin, gRPC) либо используйте режим `packet-up`, который работает через обычные запросы. В `auto` поведение зависит от клиента, `packet-up` задается на клиенте и сервере.
- Эта схема в репозитории не проверена и требует ручной настройки DNS, сертификата для поддомена, `server_name` в nginx и ссылки клиента.

### Сравнение

| Вариант | Устойчивость к DPI | Скорость | Нужен UDP | Нужен сертификат | Можно за CDN |
|---|---|---|---|---|---|
| A) REALITY (Vision) | высокая | высокая | нет | есть (self-steal) | нет |
| B) XHTTP + TLS (h2) | средняя/высокая | средняя | нет | да, настоящий | да (см. D) |
| C) XHTTP + HTTP/3 | зависит от QUIC | высокая при отсутствии потерь | да | да, настоящий | нет |
| D) XHTTP через CDN | средняя (зависит от CDN) | средняя | нет | да | да |

### Клиенты

Нужны версии с поддержкой REALITY и XHTTP (свежие релизы):

- Windows/Linux/macOS: v2rayN, NekoBox.
- Android: v2rayNG, NekoBox, Hiddify.
- iOS/macOS: Streisand, FoXray, Shadowrocket, Hiddify.

Импорт: скопируйте `vless://` из `./vpn.sh links` и вставьте из буфера обмена в клиент. QR-код можно получить в панели (кнопка у клиента во входе).

### Дополнительные пользователи

В панели 3X-UI откройте вход `reality` и `xhttp`, добавьте клиентов. Электронная почта (email) клиента должна быть уникальной в пределах панели, один и тот же человек может иметь по клиенту на каждом входе с разными email. Ссылки и QR берутся из панели. Для REALITY-клиентам задайте Flow `xtls-rprx-vision`.

## 8. Панель 3X-UI

- URL: `https://DOMAIN/PANEL_PATH/`.
- Логин и пароль: `PANEL_USERNAME` / `PANEL_PASSWORD` в `.env`; также выводятся `vpn.sh links`.
- Не меняйте порты и target входов без необходимости: порты 10000 и 8443 связаны с настройкой nginx, а target REALITY должен указывать на `nginx:8443` с `xver=1`.
- Не публикуйте адрес панели и не передавайте путь третьим лицам.

## 9. Сертификаты

- Выпуск происходит автоматически при `deploy` (HTTP-01 на порту 80, DNS должен указывать на сервер).
- Продление автоматическое: контейнер `acme` запускает cron acme.sh, nginx сам перечитывает сертификат при смене файлов.
- Проверка: `./vpn.sh status` или `scripts/certs.sh status`.
- Для пробных запусков без лимитов Let's Encrypt поставьте в `.env` `ACME_SERVER=letsencrypt_test` (staging, сертификат не доверенный, клиенты в режиме TLS его не примут). Для рабочей схемы верните `letsencrypt` и выполните `scripts/certs.sh issue`/`renew`.

## 10. Безопасность и маскировка

- Не делитесь путем панели и XHTTP, а также паролем и ссылками.
- Выберите правдоподобные `APP_NAME`, `APP_DESCRIPTION`, `APP_KEYWORDS`.
- Rootless Docker: контейнеры работают от непривилегированного `vpn`; у контейнеров сброшены capabilities и включен `no-new-privileges`.
- Порт панели не опубликован, наружу торчит только 80, 443/tcp и 443/udp.
- Встроенный fail2ban в 3X-UI отключен (нет iptables/NET_ADMIN). Защита от перебора на сайте-обманке и лимит запросов реализованы в самом `fakeapp`.
- Логи: `json-file`, ротация 10 МБ x 3 на контейнер. Лог доступа к XHTTP-пути в nginx отключен.

## 11. Удаление

```bash
sudo ./vpn.sh remove          # контейнеры и образы; данные, пользователь и Docker остаются
sudo ./vpn.sh remove --purge  # + данные (сертификаты, БД панели), rootless Docker, пользователь vpn, sysctl-файл
```

Установленные пакеты не удаляются никогда. Текущее значение sysctl сохраняется до перезагрузки.

## 12. Диагностика и FAQ

Логи (от пользователя `vpn`, в каталоге проекта; см. раздел 5 про окружение):

```bash
docker compose ps
docker compose logs --tail=100 nginx
docker compose logs --tail=100 xui acme fakeapp
```

- Сертификат не выпускается: проверьте A-запись домена, что 80/tcp доступен снаружи (файрвол провайдера и ufw), и что nginx запущен. Затем `scripts/certs.sh issue`. Для отладки используйте staging.
- Клиент не подключается: проверьте синхронизацию времени на сервере и клиенте (REALITY и TLS чувствительны), `fingerprint`, `shortId`, публичный ключ, SNI равен `DOMAIN`, Flow `xtls-rprx-vision` только для REALITY. Для вариантов B и C нужен действительный сертификат.
- Проверка маскировки: `curl -I https://DOMAIN/` должен вернуть страницу сайта-обманки (200), `curl -I http://DOMAIN/` вернет 301 на https.
- Реальные IP клиентов: в nginx приходят через PROXY protocol (TCP) и напрямую (QUIC). При rootless Docker источник соединения на хосте может отображаться как адрес внутренней сети, поэтому не полагайтесь на IP в логах контейнеров как на абсолютно точный.

## 13. Структура репозитория

```
.
├── vpn.sh                  # установка и управление
├── docker-compose.yml      # xui, nginx, acme, fakeapp
├── .env.example            # шаблон конфигурации
├── scripts/
│   ├── lib.sh              # общие функции
│   ├── certs.sh            # сертификаты (acme.sh)
│   └── xui.sh              # панель, входы, ссылки
├── nginx/
│   ├── templates/          # 00-http, 10-site (маршрутизация)
│   └── docker-entrypoint.d/40-cert-reload.sh
└── fake-webapp/            # сайт-обманка на Go
```

Разработка fake-webapp (подробности в `fake-webapp/README.md`):

```bash
cd fake-webapp
go test ./...
docker build -t fake-webapp .
```
