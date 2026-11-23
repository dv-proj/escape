# Russian messages (printf formats; a literal % is written %%). Same key set as the other language.
# shellcheck shell=bash disable=SC2034
MSG["app.cant_create"]="не удалось создать %s"
MSG["app.favicon_fail"]="не удалось создать favicon.ico"
MSG["app.file_generated"]="%s создан"
MSG["app.file_kept"]="%s уже есть; оставляем как есть"
MSG["app.https_down"]="%s не отвечает (см.: ./install.sh logs)"
MSG["app.https_ok"]="%s отвечает (nginx -> fakeapp, сертификат доверенный)"
MSG["app.https_untrusted"]="%s отвечает, но сертификат пока не доверенный (временный самоподписанный или LE_STAGING=1)"
MSG["app.login_fail"]="не удалось создать login.html"
MSG["app.missing_file"]="%s отсутствует в %s"
MSG["app.not_readable"]="не удалось сделать все файлы в %s читаемыми для контейнера"
MSG["app.project_ok"]="проект: %s"
MSG["app.readable"]="%s доступен контейнеру для чтения (монтируется только для чтения)"
MSG["app.sum_cert"]="Сертификат : %s"
MSG["app.res_header"]="=== Итоговые данные ==="
MSG["app.res_random"]="Путь random-data (fake-app): https://%s%s/random-%s?size=1000"
MSG["app.sum_files"]="Файлы      : %s (login.html: после правки выполните ./install.sh restart; остальные файлы отдаются как есть)"
MSG["app.sum_name"]="Название   : %s"
MSG["app.sum_nginx"]="nginx      : %s/conf.d/default.conf создаётся автоматически (не правьте его); расширения добавляют location в %s/locations.d/"
MSG["app.sum_renew"]="Продление  : %s"
MSG["app.sum_site"]="Сайт       : https://%s%s/ (контейнер nginx на портах %s/%s; приложение только внутри сети: http://fakeapp:%s)"
MSG["certs.cron_ok"]="запись cron для продления установлена: %s"
MSG["certs.dns_mismatch"]="%s указывает на %s, а это не адрес этого сервера (NAT или A-запись ведёт в другое место): проверьте, иначе сертификат Let's Encrypt не будет выдан"
MSG["certs.dns_noresolve"]="%s не разрешается в IPv4-адрес (нет A-записи?): сертификат Let's Encrypt не будет выдан, пока это не исправлено"
MSG["certs.dns_ok"]="%s указывает на этот сервер (%s)"
MSG["certs.ext_bad_name"]="%s: неверное DNS-имя '%s'"
MSG["certs.ext_deleted"]="файлы сертификата %s удалены"
MSG["certs.ext_have"]="сертификат Let's Encrypt для %s уже есть"
MSG["certs.ext_registered"]="сертификат %s зарегистрирован для '%s' (продлевается таймером)"
MSG["certs.ext_released"]="сертификат %s освобождён расширением '%s' (больше не продлевается; файлы сохранены)"
MSG["certs.failed"]="не удалось получить сертификат для %s; nginx продолжает работать с временным самоподписанным"
MSG["certs.hint1"]="проверьте: A/AAAA-запись %s указывает на этот сервер;"
MSG["certs.hint2"]="            порт 80 доступен из интернета (файрвол, группа безопасности в облаке) и обслуживается этим стеком;"
MSG["certs.hint3"]="            не исчерпаны лимиты Let's Encrypt (для проверки попробуйте LE_STAGING=1)."
MSG["certs.issued"]="сертификат для %s выдан"
MSG["certs.reload_fail"]="nginx не перезагрузился (см.: ./install.sh logs)"
MSG["certs.reloaded"]="nginx перезагружен с новым сертификатом"
MSG["certs.renew_fail_name"]="certbot renew завершился ошибкой для %s"
MSG["certs.renew_reload_fail"]="nginx не перезагрузился"
MSG["certs.renewed"]="сертификаты проверены, nginx перезагружен"
MSG["certs.requesting"]="запрашиваем сертификат для %s у Let's Encrypt"
MSG["certs.retry"]="затем повторите: sudo ./install.sh renew (или запустите install снова)"
MSG["certs.selfsigned_fail"]="не удалось создать временный самоподписанный сертификат (openssl)"
MSG["certs.selfsigned_ok"]="создан временный самоподписанный сертификат для %s"
MSG["certs.staging_suffix"]=" (тестовый)"
MSG["certs.staging_warn"]="LE_STAGING=1: браузеры не будут доверять этому сертификату"
MSG["certs.state_cron"]="запись cron %s"
MSG["certs.state_none"]="не установлено (выполните: sudo ./install.sh install)"
MSG["certs.state_timer"]="таймер systemd %s (%s)"
MSG["certs.sum_le"]="Let's Encrypt%s, действует до %s"
MSG["certs.sum_self"]="временный самоподписанный (сертификата Let's Encrypt ещё нет: sudo ./install.sh renew)"
MSG["certs.timer_fail"]="не удалось включить %s; вместо него используется %s"
MSG["certs.timer_ok"]="таймер продления установлен: %s (systemctl list-timers %s)"
MSG["certs.unknown"]="неизвестно"
MSG["cmd.confirm_purge"]="Удалить контейнеры, их образы, таймер продления, системные файлы расширений, данные (%s) и весь каталог установки %s?"
MSG["cmd.confirm_remove"]="Остановить и удалить контейнеры, их образы и таймер продления (данные и сертификаты останутся)?"
MSG["cmd.delete_fail"]="не удалось полностью удалить %s"
MSG["cmd.dir_needs_value"]="--dir требует значение"
MSG["cmd.ext_purge_fail"]="не удалось полностью удалить расширение '%s'; проверьте его системные файлы вручную (см. README: вне каталога установки)"
MSG["cmd.finished"]="Установка завершена."
MSG["cmd.lang_needs_value"]="--lang требует значение"
MSG["cmd.no_env"]="%s не найден; выполните: sudo ./install.sh install"
MSG["cmd.one_command"]="допускается только одна команда (получено '%s' и '%s')"
MSG["cmd.purge_only"]="--purge применим только к 'remove'"
MSG["cmd.refresh_warn"]="не удалось обновить конфигурацию nginx в %s (нужен root?); используется имеющаяся"
MSG["cmd.rm_done"]="каталог установки %s, файл-указатель и все данные удалены; Docker сохранён"
MSG["cmd.rm_kept"]="данные (%s) и .env сохранены в %s (чтобы удалить данные и каталог установки, используйте --purge)"
MSG["cmd.rm_skip_down"]="docker или %s недоступны; пропускаем 'docker compose down'"
MSG["cmd.status_cert"]="Сертификат: %s"
MSG["cmd.status_renew"]="Продление : %s"
MSG["cmd.step_cert"]="Получение сертификата Let's Encrypt"
MSG["cmd.step_data"]="Подготовка каталога данных и конфигурации nginx"
MSG["cmd.step_docker"]="Проверка Docker и docker compose"
MSG["cmd.step_env"]="Подготовка .env"
MSG["cmd.step_prereqs"]="Установка необходимых пакетов (%s)"
MSG["cmd.step_renew"]="Продление сертификатов"
MSG["cmd.step_rm_containers"]="Удаление контейнеров и образов"
MSG["cmd.step_rm_data"]="Удаление данных"
MSG["cmd.step_rm_ext"]="Удаление системных файлов расширений"
MSG["cmd.step_rm_timer"]="Удаление таймера продления"
MSG["cmd.step_stack"]="Сборка и запуск nginx и fakeapp"
MSG["cmd.step_summary"]="итоговая сводка"
MSG["cmd.step_timer"]="Установка таймера продления сертификата"
MSG["cmd.suspicious"]="отказ удалять подозрительный путь '%s'"
MSG["cmd.unknown_arg"]="неизвестный аргумент '%s' (см. --help)"
MSG["cmd.with_needs_value"]="--with требует значение"
MSG["common.aborted"]="прервано"
MSG["common.all_valid"]="все значения корректны"
MSG["common.assume_yes"]="%s -> да (--yes)"
MSG["common.need_root"]="'%s' нужно запускать от root (например: sudo ./install.sh %s)"
MSG["common.no_input"]="нет ввода"
MSG["common.no_terminal"]="%s (нет терминала; чтобы согласиться, запустите с --yes)"
MSG["common.phase"]="### Этап %s/3: %s"
MSG["common.problems_found"]="найдено проблем: %d; ничего не развёрнуто:"
MSG["common.step"]="==> [%d/%d] %s"
MSG["common.step_failed"]="шаг «%s» завершился с ошибкой (код %d) в %s, строка %s: %s"
MSG["common.wait_timeout"]="истекло время ожидания (%s с): %s"
MSG["common.yn"]="[д/Н]"
MSG["dir.bad_chars"]="в каталоге установки '%s' допустимы только буквы, цифры и . _ / + @ : - (без пробелов)"
MSG["dir.cant_create"]="каталог установки '%s' создать нельзя: нет прав на запись в '%s' (запустите от root или выберите другой путь)"
MSG["dir.deprecated_env"]="FAKEAPP_DIR устарел; используйте ESCAPE_DIR или --dir"
MSG["dir.from_default"]="каталог установки (по умолчанию): %s"
MSG["dir.from_flag"]="каталог установки (--dir): %s"
MSG["dir.is_checkout"]="'%s' — репозиторий, из которого запущен этот install.sh, а не установка; выберите другой каталог (по умолчанию /opt/escape), чтобы каталог установки остался чистым"
MSG["dir.legacy"]="'%s' похож на старую установку (git-репозиторий проекта с .env/data). Он не затрагивается: остановите и удалите его его же командой './install.sh remove --purge' или выберите другой каталог (для переноса сначала скопируйте его .env и data/ в новый каталог; см. README: Перенос со старой схемы)"
MSG["dir.new"]="каталог установки: %s"
MSG["dir.no_install"]="установка не найдена: %s не существует, ни --dir, ни ESCAPE_DIR не заданы, а этот install.sh не установленная копия. Сначала выполните install (каталог по умолчанию %s) или укажите установку параметром --dir PATH"
MSG["dir.no_installed_script"]="%s/install.sh отсутствует: установка повреждена; выполните install заново из свежей загрузки"
MSG["dir.not_absolute"]="каталог установки '%s' должен быть абсолютным путём (начинаться с /)"
MSG["dir.not_dir"]="'%s' существует и не является каталогом"
MSG["dir.not_empty"]="'%s' не пуст и не является установкой этого проекта (нет маркера %s); выберите пустой или новый каталог (подойдёт и каталог, где лежат только .env и data/, скопированные из старой установки)"
MSG["dir.not_installation"]="%s не является установкой этого проекта (нет маркера %s); проверьте --dir / ESCAPE_DIR / файл-указатель"
MSG["dir.not_writable"]="в каталог установки '%s' нельзя писать (запустите от root или выберите другой путь)"
MSG["dir.q"]="Каталог установки (здесь живут код, .env и все данные)"
MSG["dir.registered"]="установка зарегистрирована: %s -> %s"
MSG["dir.reuse"]="%s — существующая установка: код обновляется, .env и data/ сохраняются"
MSG["dir.src_incomplete"]="%s отсутствует в %s: файлы проекта неполные (скачайте заново)"
MSG["dir.step_register"]="Регистрация установки (%s)"
MSG["dir.sync_fail"]="не удалось скопировать проект в %s"
MSG["dir.synced"]="проект скопирован: файлов %s в %s (удалено устаревших: %s)"
MSG["dir.system"]="'%s' — системный каталог, он не может быть каталогом установки; выберите подкаталог, например /opt/escape"
MSG["dir.this_copy"]="каталог установки (эта установленная копия): %s"
MSG["env.added_key"]="добавлен отсутствующий ключ %s в %s"
MSG["env.cannot_generate"]="не удалось сгенерировать %s"
MSG["env.creating"]="создаём %s"
MSG["env.default_invalid"]="значение по умолчанию для %s неверно: ожидается %s"
MSG["env.domain_bad_fix"]="DOMAIN в %s не является корректным DNS-именем; исправьте его и запустите install снова"
MSG["env.domain_missing"]="DOMAIN в %s отсутствует или не является DNS-именем (получено '%s'); задайте его и запустите install снова"
MSG["env.domain_set"]="DOMAIN записан в %s"
MSG["env.empty_generated"]="в созданном .env пустое значение для %s"
MSG["env.from_default"]="%s (по умолчанию): %s"
MSG["env.from_environment"]="%s (из окружения): %s"
MSG["env.generator_empty"]="генератор для %s ничего не вернул"
MSG["env.invalid_email"]="неверный адрес e-mail"
MSG["env.invalid_from_env"]="%s из окружения неверно: ожидается %s"
MSG["env.invalid_value"]="неверное значение; ожидается %s"
MSG["env.lang_saved"]="FAKEAPP_LANG=%s сохранён в %s"
MSG["env.missing_no_default"]="ключа %s нет в %s, значения по умолчанию тоже нет; добавьте его вручную"
MSG["env.no_template"]="шаблон не найден: %s"
MSG["env.no_value"]="нет значения для %s"
MSG["env.port_range"]="%s в %s должен быть в диапазоне 1-65535 (получено '%s')"
MSG["env.q_app_desc"]="Описание сайта-обманки"
MSG["env.q_app_kw"]="Ключевые слова сайта-обманки"
MSG["env.q_app_name"]="Название сайта-обманки"
MSG["env.q_domain"]="DNS-имя сайта (его A-запись должна указывать на этот сервер), например app.example.com"
MSG["env.q_email"]="E-mail для уведомлений Let's Encrypt о сроке сертификата (пусто: без e-mail)"
MSG["env.q_tz"]="Часовой пояс"
MSG["env.required_noterm"]="%s обязателен (задайте его в окружении; терминала для вопроса нет)"
MSG["env.reusing"]="%s уже есть; используем его (вопросов не будет)"
MSG["env.written"]="%s записан (права 600)"
MSG["ext.bad_chars"]="%s: недопустимые символы в '%s'"
MSG["ext.bad_choice"]="неверный выбор '%s'"
MSG["ext.bad_id"]="%s: недопустимый идентификатор '%s'"
MSG["ext.compose_not_found"]="%s: compose-файл не найден: '%s'"
MSG["ext.compose_registered"]="compose-файл расширения '%s' подключён: %s"
MSG["ext.compose_unregistered"]="compose-файл расширения '%s' отключён"
MSG["ext.empty_location"]="%s: пустой location для '%s'"
MSG["ext.empty_server"]="%s: пустой блок server для '%s'"
MSG["ext.empty_stream"]="%s: нет маршрутов для '%s'"
MSG["ext.location_ok"]="location nginx '%s' установлен: %s"
MSG["ext.location_removed"]="location nginx '%s' удалён"
MSG["ext.menu_prompt"]="Что установить? Номера через пробел, 'all' (всё) или пусто (ничего): "
MSG["ext.menu_title"]="Дополнительные функции:"
MSG["ext.nginx_after_rm"]="nginx не принял конфигурацию после удаления '%s'"
MSG["ext.nginx_not_running"]="nginx не запущен; конфигурация будет применена при его следующем запуске"
MSG["ext.nginx_recreate"]="контейнер nginx однократно пересоздаётся, чтобы подключить data/nginx/servers.d (сайт недоступен несколько секунд)"
MSG["ext.nginx_rejected"]="nginx не принял location '%s' (изменения отменены); см. сообщение выше"
MSG["ext.nginx_rejected_server"]="nginx не принял блок server '%s' (изменение отменено); см. сообщение выше"
MSG["ext.nginx_rejected_stream"]="nginx не принял маршрут TLS-фронта '%s' (изменение отменено); см. сообщение выше"
MSG["ext.none"]="расширений нет (см. extensions.d/README.md)"
MSG["ext.server_ok"]="блок server nginx '%s' установлен: %s"
MSG["ext.server_removed"]="блок server nginx '%s' удалён"
MSG["ext.step"]="Расширение: %s"
MSG["ext.stream_bad_route"]="%s: неверный маршрут '%s' (ожидается: ИМЯ ХОСТ:ПОРТ)"
MSG["ext.stream_ok"]="маршрут TLS-фронта nginx '%s' установлен: %s"
MSG["ext.stream_removed"]="маршрут TLS-фронта nginx '%s' удалён"
MSG["ext.stream_sni_taken"]="%s: имя '%s' обслуживает HTTPS-сервер этого nginx (DOMAIN или сертификат расширения); направить его в другое место нельзя"
MSG["ext.unknown"]="неизвестное расширение '%s' (список: ./install.sh extensions)"
MSG["ext.validate_failed"]="расширение '%s': проверка не пройдена"
MSG["hint.01"]="0 или 1"
MSG["hint.domain"]="DNS-имя вида app.example.com"
MSG["hint.email"]="адрес e-mail"
MSG["hint.port"]="порт 1-65535"
MSG["hint.text"]="от 1 до 200 символов, без кавычек, \$, обратных апострофов и обратной косой черты"
MSG["hint.tz"]="зона IANA, например Europe/Berlin"
MSG["i18n.bad_lang"]="неизвестный язык '%s' (источник: %s); допустимо en или ru"
MSG["lbl.error"]="ошибка"
MSG["lbl.ok"]="готово"
MSG["lbl.warning"]="внимание"
MSG["nginx.by_holder"]=" программой '%s'"
MSG["nginx.cert_le"]="сертификат Let's Encrypt"
MSG["nginx.cert_self"]="временный самоподписанный сертификат"
MSG["nginx.http_port_warn"]="NGINX_HTTP_PORT=%s: Let's Encrypt проверяет домен только на порту 80; пробросьте его сюда, иначе сертификат не выдастся"
MSG["nginx.port_busy"]="порт %s уже занят%s (другой nginx, Xray, 3X-UI?); остановите её или перенесите на другой порт, проверить можно так: ss -ltnp 'sport = :%s'. nginx этого стека нужны порты %s и %s (NGINX_HTTP_PORT и NGINX_HTTPS_PORT в %s)"
MSG["nginx.ports_free"]="порты %s и %s свободны для nginx"
MSG["nginx.recreate_front"]="контейнер nginx однократно пересоздаётся для TLS-фронта на порту HTTPS (stream, data/nginx/stream.d): сайт недоступен несколько секунд"
MSG["nginx.rendered"]="конфигурация nginx создана: %s (%s)"
MSG["phase.collect"]="Сбор настроек (только вопросы, ничего не меняется)"
MSG["phase.deploy"]="Развёртывание"
MSG["phase.validate"]="Проверка"
MSG["system.cant_enable_docker"]="не удалось включить docker.service"
MSG["system.compose_manual_io"]="не удалось установить плагин compose для docker.io; установите Docker Compose v2 вручную"
MSG["system.compose_missing"]="плагин docker compose отсутствует: устанавливаем"
MSG["system.compose_na"]="docker compose недоступен"
MSG["system.compose_old"]="docker compose %s слишком старый (нужна версия 2.20+); обновите docker-compose-plugin"
MSG["system.continue_anyway"]="Всё равно продолжить с репозиторием Docker для %s?"
MSG["system.daemon_start"]="демон Docker не отвечает; запускаем docker.service"
MSG["system.daemon_unreachable"]="нет связи с демоном Docker (он не запущен или нет прав: попробуйте sudo)"
MSG["system.desc_daemon"]="демон Docker"
MSG["system.docker_found"]="Docker найден: %s"
MSG["system.docker_missing"]="Docker не установлен: ставим Docker CE с download.docker.com"
MSG["system.docker_not_apt"]="Docker установлен не из apt (snap, бинарный файл?); установите плагин Docker Compose v2 вручную"
MSG["system.docker_not_found"]="docker не найден; выполните: sudo ./install.sh install"
MSG["system.fetch_key"]="загружаем ключ репозитория Docker"
MSG["system.installing_prereqs"]="устанавливаем необходимые пакеты: %s"
MSG["system.no_apt"]="apt-get не найден (поддерживаются только Debian и Ubuntu)"
MSG["system.no_base"]="основа Debian/Ubuntu не обнаружена; репозиторий Docker для apt настроить нельзя"
MSG["system.no_codename"]="не удалось определить кодовое имя дистрибутива"
MSG["system.no_osrel"]="/etc/os-release не найден: система не поддерживается"
MSG["system.no_systemd"]="systemctl не найден (нужен systemd)"
MSG["system.prereqs_ok"]="необходимые пакеты уже установлены (%s)"
MSG["system.unsupported"]="%s не поддерживается (нужен Ubuntu 22.04+ или Debian 12+)"
MSG["usage"]="$(cat <<'EOF_MSG'
Использование: install.sh [параметры] <команда>

Разворачивает стек docker compose: nginx в контейнере (порты 80 и 443 хоста,
TLS с сертификатом Let's Encrypt для DOMAIN) перед сайтом-обманкой
(fake-webapp), которая доступна только внутри сети compose. Поддерживаются
Ubuntu 22.04+ и Debian 12+.

Проект живёт в каталоге установки (по умолчанию /opt/escape; --dir,
ESCAPE_DIR): install копирует его туда из репозитория / загрузки, в котором
лежит этот скрипт, а все команды выполняют установленную копию
(/opt/escape/install.sh). При запуске из другого места команды находят
установку по /etc/escape/install-dir (или по --dir / ESCAPE_DIR).

Команды:
  install   Идемпотентная установка (root/sudo) в три фазы: сбор всех ответов
            (только вопросы: язык, каталог установки, параметры сайта),
            проверка всех значений сразу, затем развёртывание. Копирует проект
            в каталог установки (при обновлении .env и data/ сохраняются),
            использует Docker системы (Docker CE ставится только если docker
            нет, плагин compose только если его нет), создаёт .env
            (спрашивает DNS-имя сайта, e-mail для Let's Encrypt, название,
            описание и ключевые слова сайта; остальное генерируется), создаёт
            недостающие login.html и favicon.ico и конфигурацию nginx,
            собирает и запускает стек, получает сертификат (certbot, webroot)
            и ставит таймер продления. Повторный запуск обновляет, пересобирает
            и перезапускает стек; значения в .env и файлы в data/ сохраняются.
  start     Запустить стек (docker compose up -d --wait).
  stop      Остановить стек.
  restart   Перезапустить стек (например, после правки login.html).
  info      Повторно вывести итоговые данные (путь random-data, ссылка web-proxy).
  status    Показать состояние контейнеров, сертификат и проверить
            https://DOMAIN/ на этом сервере (curl --resolve на 127.0.0.1).
  logs      Следить за журналами контейнеров (выход: Ctrl+C).
  renew     Продлить сертификаты и перезагрузить nginx (запускается таймером;
            если сертификата ещё нет, выпускает его). root/sudo.
  extensions  Список дополнительных функций (extensions.d/); с --with ID,...
            устанавливает их.
  remove    Удалить стек, его образы и таймер продления (root/sudo).
            Каталог установки, .env и data/ остаются. С --purge удаляется всё,
            что создала установка: системные файлы расширений (юниты,
            sysctl, правила файрвола), данные, весь каталог установки и
            /etc/escape/install-dir. Docker остаётся.

Параметры:
  -y, --yes   Отвечать «да» на все подтверждения.
  --dir PATH  Каталог установки (по умолчанию /opt/escape; также ESCAPE_DIR;
              FAKEAPP_DIR устарел и работает как псевдоним). Спрашивается сразу
              после языка. Нужен абсолютный путь к пустому, новому или уже
              установленному каталогу этого проекта.
  --with IDS  Расширения, которые нужно установить без меню (список через
              запятую или "all"); также FAKEAPP_EXTENSIONS. Для install и
              extensions.
  --lang L    Язык сообщений: en или ru (также FAKEAPP_LANG, сохраняется в
              .env как FAKEAPP_LANG). Без параметра install спросит в самом
              начале (по умолчанию: английский).
  --purge     Для `remove`: удалить ещё и данные и каталог установки.
  -h, --help  Показать эту справку.

Переменные окружения (используются, когда install создаёт .env, без вопросов):
  DOMAIN, LE_EMAIL, LE_STAGING, NGINX_HTTP_PORT, NGINX_HTTPS_PORT, FAKEAPP_PORT,
  APP_NAME, APP_DESCRIPTION, APP_KEYWORDS, FAKEAPP_LANG
              Незаданные APP_* генерируются случайно (в диалоге предлагаются
              как значения по умолчанию). Без терминала каждый вопрос берёт
              значение по умолчанию, кроме DOMAIN: он обязателен.
  Загрузка (только curl | bash): ESCAPE_REPO_URL (по умолчанию
  https://codeload.github.com/dv-proj/escape), ESCAPE_BRANCH (по умолчанию main).

Примечания:
  * Порты 80 и 443 должны быть свободны (сначала остановите nginx / Xray на
    хосте).
  * Конфигурация сайта создаётся в data/nginx/ (не правьте её); расширения
    добавляют location как data/nginx/locations.d/<id>.conf
    (extensions.d/README.md).
  * start/stop/restart/status/logs требуют доступа к Docker (root, sudo или
    группа docker).
EOF_MSG
)"
