#!/bin/sh
# ============================================================
#  TorrServer MatriX — интерактивный установщик для Entware
#  Платформа: Keenetic / KeeneticOS (linux-arm64)
#  Версия:    2.1  (исправлен ввод и отрисовка меню)
# ============================================================

TARGET_SCRIPT="/tmp/install_torrserver.sh"

cat > "$TARGET_SCRIPT" <<'EOF_INSTALL_TORRSERVER'
#!/bin/sh
# ==== основной установщик ====

set -u

REPO="YouROK/TorrServer"
ARCH_ASSET="TorrServer-linux-arm64"

BASE_DIR="/opt/torrserver"
BIN_PATH="$BASE_DIR/TorrServer"
BACKUP_PATH="$BASE_DIR/TorrServer.bak"
DATA_DIR="$BASE_DIR/data"
CONF_PATH="$BASE_DIR/torrserver.conf"
LOG_DIR="$BASE_DIR/log"
WATCHDOG_LOG="$LOG_DIR/torrserver_watchdog.log"

INIT_DIR="/opt/etc/init.d"
INIT_PATH="/opt/etc/init.d/torrserver"

WATCHDOG_INTERVAL_DEFAULT=120
WATCHDOG_INTERVAL_MIN=15
WATCHDOG_INTERVAL_MAX=3600
WATCHDOG_LOG_MAX_BYTES_DEFAULT=2097152
PORT_DEFAULT=8090

INTERRUPTED=0
MENU_CHOICE=""
INPUT_INTERVAL=""

# ---------- цвета ----------
if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
    C_RESET="$(printf '\033[0m')"
    C_TITLE="$(printf '\033[1;36m')"
    C_LABEL="$(printf '\033[1;33m')"
    C_VALUE="$(printf '\033[1;32m')"
    C_MENU="$(printf '\033[1;37m')"
    C_WARN="$(printf '\033[1;31m')"
    C_OK="$(printf '\033[1;32m')"
    C_DIM="$(printf '\033[2;37m')"
    C_BLINK="$(printf '\033[5;33m')"
else
    C_RESET=""; C_TITLE=""; C_LABEL=""; C_VALUE=""; C_MENU=""
    C_WARN=""; C_OK=""; C_DIM=""; C_BLINK=""
fi

on_sigint() {
    echo
    echo "${C_WARN}Операция прервана (Ctrl+C). Возврат в меню...${C_RESET}"
    INTERRUPTED=1
}
trap 'on_sigint' INT

# ---------- пакеты ----------
ensure_pkg() {
    pkg="$1"
    case "$pkg" in
        curl)
            if ! command -v curl >/dev/null 2>&1; then
                opkg update >/dev/null 2>&1 || true
                opkg install curl >/dev/null 2>&1 || true
            fi
            ;;
        ca-certificates)
            if [ ! -f /opt/etc/ssl/certs/ca-certificates.crt ]; then
                opkg update >/dev/null 2>&1 || true
                opkg install ca-certificates >/dev/null 2>&1 || true
            fi
            ;;
        file)
            if ! command -v file >/dev/null 2>&1; then
                opkg update >/dev/null 2>&1 || true
                opkg install file >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

fatal() {
    echo "${C_WARN}✖ $1${C_RESET}"
    exit 1
}

ensure_pkg curl
ensure_pkg ca-certificates
ensure_pkg file

command -v curl >/dev/null 2>&1            || fatal "curl не установлен и не удалось поставить."
command -v start-stop-daemon >/dev/null 2>&1 || fatal "start-stop-daemon не найден. Проверь Entware/busybox."

mkdir -p "$BASE_DIR" "$DATA_DIR" "$INIT_DIR" "$LOG_DIR" "/opt/var/run" 2>/dev/null || fatal "Не могу создать каталоги."

# ---------- curl-фичи ----------
CURL_RETRY_ALL=""
if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
    CURL_RETRY_ALL="--retry-all-errors"
fi

# ---------- конфиг ----------
init_default_conf_if_needed() {
    if [ ! -f "$CONF_PATH" ]; then
        cat > "$CONF_PATH" <<EOF_CONF
# Конфиг TorrServer MatriX для Entware
# Формат: KEY=VALUE, без пробелов вокруг "="
PORT=$PORT_DEFAULT
DATA_DIR=$DATA_DIR
WATCHDOG_INTERVAL=$WATCHDOG_INTERVAL_DEFAULT
WATCHDOG_LOG_MAX_BYTES=$WATCHDOG_LOG_MAX_BYTES_DEFAULT
EOF_CONF
        chmod 600 "$CONF_PATH" 2>/dev/null || true
    fi
}

get_conf_value() {
    key="$1"
    [ -f "$CONF_PATH" ] || { echo ""; return; }
    grep "^${key}=" "$CONF_PATH" 2>/dev/null | head -n1 | cut -d'=' -f2-
}

set_conf_value() {
    key="$1"
    val="$2"
    mkdir -p "$(dirname "$CONF_PATH")" 2>/dev/null || true
    if [ -f "$CONF_PATH" ]; then
        grep -v "^${key}=" "$CONF_PATH" > "$CONF_PATH.tmp" 2>/dev/null || true
        mv "$CONF_PATH.tmp" "$CONF_PATH" 2>/dev/null || true
    fi
    echo "${key}=${val}" >> "$CONF_PATH"
}

get_port() {
    p="$(get_conf_value PORT)"
    echo "${p:-}" | grep -Eq '^[0-9]+$' && echo "$p" || echo "$PORT_DEFAULT"
}

get_data_dir() {
    d="$(get_conf_value DATA_DIR)"
    [ -n "${d:-}" ] && echo "$d" || echo "$DATA_DIR"
}

get_watchdog_interval() {
    v="$(get_conf_value WATCHDOG_INTERVAL)"
    if echo "${v:-}" | grep -Eq '^[0-9]+$'; then
        if [ "$v" -lt "$WATCHDOG_INTERVAL_MIN" ]; then echo "$WATCHDOG_INTERVAL_MIN"
        elif [ "$v" -gt "$WATCHDOG_INTERVAL_MAX" ]; then echo "$WATCHDOG_INTERVAL_MAX"
        else echo "$v"; fi
    else
        echo "$WATCHDOG_INTERVAL_DEFAULT"
    fi
}

get_watchdog_log_max_bytes() {
    v="$(get_conf_value WATCHDOG_LOG_MAX_BYTES)"
    echo "${v:-}" | grep -Eq '^[0-9]+$' && echo "$v" || echo "$WATCHDOG_LOG_MAX_BYTES_DEFAULT"
}

# ---------- версия и статус ----------
get_installed_version() {
    if [ ! -x "$BIN_PATH" ]; then
        echo "не установлен"
        return
    fi
    VER="$(timeout 5 "$BIN_PATH" --version 2>/dev/null | head -n1 || true)"
    if [ -n "${VER:-}" ]; then echo "$VER"; return; fi
    if command -v strings >/dev/null 2>&1; then
        VER="$(strings "$BIN_PATH" 2>/dev/null | grep -m1 '^MatriX\.' || true)"
        [ -n "${VER:-}" ] && { echo "$VER"; return; }
    fi
    echo "установлен (версия неизвестна)"
}

is_torrserver_running() {
    pidof TorrServer >/dev/null 2>&1
}

http_alive() {
    curl -fs --max-time 5 "http://127.0.0.1:$(get_port)/" >/dev/null 2>&1
}

watchdog_pid() {
    [ -f /opt/var/run/torrserver_watchdog.pid ] && cat /opt/var/run/torrserver_watchdog.pid 2>/dev/null
}

auto_start_torrserver_if_needed() {
    [ -x "$BIN_PATH" ] || return 1
    is_torrserver_running && return 0
    if [ -x "$INIT_PATH" ]; then
        "$INIT_PATH" start >/dev/null 2>&1 || true
    else
        PORT_VAL="$(get_port)"
        DATA_DIR_VAL="$(get_data_dir)"
        mkdir -p "$DATA_DIR_VAL" 2>/dev/null || true
        start-stop-daemon -S -b -x "$BIN_PATH" -- -p "$PORT_VAL" -d "$DATA_DIR_VAL" 2>/dev/null || true
    fi
    sleep 3
    is_torrserver_running
}

# ---------- init-скрипт ----------
install_init_script() {
    PORT_VAL="$(get_port)"
    DATA_DIR_VAL="$(get_data_dir)"
    WATCHDOG_INTERVAL_VAL="$(get_watchdog_interval)"
    WATCHDOG_LOG_MAX_BYTES_VAL="$(get_watchdog_log_max_bytes)"

    mkdir -p "$DATA_DIR_VAL" "$LOG_DIR" "/opt/var/run" 2>/dev/null || true

    cat > "$INIT_PATH" <<EOF_INIT
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

ENABLED=yes
PROCS=TorrServer
PROG=$BIN_PATH
PORT=$PORT_VAL
DATA_DIR=$DATA_DIR_VAL
PIDFILE=/opt/var/run/torrserver.pid
WATCHDOG_PIDFILE=/opt/var/run/torrserver_watchdog.pid
WATCHDOG_LOG=$WATCHDOG_LOG
WATCHDOG_LOG_MAX_BYTES=$WATCHDOG_LOG_MAX_BYTES_VAL
WATCHDOG_INTERVAL=$WATCHDOG_INTERVAL_VAL

export GODEBUG=madvdontneed=1
export GOGC=30

is_running() { pidof "\$PROCS" >/dev/null 2>&1; }

http_ok() {
    curl -fs --max-time 5 "http://127.0.0.1:\$PORT/" >/dev/null 2>&1
}

trim_watchdog_log_if_needed() {
    if [ -f "\$WATCHDOG_LOG" ]; then
        size=\$(wc -c < "\$WATCHDOG_LOG" 2>/dev/null || echo 0)
        if [ "\$size" -gt "\$WATCHDOG_LOG_MAX_BYTES" ]; then
            : > "\$WATCHDOG_LOG"
        fi
    fi
}

start_watchdog() {
    if [ -f "\$WATCHDOG_PIDFILE" ] && kill -0 "\$(cat "\$WATCHDOG_PIDFILE" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi
    rm -f "\$WATCHDOG_PIDFILE" 2>/dev/null || true
    (
        while true; do
            sleep "\$WATCHDOG_INTERVAL"
            trim_watchdog_log_if_needed
            if ! is_running; then
                echo "\$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] процесс упал, поднимаю..." >> "\$WATCHDOG_LOG"
                start-stop-daemon -S -b -x "\$PROG" -- -p "\$PORT" -d "\$DATA_DIR" 2>/dev/null || true
                sleep 10
                if is_running; then
                    echo "\$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] поднят." >> "\$WATCHDOG_LOG"
                else
                    echo "\$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] не удалось поднять." >> "\$WATCHDOG_LOG"
                fi
            elif ! http_ok; then
                echo "\$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] HTTP не отвечает, перезапуск..." >> "\$WATCHDOG_LOG"
                killall "\$PROCS" 2>/dev/null || true
                sleep 3
                start-stop-daemon -S -b -x "\$PROG" -- -p "\$PORT" -d "\$DATA_DIR" 2>/dev/null || true
            fi
        done
    ) &
    echo \$! > "\$WATCHDOG_PIDFILE"
}

stop_watchdog() {
    if [ -f "\$WATCHDOG_PIDFILE" ]; then
        pid=\$(cat "\$WATCHDOG_PIDFILE" 2>/dev/null)
        [ -n "\$pid" ] && kill "\$pid" 2>/dev/null || true
        rm -f "\$WATCHDOG_PIDFILE" 2>/dev/null || true
    fi
}

status_service() {
    if is_running; then
        if http_ok; then
            echo "TorrServer: ● OK  (process + HTTP :\$PORT)"
        else
            echo "TorrServer: ● WARN (процесс жив, HTTP :\$PORT не отвечает)"
        fi
    else
        echo "TorrServer: ● DOWN"
    fi
    wp=\$(cat "\$WATCHDOG_PIDFILE" 2>/dev/null || echo "")
    if [ -n "\$wp" ] && kill -0 "\$wp" 2>/dev/null; then
        echo "Watchdog:   ● активен (PID \$wp, интервал \${WATCHDOG_INTERVAL}s)"
    else
        echo "Watchdog:   ● не активен"
    fi
}

start() {
    if is_running; then
        echo "TorrServer уже запущен."
    else
        start-stop-daemon -S -b -x "\$PROG" -- -p "\$PORT" -d "\$DATA_DIR"
        sleep 3
    fi
    start_watchdog
}

stop() {
    stop_watchdog
    killall "\$PROCS" 2>/dev/null || true
}

restart() {
    stop
    sleep 2
    start
}

case "\$1" in
    start)   start ;;
    stop)    stop ;;
    restart) restart ;;
    status)  status_service ;;
    *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF_INIT

    chmod +x "$INIT_PATH" 2>/dev/null || fatal "Не могу chmod init-скрипт."
}

# ---------- GitHub ----------
get_latest_tag() {
    curl -fsL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d'"' -f4
}

list_last_releases() {
    curl -fsL "https://api.github.com/repos/$REPO/releases?per_page=20" 2>/dev/null \
        | grep '"tag_name"' | cut -d'"' -f4
}

is_release_asset_available() {
    tag="$1"
    url="https://github.com/$REPO/releases/download/$tag/$ARCH_ASSET"
    curl -fsIL --max-time 15 "$url" >/dev/null 2>&1
}

# ---------- загрузка ----------
download_version() {
    VERSION="$1"
    URL="https://github.com/$REPO/releases/download/$VERSION/$ARCH_ASSET"

    TMP_FILE="$(mktemp /tmp/torrserver.XXXXXX 2>/dev/null)" || fatal "mktemp не сработал."

    FIRST_INSTALL=0
    [ -f "$BIN_PATH" ] || FIRST_INSTALL=1

    if [ -f "$BIN_PATH" ]; then
        echo "${C_LABEL}▸ Создаю бэкап:${C_RESET} $BACKUP_PATH"
        cp -f "$BIN_PATH" "$BACKUP_PATH" 2>/dev/null || {
            echo "${C_WARN}⚠ Не удалось сделать бэкап. Продолжаю без него.${C_RESET}"
            BACKUP_PATH=""
        }
    fi

    echo "${C_LABEL}▸ Скачивание:${C_RESET} $URL"
    echo "${C_DIM}  IPv4, HTTP/1.1, таймаут 10s, ретраи 3${C_RESET}"

    if ! curl -4 --http1.1 \
            --connect-timeout 10 --max-time 600 \
            --retry 3 --retry-delay 3 $CURL_RETRY_ALL \
            -fL --progress-bar "$URL" -o "$TMP_FILE"; then

        if [ -n "$CURL_RETRY_ALL" ]; then
            echo "${C_DIM}  Повтор без --retry-all-errors...${C_RESET}"
            curl -4 --http1.1 \
                --connect-timeout 10 --max-time 600 \
                --retry 3 --retry-delay 3 \
                -fL --progress-bar "$URL" -o "$TMP_FILE" || {
                echo "${C_WARN}✖ Ошибка скачивания.${C_RESET}"
                [ "$FIRST_INSTALL" -eq 0 ] && [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ] && \
                    { echo "${C_LABEL}▸ Восстанавливаю бэкап...${C_RESET}"; cp -f "$BACKUP_PATH" "$BIN_PATH"; }
                rm -f "$TMP_FILE"
                return 1
            }
        else
            echo "${C_WARN}✖ Ошибка скачивания.${C_RESET}"
            [ "$FIRST_INSTALL" -eq 0 ] && [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ] && \
                { echo "${C_LABEL}▸ Восстанавливаю бэкап...${C_RESET}"; cp -f "$BACKUP_PATH" "$BIN_PATH"; }
            rm -f "$TMP_FILE"
            return 1
        fi
    fi

    if command -v file >/dev/null 2>&1; then
        if ! file "$TMP_FILE" 2>/dev/null | grep -qi 'ELF'; then
            echo "${C_WARN}✖ Файл не ELF-бинарник.${C_RESET}"
            [ "$FIRST_INSTALL" -eq 0 ] && [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ] && \
                { echo "${C_LABEL}▸ Восстанавливаю бэкап...${C_RESET}"; cp -f "$BACKUP_PATH" "$BIN_PATH"; }
            rm -f "$TMP_FILE"
            return 1
        fi
    else
        echo "${C_DIM}  file не установлен — пропускаю проверку ELF.${C_RESET}"
    fi

    mv -f "$TMP_FILE" "$BIN_PATH" 2>/dev/null || {
        echo "${C_WARN}✖ Не удалось переместить бинарник.${C_RESET}"
        rm -f "$TMP_FILE"
        return 1
    }
    chmod +x "$BIN_PATH" 2>/dev/null || {
        echo "${C_WARN}✖ chmod не сработал.${C_RESET}"
        return 1
    }

    echo "${C_OK}✔ Версия $VERSION установлена.${C_RESET}"
    return 0
}

rollback() {
    if [ ! -f "$BACKUP_PATH" ]; then
        echo "${C_WARN}✖ Бэкап не найден: $BACKUP_PATH${C_RESET}"
        return 1
    fi
    echo "${C_LABEL}▸ Откат из:${C_RESET} $BACKUP_PATH"
    cp -f "$BACKUP_PATH" "$BIN_PATH" && chmod +x "$BIN_PATH" || {
        echo "${C_WARN}✖ Откат не удался.${C_RESET}"
        return 1
    }
    echo "${C_OK}✔ Откат выполнен.${C_RESET}"
    return 0
}

# ---------- ввод ----------
read_watchdog_interval_from_user() {
    current="$(get_watchdog_interval)"
    echo "Интервал задаётся в СЕКУНДАХ. Примеры: 60, 120, 300."
    printf "Введите период проверки в секундах [%s]: " "$current"
    read -r INPUT_INTERVAL || INPUT_INTERVAL=""
    if [ -z "${INPUT_INTERVAL:-}" ]; then
        INPUT_INTERVAL="$current"
        return
    fi
    if echo "$INPUT_INTERVAL" | grep -Eq '^[0-9]+$'; then
        if [ "$INPUT_INTERVAL" -lt "$WATCHDOG_INTERVAL_MIN" ]; then
            INPUT_INTERVAL="$WATCHDOG_INTERVAL_MIN"
        elif [ "$INPUT_INTERVAL" -gt "$WATCHDOG_INTERVAL_MAX" ]; then
            INPUT_INTERVAL="$WATCHDOG_INTERVAL_MAX"
        fi
    else
        INPUT_INTERVAL="$current"
    fi
}

# ---------- удаление ----------
uninstall_all() {
    echo "${C_WARN}────────────────────────────────────────────${C_RESET}"
    echo "${C_WARN} ВНИМАНИЕ: полное удаление TorrServer      ${C_RESET}"
    echo "${C_WARN} Бинарник, конфиг, логи, init — всё уйдёт. ${C_RESET}"
    echo "${C_WARN}────────────────────────────────────────────${C_RESET}"
    printf "Для подтверждения введите ровно YES: "
    read -r ans
    [ "$ans" = "YES" ] || { echo "Отменено."; return 0; }

    [ -x "$INIT_PATH" ] && "$INIT_PATH" stop >/dev/null 2>&1 || true
    rm -f "$INIT_PATH"
    rm -rf "$BASE_DIR"
    echo "${C_OK}✔ Полное удаление завершено.${C_RESET}"
    return 0
}

# ---------- /help ----------
show_help() {
    clear 2>/dev/null || printf '\033c'
    cat <<HELP_TEXT
${C_TITLE}══════════════════════════════════════════════════════════════
                TorrServer MatriX — помощь /help               
══════════════════════════════════════════════════════════════${C_RESET}

${C_LABEL}Что это:${C_RESET}
  TorrServer — сервер, который качает торренты и отдаёт их как
  HTTP-поток. Ты открываешь в браузере http://<IP-роутера>:8090
  и смотришь видео. Скачивать целиком не нужно.

${C_LABEL}Куда зайти:${C_RESET}
  http://IP_РОУТЕРА:8090
  IP можно узнать командой: ip a | grep 'inet '

${C_LABEL}Пункты меню:${C_RESET}
  ${C_VALUE}1${C_RESET} Установить / обновить до последней стабильной версии.
    Берёт latest release с GitHub, качает бинарник arm64,
    делает бэкап старого, подменяет, перезапускает сервис.

  ${C_VALUE}2${C_RESET} Выбрать из 20 последних релизов.
    Показывает список тегов, для которых есть файл $ARCH_ASSET.
    Введи номер из списка — поставится конкретная версия.

  ${C_VALUE}3${C_RESET} Откатиться на предыдущую версию.
    Возвращает TorrServer.bak на место основного бинарника.

  ${C_VALUE}4${C_RESET} Настроить интервал watchdog (в секундах).
    Минимум $WATCHDOG_INTERVAL_MIN, максимум $WATCHDOG_INTERVAL_MAX.
    После сохранения сервис перезапускается с новым значением.

  ${C_VALUE}5${C_RESET} Показать статус.
    Печатает, жив ли процесс, отвечает ли HTTP, активен ли watchdog,
    и последние 5 строк журнала.

  ${C_VALUE}6${C_RESET} Полное удаление. Требует ввести YES. Необратимо.

  ${C_VALUE}7${C_RESET} Эта справка.

  ${C_VALUE}0${C_RESET} Выход.

${C_LABEL}Файлы:${C_RESET}
  $BIN_PATH            — бинарник TorrServer
  $BACKUP_PATH         — бэкап прошлой версии (для отката)
  $CONF_PATH           — конфиг (порт, data dir, интервал)
  $LOG_DIR/            — журнал watchdog
  $INIT_PATH           — автозапуск при загрузке роутера

${C_LABEL}Из командной строки:${C_RESET}
  $INIT_PATH start      — запустить
  $INIT_PATH stop       — остановить
  $INIT_PATH restart    — перезапустить
  $INIT_PATH status     — статус

${C_LABEL}Частые проблемы:${C_RESET}
  • «Не могу скачать» → проверь интернет роутера, DNS, дату.
  • «Не ELF» → GitHub отдал заглушку/ошибку, попробуй пункт 2.
  • «Порт занят» → смени порт в $CONF_PATH (PORT=...),
    затем пункт 5 → restart.
  • Watchdog не поднимает → проверь лог:
      tail -n 20 $WATCHDOG_LOG
  • Нет доступа к :8090 снаружи → открой порт в настройках
    Keenetic (Межсетевой экран).

${C_LABEL}Безопасность:${C_RESET}
  Порт 8090 — без пароля. Не публикуй его в интернет без прокси.

${C_DIM}Нажми Enter для возврата...${C_RESET}
HELP_TEXT
    read -r _
}

# ---------- меню ----------
draw_status_box() {
    CUR_VER="$(get_installed_version)"
    CUR_PORT="$(get_port)"

    if [ "$CUR_VER" = "не установлен" ]; then
        VER_LINE="${C_WARN}● не установлен${C_RESET}"
    elif is_torrserver_running; then
        VER_LINE="${C_OK}● работает${C_RESET}  ($CUR_VER)"
    else
        if auto_start_torrserver_if_needed; then
            VER_LINE="${C_OK}● поднят автоматически${C_RESET}  ($CUR_VER)"
        else
            VER_LINE="${C_WARN}● не работает${C_RESET}  ($CUR_VER)"
        fi
    fi

    if http_alive; then HTTP_LINE="${C_OK}● :$CUR_PORT отвечает${C_RESET}"
    else               HTTP_LINE="${C_WARN}● :$CUR_PORT нет ответа${C_RESET}"; fi

    wp="$(watchdog_pid)"
    if [ -n "${wp:-}" ] && kill -0 "$wp" 2>/dev/null; then
        WD_LINE="${C_OK}● PID $wp, интервал $(get_watchdog_interval)s${C_RESET}"
    else
        WD_LINE="${C_WARN}● не активен${C_RESET}"
    fi

    echo "${C_DIM}──── Состояние ────${C_RESET}"
    echo " ${C_LABEL}TorrServer:${C_RESET} $VER_LINE"
    echo " ${C_LABEL}HTTP:${C_RESET}       $HTTP_LINE"
    echo " ${C_LABEL}Watchdog:${C_RESET}   $WD_LINE"
    echo "${C_DIM}───────────────────${C_RESET}"
}

draw_params_box() {
    CUR_DATA="$(get_data_dir)"
    CUR_INT="$(get_watchdog_interval)"
    CUR_LOG_MAX="$(get_watchdog_log_max_bytes)"
    echo "${C_DIM}──── Параметры ────${C_RESET}"
    echo " ${C_LABEL}Каталог:${C_RESET} $BASE_DIR"
    echo " ${C_LABEL}Данные:${C_RESET}  $CUR_DATA"
    echo " ${C_LABEL}Init:${C_RESET}    $INIT_PATH"
    echo " ${C_LABEL}Конфиг:${C_RESET}  $CONF_PATH"
    echo " ${C_LABEL}Лог:${C_RESET}     max $CUR_LOG_MAX байт"
    echo "${C_DIM}───────────────────${C_RESET}"
}

menu_screen() {
    clear 2>/dev/null || printf '\033c'
    init_default_conf_if_needed

    echo
    echo "${C_TITLE}══════════════════════════════════════════════════════════════"
    echo "  TorrServer MatriX  ·  Entware  ·  linux-arm64"
    echo "══════════════════════════════════════════════════════════════${C_RESET}"
    echo
    draw_status_box
    echo
    draw_params_box
    echo
    echo "${C_MENU}──── Меню ────${C_RESET}"
    echo "  1) Установить / обновить до последней версии"
    echo "  2) Выбрать из 20 последних релизов"
    echo "  3) Откатиться на предыдущую версию (бэкап)"
    echo "  4) Настроить интервал watchdog"
    echo "  5) Показать статус"
    echo "  6) Полное удаление"
    echo "  7) Помощь (/help)"
    echo "  0) Выход"
    echo "${C_MENU}──────────────${C_RESET}"
    echo
}

ask_choice() {
    while :; do
        printf "Выбор [0–7] или 'help': "
        read -r MENU_CHOICE || MENU_CHOICE=""
        case "$MENU_CHOICE" in
            0|1|2|3|4|5|6|7) return 0 ;;
            help|/help|h|H|\?) MENU_CHOICE="7"; return 0 ;;
            *) echo "${C_WARN}Неверный выбор. Введи 0–7 или 'help'.${C_RESET}" ;;
        esac
    done
}

# ---------- главный цикл ----------
main_menu() {
    while true; do
        menu_screen
        ask_choice
        choice="$MENU_CHOICE"
        
        case "$choice" in
            0) exit 0 ;;
            1)
                INTERRUPTED=0
                VERSION="$(get_latest_tag)"
                [ "$INTERRUPTED" -eq 1 ] && { INTERRUPTED=0; continue; }
                if [ -z "${VERSION:-}" ]; then
                    echo "${C_WARN}✖ Не удалось получить latest release.${C_RESET}"
                    printf "Enter..."; read -r _; continue
                fi
                echo "${C_LABEL}▸ Latest:${C_RESET} $VERSION"
                if ! download_version "$VERSION"; then
                    printf "Enter..."; read -r _; continue
                fi
                install_init_script
                "$INIT_PATH" restart
                printf "Enter..."; read -r _
                ;;
            2)
                INTERRUPTED=0
                echo "${C_LABEL}▸ Получаю список релизов...${C_RESET}"
                TAGS_RAW="$(list_last_releases)"
                [ "$INTERRUPTED" -eq 1 ] && { INTERRUPTED=0; continue; }
                if [ -z "${TAGS_RAW:-}" ]; then
                    echo "${C_WARN}✖ GitHub API недоступен (или rate-limit).${C_RESET}"
                    printf "Enter..."; read -r _; continue
                fi
                echo "${C_LABEL}▸ Проверяю наличие $ARCH_ASSET...${C_RESET}"
                AVAILABLE_TAGS=""
                while IFS= read -r tag; do
                    [ -z "$tag" ] && continue
                    if is_release_asset_available "$tag"; then
                        if [ -z "$AVAILABLE_TAGS" ]; then AVAILABLE_TAGS="$tag"
                        else AVAILABLE_TAGS="$AVAILABLE_TAGS
$tag"; fi
                    fi
                done <<EOF_TAGS
$TAGS_RAW
EOF_TAGS
                if [ -z "${AVAILABLE_TAGS:-}" ]; then
                    echo "${C_WARN}✖ Нет релизов с ассетом $ARCH_ASSET.${C_RESET}"
                    printf "Enter..."; read -r _; continue
                fi
                echo
                i=1
                echo "$AVAILABLE_TAGS" | while read -r tag; do
                    [ -z "$tag" ] && continue
                    printf "  %2d) %s\n" "$i" "$tag"
                    i=$((i+1))
                done
                echo
                printf "Номер релиза (0 — назад): "
                read -r num || num="0"
                [ "$num" = "0" ] && continue
                if ! echo "$num" | grep -Eq '^[0-9]+$'; then
                    echo "${C_WARN}✖ Неверный ввод.${C_RESET}"
                    printf "Enter..."; read -r _; continue
                fi
                SELECTED_TAG="$(echo "$AVAILABLE_TAGS" | sed -n "${num}p")"
                if [ -z "${SELECTED_TAG:-}" ]; then
                    echo "${C_WARN}✖ Нет такого номера.${C_RESET}"
                    printf "Enter..."; read -r _; continue
                fi
                echo "${C_LABEL}▸ Выбрано:${C_RESET} $SELECTED_TAG"
                if ! download_version "$SELECTED_TAG"; then
                    printf "Enter..."; read -r _; continue
                fi
                install_init_script
                "$INIT_PATH" restart
                printf "Enter..."; read -r _
                ;;
            3)
                if rollback; then
                    install_init_script
                    "$INIT_PATH" restart
                fi
                printf "Enter..."; read -r _
                ;;
            4)
                read_watchdog_interval_from_user
                set_conf_value WATCHDOG_INTERVAL "$INPUT_INTERVAL"
                install_init_script
                echo "${C_OK}✔ Интервал сохранён: ${INPUT_INTERVAL}s. Перезапускаю сервис...${C_RESET}"
                "$INIT_PATH" restart
                printf "Enter..."; read -r _
                ;;
            5)
                if [ -x "$INIT_PATH" ]; then
                    "$INIT_PATH" status
                    if [ -f "$WATCHDOG_LOG" ]; then
                        echo
                        echo "${C_DIM}── последние 5 строк watchdog ──${C_RESET}"
                        tail -n 5 "$WATCHDOG_LOG"
                    fi
                else
                    echo "${C_WARN}✖ Init-скрипт не найден.${C_RESET}"
                fi
                printf "Enter..."; read -r _
                ;;
            6)
                uninstall_all && { printf "Enter..."; read -r _; exit 0; }
                printf "Enter..."; read -r _
                ;;
            7)
                show_help
                ;;
        esac
    done
}

main_menu
EOF_INSTALL_TORRSERVER

chmod +x "$TARGET_SCRIPT" || { echo "Не могу сделать $TARGET_SCRIPT исполняемым"; exit 1; }
echo "Скрипт сохранён: $TARGET_SCRIPT"
echo "Запуск установщика..."
exec "$TARGET_SCRIPT"
