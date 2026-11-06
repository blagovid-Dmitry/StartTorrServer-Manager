#!/bin/sh
# ============================================================
#  TorrServer MatriX — интерактивный установщик для Entware
#  Версия: 3.1 (белые команды в таблице)
# ============================================================

TARGET_SCRIPT="/opt/torrserver/menu.sh"

mkdir -p /opt/torrserver /opt/bin

cat > "$TARGET_SCRIPT" <<'EOF_INSTALL_TORRSERVER'
#!/bin/sh

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
else
    C_RESET=""; C_TITLE=""; C_LABEL=""; C_VALUE=""; C_MENU=""
    C_WARN=""; C_OK=""; C_DIM=""
fi

on_sigint() {
    echo
    echo "${C_WARN}Операция прервана (Ctrl+C). Возврат в меню...${C_RESET}"
    INTERRUPTED=1
}
trap 'on_sigint' INT

# ---------- функции ввода ----------
wait_enter() {
    echo
    local i=3
    while [ "$i" -gt 0 ]; do
        printf "\r\033[K${C_DIM}Возврат в меню через %s... (Enter - пропустить)${C_RESET}" "$i"
        key=""
        if read -t 1 -r key 2>/dev/null; then
            if [ -z "$key" ]; then
                echo
                return
            fi
        fi
        i=$((i-1))
    done
    echo
}

ask_choice() {
    while :; do
        printf "Выбор [0–7] или 'help': "
        read -r MENU_CHOICE || MENU_CHOICE=""
        
        if [ -z "$MENU_CHOICE" ]; then
            printf "\033[A\r\033[K"
        else
            case "$MENU_CHOICE" in
                0|1|2|3|4|5|6|7) return 0 ;;
                help|/help|h|H|\?) MENU_CHOICE="7"; return 0 ;;
                *) echo "${C_WARN}Неверный выбор. Введи 0–7 или 'help'.${C_RESET}" ;;
            esac
        fi
    done
}

# ---------- пакеты ----------
ensure_pkg() {
    pkg="$1"
    case "$pkg" in
        curl) command -v curl >/dev/null 2>&1 || { opkg update >/dev/null 2>&1 || true; opkg install curl >/dev/null 2>&1 || true; } ;;
        ca-certificates) [ -f /opt/etc/ssl/certs/ca-certificates.crt ] || { opkg update >/dev/null 2>&1 || true; opkg install ca-certificates >/dev/null 2>&1 || true; } ;;
        file) command -v file >/dev/null 2>&1 || { opkg update >/dev/null 2>&1 || true; opkg install file >/dev/null 2>&1 || true; } ;;
    esac
}

fatal() { echo "${C_WARN}✖ $1${C_RESET}"; exit 1; }

ensure_pkg curl
ensure_pkg ca-certificates
ensure_pkg file

command -v curl >/dev/null 2>&1            || fatal "curl не установлен."
command -v start-stop-daemon >/dev/null 2>&1 || fatal "start-stop-daemon не найден."

mkdir -p "$BASE_DIR" "$DATA_DIR" "$INIT_DIR" "$LOG_DIR" "/opt/var/run" 2>/dev/null || fatal "Ошибка каталогов."

CURL_RETRY_ALL=""
if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then CURL_RETRY_ALL="--retry-all-errors"; fi

# ---------- конфиг ----------
init_default_conf_if_needed() {
    if [ ! -f "$CONF_PATH" ]; then
        cat > "$CONF_PATH" <<EOF_CONF
PORT=$PORT_DEFAULT
DATA_DIR=$DATA_DIR
WATCHDOG_INTERVAL=$WATCHDOG_INTERVAL_DEFAULT
WATCHDOG_LOG_MAX_BYTES=$WATCHDOG_LOG_MAX_BYTES_DEFAULT
EOF_CONF
        chmod 600 "$CONF_PATH" 2>/dev/null || true
    fi
}

get_conf_value() { [ -f "$CONF_PATH" ] && grep "^${1}=" "$CONF_PATH" 2>/dev/null | head -n1 | cut -d'=' -f2- || echo ""; }
set_conf_value() {
    mkdir -p "$(dirname "$CONF_PATH")" 2>/dev/null || true
    [ -f "$CONF_PATH" ] && grep -v "^${1}=" "$CONF_PATH" > "$CONF_PATH.tmp" 2>/dev/null || true
    [ -f "$CONF_PATH.tmp" ] && mv "$CONF_PATH.tmp" "$CONF_PATH" 2>/dev/null || true
    echo "${1}=${2}" >> "$CONF_PATH"
}

get_port() { p="$(get_conf_value PORT)"; echo "${p:-}" | grep -Eq '^[0-9]+$' && echo "$p" || echo "$PORT_DEFAULT"; }
get_data_dir() { d="$(get_conf_value DATA_DIR)"; [ -n "${d:-}" ] && echo "$d" || echo "$DATA_DIR"; }
get_watchdog_interval() {
    v="$(get_conf_value WATCHDOG_INTERVAL)"
    if echo "${v:-}" | grep -Eq '^[0-9]+$'; then
        [ "$v" -lt "$WATCHDOG_INTERVAL_MIN" ] && echo "$WATCHDOG_INTERVAL_MIN" && return
        [ "$v" -gt "$WATCHDOG_INTERVAL_MAX" ] && echo "$WATCHDOG_INTERVAL_MAX" && return
        echo "$v"
    else echo "$WATCHDOG_INTERVAL_DEFAULT"; fi
}
get_watchdog_log_max_bytes() { v="$(get_conf_value WATCHDOG_LOG_MAX_BYTES)"; echo "${v:-}" | grep -Eq '^[0-9]+$' && echo "$v" || echo "$WATCHDOG_LOG_MAX_BYTES_DEFAULT"; }

# ---------- версия и статус ----------
get_installed_version() {
    [ ! -x "$BIN_PATH" ] && echo "не установлен" && return
    VER="$(timeout 5 "$BIN_PATH" --version 2>/dev/null | head -n1 || true)"
    [ -n "${VER:-}" ] && echo "$VER" && return
    command -v strings >/dev/null 2>&1 && VER="$(strings "$BIN_PATH" 2>/dev/null | grep -m1 '^MatriX\.' || true)"
    [ -n "${VER:-}" ] && echo "$VER" || echo "установлен (версия неизвестна)"
}

is_torrserver_running() { pidof TorrServer >/dev/null 2>&1; }
http_alive() { curl -fs --max-time 5 "http://127.0.0.1:$(get_port)/" >/dev/null 2>&1; }
watchdog_pid() { [ -f /opt/var/run/torrserver_watchdog.pid ] && cat /opt/var/run/torrserver_watchdog.pid 2>/dev/null; }

auto_start_torrserver_if_needed() {
    [ ! -x "$BIN_PATH" ] && return 1
    is_torrserver_running && return 0
    if [ -x "$INIT_PATH" ]; then "$INIT_PATH" start >/dev/null 2>&1 || true
    else
        start-stop-daemon -S -b -x "$BIN_PATH" -- -p "$(get_port)" -d "$(get_data_dir)" 2>/dev/null || true
    fi
    sleep 3
    is_torrserver_running
}

# ---------- установка ----------
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
http_ok() { curl -fs --max-time 5 "http://127.0.0.1:\$PORT/" >/dev/null 2>&1; }

trim_watchdog_log_if_needed() {
    [ -f "\$WATCHDOG_LOG" ] || return
    size=\$(wc -c < "\$WATCHDOG_LOG" 2>/dev/null || echo 0)
    [ "\$size" -gt "\$WATCHDOG_LOG_MAX_BYTES" ] && : > "\$WATCHDOG_LOG"
}

start_watchdog() {
    if [ -f "\$WATCHDOG_PIDFILE" ] && kill -0 "\$(cat "\$WATCHDOG_PIDFILE" 2>/dev/null)" 2>/dev/null; then return 0; fi
    rm -f "\$WATCHDOG_PIDFILE" 2>/dev/null || true
    (
        while true; do
            sleep "\$WATCHDOG_INTERVAL"
            trim_watchdog_log_if_needed
            if ! is_running; then
                echo "\$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] процесс упал, поднимаю..." >> "\$WATCHDOG_LOG"
                start-stop-daemon -S -b -x "\$PROG" -- -p "\$PORT" -d "\$DATA_DIR" 2>/dev/null || true
                sleep 10
                is_running && echo "\$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] поднят." >> "\$WATCHDOG_LOG" || echo "\$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] не удалось поднять." >> "\$WATCHDOG_LOG"
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
        http_ok && echo "TorrServer: ● OK  (process + HTTP :\$PORT)" || echo "TorrServer: ● WARN (процесс жив, HTTP :\$PORT нет)"
    else echo "TorrServer: ● DOWN"; fi
    wp=\$(cat "\$WATCHDOG_PIDFILE" 2>/dev/null || echo "")
    [ -n "\$wp" ] && kill -0 "\$wp" 2>/dev/null && echo "Watchdog:   ● активен (PID \$wp, интервал \${WATCHDOG_INTERVAL}s)" || echo "Watchdog:   ● не активен"
}

start() {
    if ! is_running; then
        start-stop-daemon -S -b -x "\$PROG" -- -p "\$PORT" -d "\$DATA_DIR"
        sleep 3
    fi
    start_watchdog
}
stop() { stop_watchdog; killall "\$PROCS" 2>/dev/null || true; }
restart() { stop; sleep 2; start; }

case "\$1" in
    start) start ;; stop) stop ;; restart) restart ;; status) status_service ;;
    *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF_INIT

    chmod +x "$INIT_PATH" 2>/dev/null || fatal "Ошибка chmod."
}

# ---------- GitHub ----------
get_latest_tag() { curl -fsL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | cut -d'"' -f4; }
list_last_releases() { curl -fsL "https://api.github.com/repos/$REPO/releases?per_page=20" 2>/dev/null | grep '"tag_name"' | cut -d'"' -f4; }
is_release_asset_available() { curl -fsIL --max-time 15 "https://github.com/$REPO/releases/download/$1/$ARCH_ASSET" >/dev/null 2>&1; }

download_version() {
    VERSION="$1"
    URL="https://github.com/$REPO/releases/download/$VERSION/$ARCH_ASSET"
    TMP_FILE="$(mktemp /tmp/torrserver.XXXXXX 2>/dev/null)" || fatal "Ошибка mktemp."

    FIRST_INSTALL=0; [ -f "$BIN_PATH" ] || FIRST_INSTALL=1
    if [ -f "$BIN_PATH" ]; then
        echo "${C_LABEL}▸ Бэкап:${C_RESET} $BACKUP_PATH"
        cp -f "$BIN_PATH" "$BACKUP_PATH" 2>/dev/null || { echo "${C_WARN}⚠ Без бэкапа.${C_RESET}"; BACKUP_PATH=""; }
    fi

    echo "${C_LABEL}▸ Скачивание:${C_RESET} $URL"
    if ! curl -4 --http1.1 --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 3 $CURL_RETRY_ALL -fL --progress-bar "$URL" -o "$TMP_FILE"; then
        if [ -n "$CURL_RETRY_ALL" ]; then
            curl -4 --http1.1 --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 3 -fL --progress-bar "$URL" -o "$TMP_FILE" || {
                printf "\033[K\n"; echo "${C_WARN}✖ Ошибка скачивания.${C_RESET}"
                [ "$FIRST_INSTALL" -eq 0 ] && [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ] && cp -f "$BACKUP_PATH" "$BIN_PATH"
                rm -f "$TMP_FILE"; return 1
            }
        else
            printf "\033[K\n"; echo "${C_WARN}✖ Ошибка скачивания.${C_RESET}"
            [ "$FIRST_INSTALL" -eq 0 ] && [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ] && cp -f "$BACKUP_PATH" "$BIN_PATH"
            rm -f "$TMP_FILE"; return 1
        fi
    fi
    printf "\033[K\n"

    if command -v file >/dev/null 2>&1 && ! file "$TMP_FILE" 2>/dev/null | grep -qi 'ELF'; then
        echo "${C_WARN}✖ Не ELF-бинарник.${C_RESET}"
        [ "$FIRST_INSTALL" -eq 0 ] && [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ] && cp -f "$BACKUP_PATH" "$BIN_PATH"
        rm -f "$TMP_FILE"; return 1
    fi

    mv -f "$TMP_FILE" "$BIN_PATH" 2>/dev/null && chmod +x "$BIN_PATH" 2>/dev/null || {
        echo "${C_WARN}✖ Ошибка установки файла.${C_RESET}"; rm -f "$TMP_FILE"; return 1; }
    echo "${C_OK}✔ Версия $VERSION установлена.${C_RESET}"; return 0
}

rollback() {
    [ ! -f "$BACKUP_PATH" ] && echo "${C_WARN}✖ Бэкап не найден.${C_RESET}" && return 1
    echo "${C_LABEL}▸ Откат:${C_RESET} $BACKUP_PATH"
    cp -f "$BACKUP_PATH" "$BIN_PATH" && chmod +x "$BIN_PATH" || { echo "${C_WARN}✖ Ошибка.${C_RESET}"; return 1; }
    echo "${C_OK}✔ Откат выполнен.${C_RESET}"; return 0
}

read_watchdog_interval_from_user() {
    current="$(get_watchdog_interval)"
    echo "Интервал в СЕКУНДАХ. Примеры: 60, 120, 300."
    printf "Введите период [%s]: " "$current"
    read -r INPUT_INTERVAL || INPUT_INTERVAL=""
    [ -z "${INPUT_INTERVAL:-}" ] && INPUT_INTERVAL="$current" && return
    if echo "$INPUT_INTERVAL" | grep -Eq '^[0-9]+$'; then
        [ "$INPUT_INTERVAL" -lt "$WATCHDOG_INTERVAL_MIN" ] && INPUT_INTERVAL="$WATCHDOG_INTERVAL_MIN"
        [ "$INPUT_INTERVAL" -gt "$WATCHDOG_INTERVAL_MAX" ] && INPUT_INTERVAL="$WATCHDOG_INTERVAL_MAX"
    else INPUT_INTERVAL="$current"; fi
}

uninstall_all() {
    echo "${C_WARN}────────────────────────────────────────────${C_RESET}"
    echo "${C_WARN} ВНИМАНИЕ: полное удаление TorrServer      ${C_RESET}"
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

show_help() {
    clear 2>/dev/null || printf '\033c'
    ALL_IPS=$(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | grep -v '127.0.0.1')
    [ -z "$ALL_IPS" ] && ALL_IPS="192.168.1.1"

    cat <<HELP_TEXT
${C_TITLE}══════════════════════════════════════════════════════════════
                TorrServer MatriX — помощь
══════════════════════════════════════════════════════════════${C_RESET}

${C_LABEL}Что это:${C_RESET}
  Сервер качает торренты и отдаёт их как HTTP-поток.

${C_LABEL}Пример адреса для входа:${C_RESET}
  http://192.168.1.1:8090
  (где 192.168.1.1 — это IP вашего роутера, а 8090 — порт)

${C_LABEL}Ваши доступные IP-адреса:${C_RESET}
HELP_TEXT

    echo "$ALL_IPS" | while read -r ip; do
        [ -n "$ip" ] && echo "  ${C_OK}●${C_RESET} http://$ip:8090"
    done

    cat <<HELP_TEXT

${C_LABEL}Системные команды:${C_RESET}
  Вводятся в консоли (SSH) без запуска меню.

  ${C_DIM}┌────────────────────┬────────────────────────────────────────┐${C_RESET}
  ${C_DIM}│${C_MENU} Команда            ${C_DIM}│${C_MENU} Описание                               ${C_DIM}│${C_RESET}
  ${C_DIM}├────────────────────┼────────────────────────────────────────┤${C_RESET}
  ${C_DIM}│${C_RESET} ${C_MENU}torrserver start${C_RESET}   ${C_DIM}│${C_RESET} Запустить сервер и watchdog            ${C_DIM}│${C_RESET}
  ${C_DIM}│${C_RESET} ${C_MENU}torrserver stop${C_RESET}    ${C_DIM}│${C_RESET} Остановить сервер и watchdog           ${C_DIM}│${C_RESET}
  ${C_DIM}│${C_RESET} ${C_MENU}torrserver restart${C_RESET} ${C_DIM}│${C_RESET} Перезапустить сервер (stop + start)    ${C_DIM}│${C_RESET}
  ${C_DIM}│${C_RESET} ${C_MENU}torrserver status${C_RESET}  ${C_DIM}│${C_RESET} Показать статус (Process + HTTP)       ${C_DIM}│${C_RESET}
  ${C_DIM}│${C_RESET} ${C_MENU}torrservmng${C_RESET}        ${C_DIM}│${C_RESET} Открыть это интерактивное меню         ${C_DIM}│${C_RESET}
  ${C_DIM}└────────────────────┴────────────────────────────────────────┘${C_RESET}

${C_LABEL}Проблемы:${C_RESET}
  • Не качает: проверь интернет/DNS/дату.
  • Порт занят: смени PORT= в $CONF_PATH
  • Watchdog: tail -n 20 $WATCHDOG_LOG
  • Безопасность: порт 8090 без пароля, не свети в интернет.
HELP_TEXT
    printf "${C_DIM}Нажми Enter для возврата...${C_RESET}"
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
        auto_start_torrserver_if_needed && VER_LINE="${C_OK}● поднят авто${C_RESET} ($CUR_VER)" || VER_LINE="${C_WARN}● не работает${C_RESET} ($CUR_VER)"
    fi

    http_alive && HTTP_LINE="${C_OK}● :$CUR_PORT отвечает${C_RESET}" || HTTP_LINE="${C_WARN}● :$CUR_PORT нет ответа${C_RESET}"
    wp="$(watchdog_pid)"
    [ -n "${wp:-}" ] && kill -0 "$wp" 2>/dev/null && WD_LINE="${C_OK}● PID $wp, интервал $(get_watchdog_interval)s${C_RESET}" || WD_LINE="${C_WARN}● не активен${C_RESET}"

    echo "${C_DIM}──── Состояние ────${C_RESET}"
    echo " ${C_LABEL}TorrServer:${C_RESET} $VER_LINE"
    echo " ${C_LABEL}HTTP:${C_RESET}       $HTTP_LINE"
    echo " ${C_LABEL}Watchdog:${C_RESET}   $WD_LINE"
    echo "${C_DIM}───────────────────${C_RESET}"
}

draw_params_box() {
    echo "${C_DIM}──── Параметры ────${C_RESET}"
    echo " ${C_LABEL}Каталог:${C_RESET} $BASE_DIR"
    echo " ${C_LABEL}Данные:${C_RESET}  $(get_data_dir)"
    echo " ${C_LABEL}Init:${C_RESET}    $INIT_PATH"
    echo " ${C_LABEL}Конфиг:${C_RESET}  $CONF_PATH"
    echo " ${C_LABEL}Лог:${C_RESET}     max $(get_watchdog_log_max_bytes) байт"
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
    echo "  7) Помощь"
    echo "  0) Выход"
    echo "${C_MENU}──────────────${C_RESET}"
    echo
}

main_menu() {
    while true; do
        menu_screen
        ask_choice
        choice="$MENU_CHOICE"

        if [ ! -x "$BIN_PATH" ] && { [ "$choice" = "4" ] || [ "$choice" = "5" ]; }; then
            echo "${C_WARN}✖ TorrServer не установлен.${C_RESET}"
            sleep 2
            continue
        fi

        case "$choice" in
            0) 
                printf "Выйти в консоль? [Enter=Да, 0=Нет]: "
                read -r ans
                [ "$ans" = "0" ] && continue
                exit 0 
                ;;
            1)
                INTERRUPTED=0
                VERSION="$(get_latest_tag)"
                [ "$INTERRUPTED" -eq 1 ] && { INTERRUPTED=0; continue; }
                if [ -z "${VERSION:-}" ]; then echo "${C_WARN}✖ Нет связи с GitHub.${C_RESET}"; wait_enter; continue; fi
                
                CUR_VER="$(get_installed_version)"
                case "$CUR_VER" in
                    *"$VERSION"*)
                        echo "${C_OK}✔ Версия $VERSION уже установлена.${C_RESET}"
                        printf "Переустановить? [Enter=Да, 0=Нет]: "
                        read -r ans
                        [ "$ans" = "0" ] && continue
                        ;;
                esac

                echo "${C_LABEL}▸ Latest:${C_RESET} $VERSION"
                if ! download_version "$VERSION"; then wait_enter; continue; fi
                install_init_script
                "$INIT_PATH" restart
                wait_enter
                ;;
            2)
                INTERRUPTED=0
                echo "${C_LABEL}▸ Загрузка списка...${C_RESET}"
                TAGS_RAW="$(list_last_releases)"
                [ "$INTERRUPTED" -eq 1 ] && { INTERRUPTED=0; continue; }
                [ -z "${TAGS_RAW:-}" ] && { echo "${C_WARN}✖ GitHub API недоступен.${C_RESET}"; wait_enter; continue; }
                
                echo "${C_LABEL}▸ Проверка доступности...${C_RESET}"
                AVAILABLE_TAGS=""
                while IFS= read -r tag; do
                    [ -z "$tag" ] && continue
                    is_release_asset_available "$tag" && {
                        [ -z "$AVAILABLE_TAGS" ] && AVAILABLE_TAGS="$tag" || AVAILABLE_TAGS="$AVAILABLE_TAGS
$tag"; }
                done <<EOF_TAGS
$TAGS_RAW
EOF_TAGS
                [ -z "${AVAILABLE_TAGS:-}" ] && { echo "${C_WARN}✖ Нет релизов с файлом $ARCH_ASSET.${C_RESET}"; wait_enter; continue; }
                
                echo
                i=1
                echo "$AVAILABLE_TAGS" | while read -r tag; do
                    [ -z "$tag" ] && continue
                    printf "  %2d) %s\n" "$i" "$tag"
                    i=$((i+1))
                done
                echo
                printf "Номер релиза (0 — назад): "
                read -r num
                [ "$num" = "0" ] && continue
                ! echo "$num" | grep -Eq '^[0-9]+$' && { echo "${C_WARN}✖ Неверный ввод.${C_RESET}"; wait_enter; continue; }
                SELECTED_TAG="$(echo "$AVAILABLE_TAGS" | sed -n "${num}p")"
                [ -z "${SELECTED_TAG:-}" ] && { echo "${C_WARN}✖ Нет такого номера.${C_RESET}"; wait_enter; continue; }
                
                echo "${C_LABEL}▸ Выбрано:${C_RESET} $SELECTED_TAG"
                if ! download_version "$SELECTED_TAG"; then wait_enter; continue; fi
                install_init_script
                "$INIT_PATH" restart
                wait_enter
                ;;
            3)
                if rollback; then
                    install_init_script
                    "$INIT_PATH" restart
                fi
                wait_enter
                ;;
            4)
                read_watchdog_interval_from_user
                set_conf_value WATCHDOG_INTERVAL "$INPUT_INTERVAL"
                install_init_script
                echo "${C_OK}✔ Интервал: ${INPUT_INTERVAL}s. Перезапуск...${C_RESET}"
                "$INIT_PATH" restart
                wait_enter
                ;;
            5)
                if [ -x "$INIT_PATH" ]; then
                    "$INIT_PATH" status
                    if [ -f "$WATCHDOG_LOG" ]; then
                        echo
                        echo "${C_DIM}── последние 15 строк watchdog ──${C_RESET}"
                        tail -n 15 "$WATCHDOG_LOG" | while IFS= read -r line; do
                            case "$line" in
                                *"упал"*|*"не удалось"*|*"перезапуск"*|*"DOWN"*|*"WARN"*)
                                    echo "${C_WARN}$line${C_RESET}" ;;
                                *"поднят"*|*"OK"*)
                                    echo "${C_OK}$line${C_RESET}" ;;
                                *)
                                    echo "$line" ;;
                            esac
                        done
                    fi
                else
                    echo "${C_WARN}✖ Init-скрипт не найден.${C_RESET}"
                fi
                wait_enter
                ;;
            6)
                uninstall_all && { wait_enter; exit 0; }
                wait_enter
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

ln -sf "$TARGET_SCRIPT" /opt/bin/torrservmng

echo "Скрипт-менеджер сохранён в: $TARGET_SCRIPT"
echo "Доступна команда: torrservmng"
echo "Запуск установщика..."
exec "$TARGET_SCRIPT"