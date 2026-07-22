#!/bin/bash
# ================================================
# Конфигурация и чтение данных из config.yaml
# ================================================

# UTF-8 локаль нужна, чтобы ${#str} считал символы (а не байты) — иначе
# выравнивание таблицы «плывёт» на эмодзи и кириллице. Выбираем доступную.
if [ -z "${LC_ALL:-}" ] || ! printf '%s' "$LC_ALL" | grep -qi 'utf-\?8'; then
    if locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
        export LC_ALL=C.UTF-8
    elif locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
        export LC_ALL=en_US.UTF-8
    fi
fi

# HY2M_CONFIG / HY2M_DATA_DIR / HY2M_WEBROOT позволяют запустить менеджер и его
# инструменты (webapi/dispatch.sh, тесты) на фикстурном наборе данных, не трогая
# боевые файлы. В обычной работе env не заданы — пути прежние.
CONFIG="${HY2M_CONFIG:-/etc/hysteria/config.yaml}"
SERVICE="hysteria-server.service"
DATA_DIR="${HY2M_DATA_DIR:-/etc/hysteria/manager}"
STATS_FILE="$DATA_DIR/stats.dat"
IPS_FILE="$DATA_DIR/ips.dat"
EXPIRY_FILE="$DATA_DIR/expiry.dat"
# Когда срок действия юзера был выставлен (user|unixts) — для разрешения
# конфликтов при синхронизации срока по кластеру: «последнее изменение выигрывает».
EXPIRY_TS_FILE="$DATA_DIR/expiry_ts.dat"
DISABLED_FILE="$DATA_DIR/disabled.dat"
LAST_LOG_TS="$DATA_DIR/last_log_ts"
API_SECRET_FILE="$DATA_DIR/api_secret"
# Текущая скорость (B/s) за последний интервал сбора и метка времени этого интервала
SPEED_FILE="$DATA_DIR/speed.dat"
SPEED_TS_FILE="$DATA_DIR/speed_ts"
# Учёт АКТИВНОГО трафика для жёсткой проверки (см. collect_activity в traffic.sh).
# ACTIVITY_FILE «user|active|active_since|rate»: активен ли юзер на ЭТОЙ ноде
# ПРЯМО СЕЙЧАС (скорость за последнюю минуту ≥ порога — реальное использование,
# а не пинг/keepalive) и с какого момента идёт активная серия (active_since — по
# нему выбираем «первую» активную ноду). ACTIVITY_PREV_FILE «user|cum|ts» —
# прошлый снимок кумулятивного трафика (для расчёта скорости за минуту).
ACTIVITY_FILE="$DATA_DIR/activity.dat"
ACTIVITY_PREV_FILE="$DATA_DIR/activity_prev.dat"
# Спидометр мини-аппа: «скорость прямо сейчас» отдельно от минутного
# collect_activity. RATES_FILE «user|bps|ts» пересчитывается таймером каждые
# RATES_TICK_SEC секунд и публикуется пирам (см. collect_rates в traffic.sh).
# RATES_PREV_FILE «user|cum|ts» — прошлый снимок кумулятива для дельты.
RATES_FILE="$DATA_DIR/rates.dat"
RATES_PREV_FILE="$DATA_DIR/rates_prev.dat"
# Каденс тика. 15 с ≈ 3% ядра на ноде (доминируют вызовы API протоколов, а не
# число юзеров — тик идёт одним проходом awk, без grep на каждого). Увеличьте,
# если нода тесная: спидометр сгладит разницу.
RATES_TICK_SEC="${RATES_TICK_SEC:-15}"
# Порог «активного» трафика (байт/сек, усреднённо за последнюю минуту). Всё, что
# НИЖЕ порога, считаем фоном (пинги/keepalive/health-check) и НЕ обрезаем жёсткой
# проверкой. 4096 B/s ≈ 240 KiB за минуту — этого не набрать пингами, но легко
# набирает реальный сёрфинг/стриминг. Тюнится через env ACTIVITY_THRESHOLD_BPS.
ACTIVITY_THRESHOLD_BPS="${ACTIVITY_THRESHOLD_BPS:-4096}"
# ---- Анти-абуз: авто-жёсткая проверка по ОДНОВРЕМЕННОМУ активному трафику ----
# Копим «балл абуза» (0..100), когда подписка РЕАЛЬНО используется (скорость за
# минуту ≥ порога) сразу на БОЛЬШЕМ числе нод, чем разрешено устройств. Балл сам
# угасает; при превышении порога на время включается жёсткая проверка. См.
# lib/antiabuse.sh. ABUSE_FILE (синхронизируется по кластеру):
#   «user|score|updated_ts|auto_hc_until|peak_active|viol_minutes».
# ABUSE_OBS_FILE — локальные наблюдения текущего часа (сброс при коррекции):
#   «user|viol_minutes|samples|excess_sum|peak_active|peak_conn».
ABUSE_FILE="$DATA_DIR/abuse.dat"
ABUSE_OBS_FILE="$DATA_DIR/abuse_obs.dat"
# Пороги/веса анти-абуза (тюнятся через env). HIGH — балл, с которого включается
# авто-жёсткая проверка; DECAY_PER_HOUR — на сколько балл угасает за час без
# нарушений; VIOL_WEIGHT/HOURLY_CAP — вклад нарушений за час (макс. за час);
# AUTO_HC_HOURS — на сколько часов взводится авто-жёсткая проверка при превышении.
ABUSE_SCORE_HIGH="${ABUSE_SCORE_HIGH:-60}"
ABUSE_SCORE_LOW="${ABUSE_SCORE_LOW:-25}"
ABUSE_DECAY_PER_HOUR="${ABUSE_DECAY_PER_HOUR:-10}"
ABUSE_VIOL_WEIGHT="${ABUSE_VIOL_WEIGHT:-40}"
ABUSE_HOURLY_CAP="${ABUSE_HOURLY_CAP:-35}"
ABUSE_AUTO_HC_HOURS="${ABUSE_AUTO_HC_HOURS:-6}"
# Маркер «есть изменения конфига, ожидающие перезапуска Hysteria».
# Используется только для правок, которые реально требуют рестарта (порт,
# SNI и т.п.). Управление пользователями работает БЕЗ перезапуска — см. ниже.
RESTART_PENDING_FILE="$DATA_DIR/restart_pending"
# База пользователей для внешней аутентификации (auth.type: command).
# Формат строки: «username:password». Hysteria дергает AUTH_SCRIPT на каждое
# подключение и проверяет пару по этому файлу — поэтому добавление/удаление
# пользователя применяется МГНОВЕННО, без рестарта сервера.
USERS_DB="$DATA_DIR/users.db"
AUTH_SCRIPT="$DATA_DIR/hysteria-auth.sh"

# ====================== ПОДПИСКА / КЛАСТЕР ======================
# Единая подписка: клиент добавляет ссылку https://<домен>/sub/<token>, а нода
# отдаёт base64-список всех ключей hysteria2:// этого юзера со всех серверов
# кластера. Раздаёт статику Caddy (авто-HTTPS), менеджер лишь перегенерирует
# файлы. См. lib/subscription.sh и lib/cluster.sh.
NODE_CONF="$DATA_DIR/node.conf"            # NODE_NAME / NODE_HOST(домен) / WEBROOT
CLUSTER_CONF="$DATA_DIR/cluster.conf"      # реестр пиров: строки «name|host»
CLUSTER_SECRET_FILE="$DATA_DIR/cluster.secret"  # общий секрет кластера (chmod 600)
SUBTOKENS_DB="$DATA_DIR/subtokens.db"      # «user:token» — секрет подписки юзера
CLUSTER_USERS_FILE="$DATA_DIR/cluster_users"    # имена «кластерных» юзеров
# Жизненный цикл кластерного юзера как ТОЧКА ПРАВДЫ (last-write-wins по ts):
# строки «user|state|ts», state ∈ active|disabled|deleted. Нода, на которой
# произошло действие, бампает ts=now и публикует — остальные применяют у себя.
# deleted — это tombstone: не даёт roster/манифесту пира воскресить удалённого.
CLUSTER_STATE_FILE="$DATA_DIR/cluster_state.dat"
# Сбросы ключей по кластеру (тоже LWW по ts): строки «user|ts». Пароль у юзера
# на каждой ноде СВОЙ, поэтому «сбросить всё утёкшее» = попросить все ноды
# прокрутить свой пароль. См. pwreset_mark/cluster_apply_pwreset в lib/cluster.sh.
PWRESET_FILE="$DATA_DIR/cluster_pwreset.dat"
# Бесплатный тариф с лимитами трафика (см. lib/freeplan.sh). Строки:
# «user|state|start|wk_start|wk_base|mo_start|mo_base|notified|ts».
# Файл кластерный (LWW по ts): окна и базы считаются от ОБЩЕГО трафика по всем
# нодам, иначе переключение ноды обнуляло бы израсходованную квоту.
FREEPLAN_FILE="$DATA_DIR/freeplan.dat"
# Демо-профили (см. lib/demo.sh): «user|state|created|expires|cap|base|used».
# Локальные для ЭТОЙ ноды — по кластеру не публикуются (демо принимает одна нода).
DEMOS_DB="$DATA_DIR/demos.db"
WEBROOT="${HY2M_WEBROOT:-/var/www/hy2sub}"  # корень статики Caddy (sub/ и cluster/)
                                            # отдельно от DATA_DIR: его читает caddy, не hysteria
PEERS_DIR="$DATA_DIR/peers"                 # кэш манифестов и онлайна пиров
# --- Обновления менеджера (GitHub) ---
# Единый источник ссылок на репозиторий — меняется только здесь. Проверка версии
# тянет файл VERSION, само обновление запускает install.sh (режим «только менеджер»).
MANAGER_REPO_RAW="${HY2M_REPO_RAW:-https://raw.githubusercontent.com/CABi-Code/Hysteria2-manager/main}"
MANAGER_VERSION_CACHE="$DATA_DIR/.remote_version"   # кэш проверки версии: «ver|ts»
CADDYFILE="/etc/caddy/Caddyfile"
# Чужие вирт-хосты (мини-апп надстройка, редирект основного домена). Менеджер
# их не генерирует и не трогает — только подключает import'ом, чтобы перегенерация
# Caddyfile (setup_caddy) их не стирала.
CADDY_EXTRA_DIR="/etc/caddy/extra"
# Заголовок profile-title для /sub/* — отдельным сниппетом, который Caddyfile
# импортирует. Когда в названии профиля есть плейсхолдеры ({user} и др.), название
# у каждого юзера своё, и сниппет держит map «токен → название». Его перепекает
# regen_subscriptions при изменении состава юзеров/токенов, не трогая Caddyfile.
CADDY_SUBTITLES="/etc/caddy/hy2-sub-titles.conf"
# Лимит одновременных подключений на ОДНУ подписку по ВСЕМУ кластеру (0 = без
# лимита). Не даёт раздать одну подписку на десяток устройств через разные ноды.
# Устар.: значение мигрирует в общекластерную настройку POOL_LIMIT (node.conf),
# см. migrate_device_limit. Файл оставлен для чтения старого значения при апгрейде.
SUB_LIMIT_FILE="$DATA_DIR/device_limit"

# Персональные лимиты пользователя: «user|devices|hardcheck» (devices — кол-во
# устройств, по умолч. 1, приоритетнее глобальных; hardcheck — 0/1, жёсткая
# проверка на этапе аутентификации). Синхронизируются по кластеру LWW-по-ts
# (метки — в USERLIMITS_TS_FILE, «user|ts»), как срок действия. См. lib/limits.sh.
USERLIMITS_FILE="$DATA_DIR/userlimits.dat"
USERLIMITS_TS_FILE="$DATA_DIR/userlimits_ts.dat"
# Снимок для скрипта аутентификации: «user|hardcheck|pool_cap|node_cap|cluster_others».
# Обновляется менеджером (cron --online-sync и после правок). Скрипт auth читает
# его, чтобы отклонять лишние устройства. Права как у users.db (640, владелец — сервис).
AUTHLIMITS_FILE="$DATA_DIR/authlimits.dat"
# Живой маппинг «user|ip|ts» — пишет auth-скрипт на КАЖДОМ подключении (см.
# install_auth_script в lib/migration.sh). По нему klimit_reconcile раскладывает
# активные IP по тарифным классам скорости в реальном времени (см. lib/perf.sh).
# Пишет процесс hysteria (владелец — сервис), читает менеджер (root).
AUTHMAP_FILE="$DATA_DIR/authmap.dat"
# Уникальные IP, скачавшие подписку по КОНКРЕТНОМУ токену. «token|ip|first|last|count».
# Источник — access-лог Caddy, который пишется в stderr → journald (НЕ в файл: файл
# в /var/log/caddy процессу caddy под systemd недоступен и ломает старт Caddy).
# collect_sub_ips читает его через journalctl -u caddy. SUBLOG_TS — метка «since».
SUBIPS_FILE="$DATA_DIR/subips.dat"
SUBLOG_TS="$DATA_DIR/sublog_ts"

API_PORT=25580
PAGE_SIZE=10
# Интервал автообновления интерактивных меню (секунды)
REFRESH_INTERVAL=2

# ====================== ВВОД / ПРОМПТЫ ======================
# ВАЖНО: stderr перенаправлен в лог-файл (см. hy2-manager.sh), поэтому
# обычный `read -p` не годится — его промпт пишется в stderr и ушёл бы
# в лог, оставаясь невидимым для пользователя. Эти хелперы печатают
# промпт в stdout, поэтому он всегда виден.

# ask <имя_переменной> "<промпт>" [таймаут_сек]
# Возвращает код read (важно: при таймауте read -t код != 0 — это
# используется циклами меню как сигнал «обнови экран»).
ask() {
    local __ask_var="$1" __ask_msg="$2" __ask_to="${3:-}"
    printf '%s' "$__ask_msg"
    if [ -n "$__ask_to" ]; then
        read -r -t "$__ask_to" "$__ask_var"
    else
        read -r "$__ask_var"
    fi
}

# pause ["<сообщение>"] — «нажмите Enter», промпт виден в stdout
pause() {
    local __pause_msg="${1:-  Enter для продолжения...}"
    printf '%s' "$__pause_msg"
    read -r _
}

# is_yes <ответ> — подтверждение (принимаем да/yes/y в разных регистрах)
is_yes() {
    case "$1" in
        да|Да|ДА|д|Д|yes|Yes|YES|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

# ====================== ПЕРЕЗАПУСК HYSTERIA ======================
# Перезапуск ненадолго отключает ВСЕХ клиентов, поэтому делаем его явно,
# а не как побочный эффект каждой правки конфига.

mark_restart_pending()  { touch "$RESTART_PENDING_FILE" 2>/dev/null; }
clear_restart_pending() { rm -f "$RESTART_PENDING_FILE" 2>/dev/null; }
is_restart_pending()    { [ -f "$RESTART_PENDING_FILE" ]; }

# Перезапускает сервис Hysteria и снимает маркер ожидающих изменений.
restart_hysteria() {
    echo "  🔄 Перезапуск Hysteria 2 (всех клиентов кратковременно отключит)..."
    systemctl restart "$SERVICE" 2>/dev/null
    sleep 2
    clear_restart_pending
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        echo "  ✅ Hysteria перезапущена, изменения применены"
    else
        echo "  ⚠️  Hysteria НЕ запустилась! journalctl -u $SERVICE -e"
    fi
}

# Помечает изменения как ожидающие и предлагает перезапустить сейчас.
# Вызывается после правок конфига (add/delete/disable/enable/смена пароля).
prompt_apply_restart() {
    mark_restart_pending
    echo ""
    echo "  ⚠️  Изменения вступят в силу только после перезапуска Hysteria."
    local __ans
    ask __ans "  Перезапустить сейчас? (отключит всех на пару секунд) (да/нет): "
    if is_yes "$__ans"; then
        restart_hysteria
    else
        echo "  ⏸  Перезапуск отложен. Применить позже: Настройки → Перезапустить Hysteria."
    fi
}

get_ip() {
    curl -4s --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

get_port() {
    grep -oP '(?<=listen: :)\d+' "$CONFIG" 2>/dev/null || echo "11478"
}

get_obfs_pass() {
    local result
    result=$(grep -oP '(?<=password: ")[^"]+' <(grep -A 5 "salamander:" "$CONFIG") 2>/dev/null | head -1)
    echo "${result:-}"
}

get_sni() {
    local result
    result=$(grep -oP '(?<=url: https://)[^/]+' "$CONFIG" 2>/dev/null | head -1)
    echo "${result:-www.twitch.tv}"
}

# Пароль активного пользователя берём из базы users.db (а не из config.yaml).
get_user_password() {
    awk -F: -v u="$1" '$1==u { print substr($0, length($1)+2); exit }' "$USERS_DB" 2>/dev/null
}

# Активные пользователи = строки users.db (отключённые тут не значатся).
get_active_users() {
    cut -d: -f1 "$USERS_DB" 2>/dev/null | grep -v '^$'
}

# Пары «user|pass» из секции userpass конфига — нужно ТОЛЬКО при разовой
# миграции со старого формата (auth.type: userpass) на users.db.
config_userpass_pairs() {
    awk '
        /^[[:space:]]*userpass:/ { in_block=1; next }
        in_block && /^[[:space:]]+[a-zA-Z0-9_-]+:/ {
            name=$0; sub(/^[[:space:]]+/, "", name); sub(/:.*/, "", name)
            pass=$0; sub(/^[^:]*:[[:space:]]*/, "", pass); gsub(/"/, "", pass); sub(/[[:space:]]+$/, "", pass)
            print name "|" pass
            next
        }
        in_block && /^[[:space:]]*[a-zA-Z]/ && !/^[[:space:]]+[a-zA-Z0-9_-]+:/ { in_block=0 }
        in_block && /^[a-zA-Z]/ { in_block=0 }
    ' "$CONFIG" 2>/dev/null
}

get_all_users() {
    {
        get_active_users
        cut -d'|' -f1 "$DISABLED_FILE" 2>/dev/null
    } | grep -v '^$' | sort -u
}
