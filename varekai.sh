#!/usr/bin/env bash

# =============================================================================
# Xray Management Script
# Основан на:
# https://github.com/XTLS/Xray-install,
# https://github.com/zxcvos/Xray-script,
# https://raw.githubusercontent.com/xxphantom/docker-warp-native
# Форк Xray: https://github.com/Jolymmiles/Xray-core
# =============================================================================

# --- Глобальные переменные ---
readonly SCRIPT_VERSION="1.0.0"
readonly XRAY_FORK_REPO="Jolymmiles/Xray-core"
readonly CONFIG_PATH="/usr/local/etc/xray/config.json"
readonly ENV_CONFIG_PATH="/usr/local/etc/xray/xray-env.conf"
readonly BACKUP_DIR="/usr/local/etc/xray/backups"
readonly LOG_PATH="/usr/local/etc/xray/script.log"
readonly USERS_LIST="/usr/local/etc/xray/users.list"
readonly DAT_PATH="/usr/local/share/xray"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly API_SERVER="127.0.0.1:32768"
readonly STATS_DIR="/usr/local/etc/xray"

# --- Цвета ---
readonly RED='\033[31m'
readonly BRIGHT_RED='\033[1;31m'
readonly CYAN='\033[36m'
readonly BRIGHT_CYAN='\033[1;36m'
readonly GREEN='\033[32m'
readonly YELLOW='\033[33m'
readonly NC='\033[0m' # Без цвета

# --- ASCII Art заголовок ---
show_banner() {
    echo -e "${BRIGHT_RED}"
    cat << 'EOF'
                                          █████                 ███
                                         ▒▒███                 ▒▒▒
 █████ █████  ██████   ████████   ██████  ▒███ █████  ██████   ████
▒▒███ ▒▒███  ▒▒▒▒▒███ ▒▒███▒▒███ ███▒▒███ ▒███▒▒███  ▒▒▒▒▒███ ▒▒███
 ▒███  ▒███   ███████  ▒███ ▒▒▒ ▒███████  ▒██████▒    ███████  ▒███
 ▒▒███ ███   ███▒▒███  ▒███     ▒███▒▒▒   ▒███▒▒███  ███▒▒███  ▒███
  ▒▒█████   ▒▒████████ █████    ▒▒██████  ████ █████▒▒████████ █████
   ▒▒▒▒▒     ▒▒▒▒▒▒▒▒ ▒▒▒▒▒      ▒▒▒▒▒▒  ▒▒▒▒ ▒▒▒▒▒  ▒▒▒▒▒▒▒▒ ▒▒▒▒▒

EOF
    echo -e "${NC}"
}

# --- Логирование ---
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_PATH"
}

# --- Проверка root ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Ошибка: скрипт должен быть запущен от root${NC}"
        exit 1
    fi
}

# --- Создание необходимых директорий ---
create_directories() {
    mkdir -p "$(dirname "$CONFIG_PATH")"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$LOG_PATH")"
    touch "$LOG_PATH"
    chmod 644 "$LOG_PATH"
}

# --- Загрузка переменных окружения ---
load_env_config() {
    if [[ -f "$ENV_CONFIG_PATH" ]]; then
        source "$ENV_CONFIG_PATH"
    fi
    # Значения по умолчанию для настроек ротации
    LOG_ROTATE_ENABLED="${LOG_ROTATE_ENABLED:-true}"
    LOG_ROTATE_TIME="${LOG_ROTATE_TIME:-06:00}"
    LOG_ROTATE_KEEP="${LOG_ROTATE_KEEP:-30}"
}

# --- Сохранение переменных окружения ---
save_env_config() {
    cat > "$ENV_CONFIG_PATH" << EOF
# Xray Environment Configuration
ROUTING_URL="${ROUTING_URL:-}"
DOMAIN="${DOMAIN:-}"
EDITOR="${EDITOR:-}"
EDITOR_CONFIGURED="${EDITOR_CONFIGURED:-false}"
LOG_ROTATE_ENABLED="${LOG_ROTATE_ENABLED:-true}"
LOG_ROTATE_TIME="${LOG_ROTATE_TIME:-06:00}"
LOG_ROTATE_KEEP="${LOG_ROTATE_KEEP:-30}"
EOF
    chmod 644 "$ENV_CONFIG_PATH"
}

# --- Проверка зависимостей ---
check_dependencies() {
    local deps=(curl unzip jq openssl tput)
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Установка зависимостей: ${missing[*]}${NC}"
        apt-get update -qq
        apt-get install -y "${missing[@]}" > /dev/null 2>&1
    fi
}

# --- Определение архитектуры ---
detect_architecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            MACHINE="64"
            ;;
        i386|i686)
            MACHINE="32"
            ;;
        aarch64|arm64)
            MACHINE="arm64-v8a"
            echo -e "${YELLOW}Внимание: ARM архитектура. Поддержка ограничена.${NC}"
            ;;
        *)
            echo -e "${RED}Неподдерживаемая архитектура: $arch${NC}"
            exit 1
            ;;
    esac
}

# --- Генерация случайных значений ---
generate_random() {
    local min=${1:-0}
    local max=${2:-4294967295}
    local random=$(od -An -N4 -tu4 </dev/urandom)
    if [[ $min =~ ^[0-9]+$ && $max =~ ^[0-9]+$ ]] && ((min < max)); then
        local range=$((max - min + 1))
        echo $((random % range + min))
    else
        echo "$random"
    fi
}

generate_uuid() {
    if command -v xray &> /dev/null; then
        xray uuid
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

generate_short_ids() {
    local len1=$(generate_random 3 4)
    local len2=$(generate_random 5 6)
    local len3=$(generate_random 7 8)

    local id1=$(openssl rand -hex $len1)
    local id2=$(openssl rand -hex $len2)
    local id3=$(openssl rand -hex $len3)

    echo "$id1 $id2 $id3"
}

generate_path() {
    local length=$(generate_random 16 64)
    local path=$(cat /dev/urandom | tr -cd 'a-zA-Z0-9' | fold -w $length | head -n 1)
    echo "/$path"
}

generate_x25519() {
    local x25519_output=$(xray x25519)
    local private_key=$(echo "$x25519_output" | sed -ne '1s/.*:\s*//p')
    local public_key=$(echo "$x25519_output" | sed -ne '2s/.*:\s*//p')
    echo "$private_key $public_key"
}

# --- Получение версии Xray ---
get_xray_version() {
    if [[ -f "$XRAY_BIN" ]]; then
        $XRAY_BIN version | head -n 1 | awk '{print $2}'
    else
        echo "не установлен"
    fi
}

# --- Получение списка версий из GitHub ---
get_available_versions() {
    local arch=$1
    local cache_file="/tmp/xray-versions-cache.txt"
    local cache_ttl=3600  # 1 час в секундах

    # Проверка кэша
    if [[ -f "$cache_file" ]]; then
        local cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [[ $cache_age -lt $cache_ttl ]]; then
            # Проверка валидности кэша (каждая строка должна начинаться с 'v' или цифры)
            if grep -qE '^v?[0-9]' "$cache_file" 2>/dev/null; then
                cat "$cache_file"
                return 0
            fi
        fi
    fi

    local tmp_file=$(mktemp)

    echo -e "${YELLOW}  → Запрос к GitHub API...${NC}" >&2

    # Выполняем curl
    local curl_exit_code=0
    curl -s -f -L \
        -H "Accept: application/vnd.github.v3+json" \
        -H "User-Agent: Xray-Management-Script" \
        "https://api.github.com/repos/${XRAY_FORK_REPO}/releases" \
        -o "$tmp_file" 2>/dev/null || curl_exit_code=$?

    if [[ $curl_exit_code -ne 0 ]]; then
        echo -e "${RED}  ✗ Ошибка curl (код: $curl_exit_code)${NC}" >&2
        rm -f "$tmp_file"
        return 1
    fi

    # Проверка, что файл не пустой
    if [[ ! -s "$tmp_file" ]]; then
        echo -e "${RED}  ✗ Ответ от GitHub пустой${NC}" >&2
        rm -f "$tmp_file"
        return 1
    fi

    # Проверка валидности JSON
    if ! jq empty "$tmp_file" 2>/dev/null; then
        echo -e "${RED}  ✗ GitHub вернул невалидный JSON${NC}" >&2
        # Проверяем на rate limit
        if grep -q "API rate limit" "$tmp_file" 2>/dev/null; then
            echo -e "${YELLOW}  ⚠ Превышен лимит запросов к GitHub API${NC}" >&2
        fi
        rm -f "$tmp_file"
        return 1
    fi

    # Извлечение версий через jq
    local all_versions
    all_versions=$(jq -r '.[].tag_name // empty' "$tmp_file" 2>/dev/null)
    rm -f "$tmp_file"

    if [[ -z "$all_versions" ]]; then
        echo -e "${RED}  ✗ В ответе не найдено ни одного релиза${NC}" >&2
        return 1
    fi

    local version_count
    version_count=$(echo "$all_versions" | wc -l)
    echo -e "${GREEN}  ✓ Получено версий: $version_count${NC}" >&2

    # Сохранение в кэш
    echo "$all_versions" > "$cache_file"

    # В stdout только чистый список версий
    echo "$all_versions"
}

# --- Установка Xray ---
install_xray() {
    echo -e "${CYAN}=== Установка Xray ===${NC}"

    echo -e "${YELLOW}Получение списка доступных версий...${NC}"
    local versions=$(get_available_versions "$MACHINE")

    echo -e "${CYAN}Доступные версии:${NC}"
    local i=1
    local version_array=()
    while IFS= read -r version; do
        if [[ -n "$version" ]]; then
            echo -e "${CYAN}$i. $version${NC}"
            version_array+=("$version")
            ((i++))
        fi
    done <<< "$versions"
    echo -e "${CYAN}0. latest (последняя стабильная)${NC}"

    read -p "Выберите версию для установки (0-$((i-1))) [0]: " version_choice
    version_choice=${version_choice:-0}

    local install_version=""
    if [[ "$version_choice" == "0" ]]; then
        install_version="latest"
        echo -e "${YELLOW}Установка последней версии...${NC}"
    elif [[ "$version_choice" =~ ^[0-9]+$ && "$version_choice" -gt 0 && "$version_choice" -lt "$i" ]]; then
        install_version="${version_array[$((version_choice-1))]}"
        echo -e "${YELLOW}Установка версии $install_version...${NC}"
    else
        echo -e "${RED}Неверный выбор. Установка отменена.${NC}"
        return 1
    fi

    local download_url=""
    if [[ "$install_version" == "latest" ]]; then
        download_url="https://github.com/${XRAY_FORK_REPO}/releases/latest/download/Xray-linux-${MACHINE}.zip"
    else
        download_url="https://github.com/${XRAY_FORK_REPO}/releases/download/${install_version}/Xray-linux-${MACHINE}.zip"
    fi

    local tmp_dir=$(mktemp -d)
    local zip_file="${tmp_dir}/xray.zip"

    echo -e "${YELLOW}Скачивание Xray...${NC}"
    if ! curl -L -o "$zip_file" "$download_url"; then
        echo -e "${RED}Ошибка скачивания Xray${NC}"
        rm -rf "$tmp_dir"
        return 1
    fi

    echo -e "${YELLOW}Распаковка...${NC}"
    unzip -q "$zip_file" -d "$tmp_dir"

    install -m 755 "${tmp_dir}/xray" "$XRAY_BIN"
    install -d "$DAT_PATH"
    [[ -f "${tmp_dir}/geoip.dat" ]] && install -m 644 "${tmp_dir}/geoip.dat" "${DAT_PATH}/"
    [[ -f "${tmp_dir}/geosite.dat" ]] && install -m 644 "${tmp_dir}/geosite.dat" "${DAT_PATH}/"

    rm -rf "$tmp_dir"

    setup_logs
    setup_log_rotation
    setup_stats_collection

    echo -e "${YELLOW}Введите домен для serverNames (например, example.com):${NC}"
    read -p "Домен: " domain
    DOMAIN="$domain"
    save_env_config

    generate_config
    create_systemd_service

    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray

    echo -e "${GREEN}✓ Xray успешно установлен!${NC}"
    log_message "Xray установлен, версия: $(get_xray_version)"

    setup_systemd_resolved
    install_warp
}

# --- Обновление Xray ---
update_xray() {
    echo -e "${CYAN}=== Обновление Xray ===${NC}"

    if [[ ! -f "$XRAY_BIN" ]]; then
        echo -e "${RED}Xray не установлен. Сначала установите его.${NC}"
        return 1
    fi

    local current_version=$(get_xray_version)
    echo -e "${CYAN}Текущая версия: ${GREEN}${current_version}${NC}"
    echo -e "${CYAN}Архитектура: ${GREEN}${MACHINE}${NC}"
    echo -e "${CYAN}Репозиторий: ${GREEN}https://github.com/${XRAY_FORK_REPO}${NC}"
    echo

    echo -e "${YELLOW}Получение списка доступных версий...${NC}"

    # Сохраняем stdout отдельно от stderr (сообщения диагностики)
    local versions_file=$(mktemp)
    if ! get_available_versions "$MACHINE" > "$versions_file"; then
        echo
        echo -e "${RED}═══════════════════════════════════════${NC}"
        echo -e "${RED}Не удалось получить список версий${NC}"
        echo -e "${RED}═══════════════════════════════════════${NC}"
        rm -f "$versions_file"

        echo
        echo -e "${YELLOW}Альтернативный вариант — ввести версию вручную.${NC}"
        echo -e "${YELLOW}Список версий можно посмотреть здесь:${NC}"
        echo -e "${CYAN}https://github.com/${XRAY_FORK_REPO}/releases${NC}"
        echo
        read -p "Введите название версии (например, v26.8.15) или Enter для отмены: " manual_version

        if [[ -z "$manual_version" ]]; then
            echo -e "${RED}Обновление отменено${NC}"
            return 1
        fi

        echo "$manual_version" > "$versions_file"
        echo -e "${YELLOW}Будет использована версия: $manual_version${NC}"
    fi

    local versions=$(cat "$versions_file")
    rm -f "$versions_file"

    if [[ -z "$versions" ]]; then
        echo -e "${RED}Список версий пуст. Обновление отменено.${NC}"
        return 1
    fi

    echo
    echo -e "${CYAN}Доступные версии:${NC}"
    local i=1
    local version_array=()
    while IFS= read -r version; do
        if [[ -n "$version" ]]; then
            # Подсветка текущей версии
            if [[ "$version" == "$current_version" || "v${version#v}" == "$current_version" ]]; then
                echo -e "${CYAN}$i. $version ${GREEN}← текущая${NC}"
            else
                echo -e "${CYAN}$i. $version${NC}"
            fi
            version_array+=("$version")
            ((i++))
        fi
    done <<< "$versions"

    echo -e "${CYAN}0. latest (последняя стабильная)${NC}"
    echo
    echo -e "${YELLOW}Введите номер версии (0-$((i-1))) или название версии вручную:${NC}"
    read -p "Выбор [0]: " version_choice
    version_choice=${version_choice:-0}

    local update_version=""

    # Проверка, является ли ввод числом (выбор по номеру)
    if [[ "$version_choice" =~ ^[0-9]+$ ]]; then
        if [[ "$version_choice" == "0" ]]; then
            update_version="latest"
            echo -e "${YELLOW}Обновление до последней версии...${NC}"
        elif [[ "$version_choice" -gt 0 && "$version_choice" -lt "$i" ]]; then
            update_version="${version_array[$((version_choice-1))]}"
            echo -e "${YELLOW}Обновление до версии $update_version...${NC}"
        else
            echo -e "${RED}Неверный номер. Обновление отменено.${NC}"
            return 1
        fi
    else
        # Пользователь ввёл название версии вручную
        update_version="$version_choice"
        echo -e "${YELLOW}Обновление до указанной версии $update_version...${NC}"

        # Проверка, существует ли такая версия в списке
        if ! echo "$versions" | grep -qx "$update_version"; then
            echo -e "${YELLOW}Внимание: версия $update_version не найдена в списке релизов${NC}"
            read -p "Продолжить всё равно? [y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${RED}Обновление отменено${NC}"
                return 1
            fi
        fi
    fi

    # Создание бэкапа текущего бинарника
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local backup_bin="${XRAY_BIN}.bak.${timestamp}"
    echo -e "${YELLOW}Создание бэкапа текущего бинарника...${NC}"
    cp "$XRAY_BIN" "$backup_bin"
    echo -e "${GREEN}✓ Бэкап создан: $backup_bin${NC}"

    # Скачивание новой версии
    local download_url=""
    if [[ "$update_version" == "latest" ]]; then
        download_url="https://github.com/${XRAY_FORK_REPO}/releases/latest/download/Xray-linux-${MACHINE}.zip"
    else
        download_url="https://github.com/${XRAY_FORK_REPO}/releases/download/${update_version}/Xray-linux-${MACHINE}.zip"
    fi

    local tmp_dir=$(mktemp -d)
    local zip_file="${tmp_dir}/xray.zip"

    echo -e "${YELLOW}Скачивание Xray из ${download_url}...${NC}"
    if ! curl -L -o "$zip_file" "$download_url"; then
        echo -e "${RED}Ошибка скачивания Xray${NC}"
        rm -rf "$tmp_dir"
        rm -f "$backup_bin"
        return 1
    fi

    # Проверка, что файл скачался и не пустой
    if [[ ! -s "$zip_file" ]]; then
        echo -e "${RED}Скачанный файл пуст. Возможно, версия не существует или архив отсутствует для вашей архитектуры.${NC}"
        rm -rf "$tmp_dir"
        rm -f "$backup_bin"
        return 1
    fi

    local file_size=$(du -h "$zip_file" | cut -f1)
    echo -e "${GREEN}✓ Скачан архив размером $file_size${NC}"

    # Распаковка
    echo -e "${YELLOW}Распаковка...${NC}"
    if ! unzip -q "$zip_file" -d "$tmp_dir"; then
        echo -e "${RED}Ошибка распаковки${NC}"
        rm -rf "$tmp_dir"
        mv "$backup_bin" "$XRAY_BIN"
        echo -e "${YELLOW}Восстановлен бинарник из бэкапа${NC}"
        return 1
    fi

    # Проверка наличия бинарника в архиве
    if [[ ! -f "${tmp_dir}/xray" ]]; then
        echo -e "${RED}Бинарник xray не найден в архиве${NC}"
        echo -e "${YELLOW}Содержимое архива:${NC}"
        ls -la "$tmp_dir"
        rm -rf "$tmp_dir"
        mv "$backup_bin" "$XRAY_BIN"
        echo -e "${YELLOW}Восстановлен бинарник из бэкапа${NC}"
        return 1
    fi

    # Остановка сервиса перед заменой бинарника
    if systemctl is-active --quiet xray; then
        echo -e "${YELLOW}Остановка Xray...${NC}"
        systemctl stop xray
    fi

    # Установка нового бинарника
    install -m 755 "${tmp_dir}/xray" "$XRAY_BIN"

    # Обновление geoip.dat и geosite.dat если они есть
    [[ -f "${tmp_dir}/geoip.dat" ]] && install -m 644 "${tmp_dir}/geoip.dat" "${DAT_PATH}/"
    [[ -f "${tmp_dir}/geosite.dat" ]] && install -m 644 "${tmp_dir}/geosite.dat" "${DAT_PATH}/"

    # Очистка
    rm -rf "$tmp_dir"

    # Проверка нового бинарника
    local new_version=$(get_xray_version)
    if [[ -z "$new_version" || "$new_version" == "не установлен" ]]; then
        echo -e "${RED}Ошибка: новый бинарник не работает!${NC}"
        echo -e "${YELLOW}Восстановление из бэкапа...${NC}"
        mv "$backup_bin" "$XRAY_BIN"
        systemctl start xray
        echo -e "${GREEN}✓ Восстановлен бинарник из бэкапа${NC}"
        return 1
    fi

    # Запуск сервиса
    echo -e "${YELLOW}Запуск Xray...${NC}"
    if systemctl start xray; then
        echo -e "${GREEN}✓ Xray успешно обновлён!${NC}"
        echo -e "${CYAN}Старая версия: ${YELLOW}${current_version}${NC}"
        echo -e "${CYAN}Новая версия: ${GREEN}${new_version}${NC}"
        echo -e "${CYAN}Бэкап старого бинарника: ${YELLOW}${backup_bin}${NC}"
        log_message "Xray обновлён с $current_version до $new_version"

        # Восстанавливаем сервисы обслуживания (ротация + статистика)
        setup_log_rotation
        setup_stats_collection
    else
        echo -e "${RED}Ошибка запуска Xray с новым бинарником!${NC}"
        echo -e "${YELLOW}Восстановление из бэкапа...${NC}"
        systemctl stop xray 2>/dev/null
        mv "$backup_bin" "$XRAY_BIN"
        systemctl start xray
        echo -e "${GREEN}✓ Восстановлен бинарник из бэкапа${NC}"
        return 1
    fi
}

# =============================================================================
# Ротация логов
# =============================================================================
# Принцип: copytruncate. Xray открывает лог с O_APPEND, поэтому после
# копирования access.log в access-YYYY-MM-DD.log и обрезки оригинала
# запись продолжается в свежий access.log без перезапуска.
# error.log никогда не ротируется.

# --- Запись systemd timer-файла ротации (из LOG_ROTATE_TIME) ---
write_logrotate_timer_file() {
    local t="${LOG_ROTATE_TIME:-06:00}"
    local hh="06" mm="00"
    if [[ "$t" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        hh="${BASH_REMATCH[1]}"
        mm="${BASH_REMATCH[2]}"
    fi
    hh=$((10#$hh))
    mm=$((10#$mm))
    if (( hh > 23 || mm > 59 )); then
        hh=6
        mm=0
    fi
    printf -v hh "%02d" "$hh"

    cat > /etc/systemd/system/xray-logrotate.timer << EOF
[Unit]
Description=Daily Xray access.log rotation

[Timer]
OnCalendar=*-*-* ${hh}:${mm}:00
Persistent=true
Unit=xray-logrotate.service

[Install]
WantedBy=timers.target
EOF
    chmod 644 /etc/systemd/system/xray-logrotate.timer
}

# --- Установка/восстановление ротации логов (идемпотентно) ---
setup_log_rotation() {
    # Удаляем легаси-конфиг logrotate: он ломает ротацию xray (rename+create)
    # и ротирует error.log, который ротировать не нужно
    rm -f /etc/logrotate.d/xray

    # Скрипт ротации
    cat > /usr/local/bin/xray-rotate-logs.sh << 'ROTATE_EOF'
#!/usr/bin/env bash
# =============================================================================
# Ротация /var/log/xray/access.log
# copytruncate: копия в access-YYYY-MM-DD.log + обрезка оригинала.
# Безопасно, т.к. Xray открывает лог с O_APPEND (запись продолжится с нуля).
# error.log никогда не ротируется.
# =============================================================================
set -u

readonly ENV_CONFIG_PATH="/usr/local/etc/xray/xray-env.conf"
readonly LOG_DIR="/var/log/xray"
readonly ACCESS_LOG="${LOG_DIR}/access.log"

# Переменная может быть задана извне (ручной запуск из меню при выключенной
# автоматической ротации) — тогда env-файл не подменяет её
if [[ -z "${LOG_ROTATE_ENABLED+x}" ]]; then
    [[ -f "$ENV_CONFIG_PATH" ]] && source "$ENV_CONFIG_PATH"
fi

if [[ "${LOG_ROTATE_ENABLED:-true}" != "true" ]]; then
    exit 0
fi

keep="${LOG_ROTATE_KEEP:-30}"
[[ "$keep" =~ ^[0-9]+$ ]] || keep=30
(( keep < 1 )) && keep=30

today=$(date +%Y-%m-%d)
archive="${LOG_DIR}/access-${today}.log"

# Один архив в день: повторный запуск не портит данные
if [[ -s "$ACCESS_LOG" && ! -f "$archive" ]]; then
    cp "$ACCESS_LOG" "$archive"
    chmod 600 "$archive"
    truncate -s 0 "$ACCESS_LOG"
    chmod 600 "$ACCESS_LOG"
fi

# Чистка старых архивов
ls -1 "${LOG_DIR}"/access-????-??-??.log 2>/dev/null | sort | head -n "-${keep}" | xargs -r rm -f

exit 0
ROTATE_EOF
    chmod 755 /usr/local/bin/xray-rotate-logs.sh

    # Systemd units
    cat > /etc/systemd/system/xray-logrotate.service << EOF
[Unit]
Description=Xray access.log rotation

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xray-rotate-logs.sh
EOF
    chmod 644 /etc/systemd/system/xray-logrotate.service

    write_logrotate_timer_file

    systemctl daemon-reload
    if [[ "${LOG_ROTATE_ENABLED:-true}" == "true" ]]; then
        systemctl enable --now xray-logrotate.timer > /dev/null 2>&1
    fi
    log_message "Ротация логов настроена"
}

# =============================================================================
# Накопитель статистики трафика
# =============================================================================
# Снимает xray api statsquery каждые 10 минут, складывает дельты посуточно
# в скрытый .traffic-days.json (с учётом сброса счётчиков при перезапуске)
# и перегенерирует stats-YYYY-MM-DD.txt — человекочитаемую сводку
# за скользящее окно 30 дней.

setup_stats_collection() {
    cat > /usr/local/bin/xray-stats-collect.sh << 'STATS_EOF'
#!/usr/bin/env bash
# =============================================================================
# Накопитель статистики трафика Xray
# Служебные данные: /usr/local/etc/xray/.traffic-days.json
# Пользовательский вывод: /usr/local/etc/xray/stats-YYYY-MM-DD.txt
# =============================================================================
set -u

readonly API_SERVER="127.0.0.1:32768"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly CONFIG_PATH="/usr/local/etc/xray/config.json"
readonly DATA_DIR="/usr/local/etc/xray"
readonly DAYS_FILE="${DATA_DIR}/.traffic-days.json"
readonly TXT_KEEP=30

command -v jq > /dev/null 2>&1 || exit 0
[[ -x "$XRAY_BIN" ]] || exit 0
systemctl is-active --quiet xray 2>/dev/null || exit 0

today=$(date +%Y-%m-%d)
window_start=$(date -d "29 days ago" +%Y-%m-%d)

raw=$("$XRAY_BIN" api statsquery --server="$API_SERVER" 2>/dev/null)
[[ -z "$raw" ]] && exit 0
echo "$raw" | jq empty > /dev/null 2>&1 || exit 0

# --- Сырьё: агрегируем по пользователям / inbound / outbound ---
extract() {
    local prefix="$1"
    echo "$raw" | jq --arg prefix "$prefix" '
        [.stat[] | select(.name | startswith($prefix)) | (.name | split(">>>")) as $p
            | {key: $p[1], dir: $p[3], val: .value}]
        | group_by(.key)
        | map({(.[0].key): {
            up: (map(select(.dir == "uplink")) | .[0].val // 0),
            down: (map(select(.dir == "downlink")) | .[0].val // 0)}})
        | add // {}'
}

cur_users=$(extract "user>>>")
cur_inbounds=$(extract "inbound>>>")
cur_outbounds=$(extract "outbound>>>")

# --- Слияние с посуточным хранилищем ---
prev=""
if [[ -f "$DAYS_FILE" ]]; then
    prev=$(cat "$DAYS_FILE" 2>/dev/null)
fi
[[ -z "$prev" ]] && prev='{"last_raw":{"users":{},"inbounds":{},"outbounds":{}},"days":{}}'
echo "$prev" | jq empty > /dev/null 2>&1 || prev='{"last_raw":{"users":{},"inbounds":{},"outbounds":{}},"days":{}}'

merged=$(jq -n \
    --argjson cu "$cur_users" --argjson ci "$cur_inbounds" --argjson co "$cur_outbounds" \
    --argjson prev "$prev" --arg today "$today" --arg cut "$window_start" '
    def delta(c; l): ((c // 0) - (l // 0)) as $d | if $d < 0 then (c // 0) else $d end;
    def mergec($cur; $last; $rec):
        reduce ($cur | to_entries[]) as $e ({};
            .[$e.key] = {
                up: (($rec[$e.key].up // 0) + delta($e.value.up; $last[$e.key].up)),
                down: (($rec[$e.key].down // 0) + delta($e.value.down; $last[$e.key].down))
            });
    ($prev.last_raw.users // {}) as $lu |
    ($prev.last_raw.inbounds // {}) as $li |
    ($prev.last_raw.outbounds // {}) as $lo |
    ($prev.days[$today] // {}) as $td |
    {
        last_raw: {users: $cu, inbounds: $ci, outbounds: $co},
        days: (($prev.days // {}) + {($today): {
            users: mergec($cu; $lu; ($td.users // {})),
            inbounds: mergec($ci; $li; ($td.inbounds // {})),
            outbounds: mergec($co; $lo; ($td.outbounds // {}))
        }} | with_entries(select(.key >= $cut)))
    }')

tmp=$(mktemp)
if echo "$merged" | jq . > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp"
    mv "$tmp" "$DAYS_FILE"
else
    rm -f "$tmp"
    exit 0
fi

# --- Генерация txt (окно 30 дней, все пользователи) ---
SEP="═══════════════════════════════════"

format_bytes() {
    local bytes="${1:-0}"
    if [[ -z "$bytes" || "$bytes" == "null" ]]; then bytes=0; fi
    if (( bytes == 0 )); then
        echo "0 B"
    else
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes} B"
    fi
}

agg=$(echo "$merged" | jq --arg cut "$window_start" '
    def sumobjs: reduce .[] as $x ({};
        reduce ($x | to_entries[]) as $e (.;
            .[$e.key] = {
                up: ((.[$e.key].up // 0) + $e.value.up),
                down: ((.[$e.key].down // 0) + $e.value.down)
            }));
    ([.days | to_entries[] | select(.key >= $cut) | .value] | {
        users: ([.[].users] | sumobjs),
        inbounds: ([.[].inbounds] | sumobjs),
        outbounds: ([.[].outbounds] | sumobjs)
    })')

emails_now=""
if [[ -f "$CONFIG_PATH" ]]; then
    emails_now=$(jq -r '[.inbounds[]? | .settings.clients[]? | .email // empty] | unique | .[]' "$CONFIG_PATH" 2>/dev/null)
fi

stats_txt="${DATA_DIR}/stats-${today}.txt"
tmp_txt=$(mktemp)

{
    echo "=== Статистика сервера ${window_start} : ${today} ==="
    echo "$SEP"
    echo "  Трафик по inbound'ам"
    echo "$SEP"
    echo "$agg" | jq -r '.inbounds | to_entries | map(.value += {total: (.value.up + .value.down)}) | sort_by(.value.total) | reverse | .[] | "\(.key)\t\(.value.up)\t\(.value.down)"' | while IFS=$'\t' read -r name up down; do
        [[ -z "$name" ]] && continue
        echo "  ${name}"
        echo "    ↑ Upload: $(format_bytes "$up")"
        echo "    ↓ Download: $(format_bytes "$down")"
    done
    echo "$SEP"
    echo "  Трафик по outbound'ам"
    echo "$SEP"
    echo "$agg" | jq -r '.outbounds | to_entries | map(.value += {total: (.value.up + .value.down)}) | sort_by(.value.total) | reverse | .[] | "\(.key)\t\(.value.up)\t\(.value.down)"' | while IFS=$'\t' read -r name up down; do
        [[ -z "$name" ]] && continue
        echo "  ${name}"
        echo "    ↑ Upload: $(format_bytes "$up")"
        echo "    ↓ Download: $(format_bytes "$down")"
    done
    echo "$SEP"
    echo "  Статистика по пользователям"
    echo "$SEP"
    total_users=0
    rank=1
    while IFS=$'\t' read -r email up down total; do
        [[ -z "$email" ]] && continue
        mark=""
        if ! echo "$emails_now" | grep -qx "$email"; then
            mark=" (удалён)"
        fi
        echo "  ${rank}. ${email}${mark}"
        echo "     ↑ $(format_bytes "$up") | ↓ $(format_bytes "$down") | Σ $(format_bytes "$total")"
        rank=$((rank + 1))
        total_users=$((total_users + 1))
    done < <(echo "$agg" | jq -r '.users | to_entries | map(.value += {total: (.value.up + .value.down)}) | sort_by(.value.total) | reverse | .[] | select(.value.total > 0) | "\(.key)\t\(.value.up)\t\(.value.down)\t\(.value.total)"')
    echo
    echo "  Всего пользователей с трафиком: ${total_users}"
    echo "$SEP"
    echo "  Итоговый трафик сервера"
    echo "$SEP"
    tot_down=$(echo "$agg" | jq '[.inbounds[].down] | add // 0')
    tot_up=$(echo "$agg" | jq '[.inbounds[].up] | add // 0')
    tot_usr=$(echo "$agg" | jq '[.users[].up, .users[].down] | add // 0')
    echo "  Всего download:  $(format_bytes "$tot_down")"
    echo "  Всего upload:    $(format_bytes "$tot_up")"
    echo "  Всего по users:  $(format_bytes "$tot_usr")"
} > "$tmp_txt" 2>/dev/null

chmod 644 "$tmp_txt" 2>/dev/null
mv "$tmp_txt" "$stats_txt"

# Храним txt-файлы 30 дней
ls -1 "${DATA_DIR}"/stats-????-??-??.txt 2>/dev/null | sort | head -n "-${TXT_KEEP}" | xargs -r rm -f

exit 0
STATS_EOF
    chmod 755 /usr/local/bin/xray-stats-collect.sh

    cat > /etc/systemd/system/xray-stats.service << EOF
[Unit]
Description=Xray traffic stats collector

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xray-stats-collect.sh
EOF
    chmod 644 /etc/systemd/system/xray-stats.service

    cat > /etc/systemd/system/xray-stats.timer << 'EOF'
[Unit]
Description=Xray traffic stats collector timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=10min
Unit=xray-stats.service

[Install]
WantedBy=timers.target
EOF
    chmod 644 /etc/systemd/system/xray-stats.timer

    systemctl daemon-reload
    systemctl enable --now xray-stats.timer > /dev/null 2>&1
    log_message "Сбор статистики настроен"
}

# --- Настройка директории и файлов логов ---
setup_logs() {
    echo -e "${CYAN}Настройка директории логов...${NC}"
    if [[ ! -d '/var/log/xray/' ]]; then
        mkdir -p /var/log/xray/
        chmod 755 /var/log/xray/
        touch /var/log/xray/access.log
        touch /var/log/xray/error.log
        chmod 600 /var/log/xray/access.log
        chmod 600 /var/log/xray/error.log
        chown root:root /var/log/xray/
        chown root:root /var/log/xray/*.log
        echo -e "${GREEN}✓ Директория и файлы логов созданы${NC}"
    else
        # Если директория уже есть, просто убеждаемся, что файлы существуют и права верны
        touch /var/log/xray/access.log
        touch /var/log/xray/error.log
        chmod 755 /var/log/xray/
        chmod 600 /var/log/xray/access.log
        chmod 600 /var/log/xray/error.log
        echo -e "${GREEN}✓ Директория логов уже существует, права проверены${NC}"
    fi
    log_message "Директория логов настроена"
}

# --- Генерация конфига Xray ---
generate_config() {
    echo -e "${CYAN}Генерация конфигурации Xray...${NC}"

    local x25519_keys=$(generate_x25519)
    local private_key=$(echo "$x25519_keys" | awk '{print $1}')
    local public_key=$(echo "$x25519_keys" | awk '{print $2}')

    local vision_uuid=$(generate_uuid)

    local short_ids=$(generate_short_ids)
    local short_id_1=$(echo "$short_ids" | awk '{print $1}')
    local short_id_2=$(echo "$short_ids" | awk '{print $2}')
    local short_id_3=$(echo "$short_ids" | awk '{print $3}')

    cat > "$CONFIG_PATH" << EOF
{
  "log": {
    "loglevel": "warning",
    "error": "/var/log/xray/error.log",
    "access": "/var/log/xray/access.log",
    "maskAddress": "half"
  },
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "routing": {
    "rules": [
      {
        "ruleTag": "api",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api"
      },
      {
        "ruleTag": "bt",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      },
      {
        "ruleTag": "special direct",
        "domain": [
          "geosite:apple",
          "intlgame.com",
          "playerinfinite.com",
          "levelinfinite.com",
          "iegcom.com",
          "jupiterlauncher.com",
          "proximabeta.com",
          "nikke-en.com",
          "nikke-kr.com",
          "lipgcdn.com",
          "game-news-intl.com",
          "tencentgames.com",
          "unitegame.com",
          "gcloudsdk.com",
          "gcloudsvcs.com"
        ],
        "outboundTag": "direct"
      },
      {
        "ruleTag": "google-core-auth",
        "domain": [
          "domain:gstatic.com",
          "domain:clients6.google.com"
        ],
        "outboundTag": "warp-out"
      },
      {
        "ruleTag": "google-gemini-warp",
        "domain": [
          "geosite:google-gemini",
          "geosite:google-deepmind",
          "domain:notebooklm.google.com",
          "domain:notebooklm.google",
          "domain:generativelanguage.googleapis.com"
        ],
        "outboundTag": "warp-out"
      },
      {
        "ruleTag": "ip-block",
        "ip": [
          "geoip:private",
          "geoip:cn",
          "geoip:ir",
          "geoip:ru"
        ],
        "outboundTag": "block"
      },
      {
        "ruleTag": "domain-block",
        "domain": [
          "geosite:cn",
          "geosite:tld-cn",
          "geosite:meizu",
          "geosite:honor",
          "geosite:xiaomi",
          "geosite:category-ru",
          "geosite:category-ir",
          "geosite:category-gov-ru",
          "geosite:category-ads-all",
          "geosite:category-speedtest",
          "geosite:category-ip-geo-detect",
          "regexp:\\.ru$",
          "regexp:\\.su$",
          "regexp:\\.рф$",
          "regexp:\\.xn--p1ai$",
          "regexp:\\.tatar$",
          "domain:one.me",
          "domain:wechat.com",
          "domain:tencent.com",
          "api.beacondb.net",
          "ipv4-internet.yandex.net",
          "ipv6-internet.yandex.net"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 32768,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "sniffing": null
    },
    {
      "tag": "VLESS-SMUX-REALITY",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "vless@xtls.reality",
            "id": "$vision_uuid",
            "flow": "",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "127.0.0.1:7443",
          "xver": 0,
          "serverNames": [
            "$DOMAIN"
          ],
          "privateKey": "$private_key",
          "shortIds": [
            "$short_id_1",
            "$short_id_2",
            "$short_id_3"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    },
    {
      "tag": "warp-out",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "ForceIPv4"
      },
      "streamSettings": {
        "sockopt": {
          "interface": "warp",
          "tcpFastOpen": true
        }
      }
    }
  ]
}
EOF

    chmod 644 "$CONFIG_PATH"
    log_message "Конфигурация сгенерирована"
}

# --- Создание systemd service ---
create_systemd_service() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/${XRAY_FORK_REPO}
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
Restart=on-failure
ExecStart=${XRAY_BIN} run -config ${CONFIG_PATH}
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 /etc/systemd/system/xray.service
    log_message "Systemd service создан"
}

# --- Настройка systemd-resolved ---
setup_systemd_resolved() {
    echo -e "${CYAN}Проверка systemd-resolved...${NC}"

    if [[ -f /etc/systemd/resolved.conf ]]; then
        if grep -q "DNS=1.1.1.1" /etc/systemd/resolved.conf; then
            echo -e "${GREEN}✓ systemd-resolved уже настроен${NC}"
            return 0
        fi
    fi

    echo -e "${YELLOW}Установка и настройка systemd-resolved...${NC}"
    apt-get install -y systemd-resolved > /dev/null 2>&1

    cat > /etc/systemd/resolved.conf << EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8 1.0.0.1 8.8.4.4
#FallbackDNS=9.9.9.9
Domains=~.
DNSSEC=yes
DNSOverTLS=yes
EOF

    systemctl enable systemd-resolved.service > /dev/null 2>&1
    systemctl start systemd-resolved.service > /dev/null 2>&1
    systemctl restart systemd-resolved.service > /dev/null 2>&1

    echo -e "${GREEN}✓ systemd-resolved настроен${NC}"
    log_message "systemd-resolved настроен"
}

# --- Установка Docker ---
install_docker() {
    echo -e "${CYAN}Определение операционной системы...${NC}"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID=$ID
    else
        echo -e "${RED}Не удалось определить ОС${NC}"
        return 1
    fi

    if [[ "$OS_ID" == "ubuntu" ]]; then
        echo -e "${CYAN}Обнаружена Ubuntu. Установка Docker...${NC}"
        apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc > /dev/null 2>&1 || true
        apt-get update -qq
        apt-get install -y ca-certificates curl > /dev/null 2>&1
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        cat > /etc/apt/sources.list.d/docker.sources << EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

        apt-get update -qq
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
        systemctl enable docker > /dev/null 2>&1
        systemctl start docker > /dev/null 2>&1
        echo -e "${GREEN}✓ Docker успешно установлен!${NC}"

    elif [[ "$OS_ID" == "debian" ]]; then
        echo -e "${CYAN}Обнаружена Debian. Установка Docker...${NC}"
        apt-get update -qq
        apt-get install -y ca-certificates curl > /dev/null 2>&1
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        cat > /etc/apt/sources.list.d/docker.sources << EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

        apt-get update -qq
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
        systemctl enable docker > /dev/null 2>&1
        systemctl start docker > /dev/null 2>&1
        echo -e "${GREEN}✓ Docker успешно установлен!${NC}"

    else
        echo -e "${RED}Неподдерживаемая ОС: $OS_ID${NC}"
        return 1
    fi

    log_message "Docker установлен"
}

# --- Установка WARP ---
install_warp() {
    echo -e "${CYAN}=== Установка WARP ===${NC}"

    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}Docker не установлен. Устанавливаем...${NC}"
        install_docker || return 1
    fi

    echo -e "${YELLOW}Установка WARP через xxphantom...${NC}"
    if bash -c "$(curl -sL https://raw.githubusercontent.com/xxphantom/docker-warp-native/main/install.sh)"; then
        echo -e "${GREEN}✓ WARP успешно установлен!${NC}"
        log_message "WARP установлен"
    else
        echo -e "${RED}Ошибка установки WARP${NC}"
        return 1
    fi
}

# --- Установка и настройка TCP Brutal ---
setup_tcp_brutal() {
    echo -e "${CYAN}=== TCP Brutal ===${NC}"

    # Проверка модуля ядра
    local brutal_installed=false
    if lsmod | grep -q "^brutal" || modinfo brutal &> /dev/null; then
        brutal_installed=true
    fi

    # Проверка текущего алгоритма congestion control
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    local default_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")

    echo -e "${CYAN}Текущие настройки TCP:${NC}"
    echo -e "  Congestion Control: ${YELLOW}${current_cc}${NC}"
    echo -e "  Queue Discipline:   ${YELLOW}${default_qdisc}${NC}"
    echo -e "  Brutal module:      ${YELLOW}${brutal_installed}${NC}"
    echo

    # Шаг 1: Установка модуля ядра
    if [[ "$brutal_installed" == "false" ]]; then
        echo -e "${YELLOW}Модуль TCP Brutal не установлен в ядро.${NC}"
        echo -e "${YELLOW}Для работы Brutal необходимо установить модуль ядра.${NC}"
        echo -e "${YELLOW}Внимание: это заменит текущий алгоритм congestion control (${current_cc}).${NC}"
        echo
        read -p "Установить TCP Brutal? [y/N]: " install_confirm
        if [[ "$install_confirm" =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}Установка TCP Brutal...${NC}"
            if bash <(curl -fsSL https://tcp.hy2.sh/); then
                # Загрузка модуля
                modprobe brutal 2>/dev/null || true

                # Включение Brutal как алгоритма по умолчанию
                sysctl -w net.ipv4.tcp_congestion_control=brutal > /dev/null 2>&1
                sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1

                # === ПРОВЕРКА: модуль реально активен ===
                local actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
                if [[ "$actual_cc" != "brutal" ]]; then
                    echo -e "${RED}✗ Модуль НЕ активен (текущий cc: ${actual_cc})${NC}"
                    echo -e "${YELLOW}Установщик отработал, но алгоритм не применился.${NC}"
                    echo -e "${YELLOW}Проверьте: dmesg | tail -20 и modinfo brutal${NC}"
                    return 1
                fi

                # Автозагрузка модуля при старте системы
                echo "brutal" > /etc/modules-load.d/brutal.conf

                # Сохранение в sysctl.conf для персистентности
                if ! grep -q "tcp_congestion_control=brutal" /etc/sysctl.conf; then
                    echo "net.ipv4.tcp_congestion_control=brutal" >> /etc/sysctl.conf
                fi
                if ! grep -q "default_qdisc=fq" /etc/sysctl.conf; then
                    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
                fi

                echo -e "${GREEN}✓ TCP Brutal успешно установлен и активирован!${NC}"
                log_message "TCP Brutal установлен и активирован"
                brutal_installed=true
            else
                echo -e "${RED}Ошибка установки TCP Brutal${NC}"
                return 1
            fi
        else
            echo -e "${YELLOW}Установка отменена.${NC}"
            return 0
        fi
    else
        echo -e "${GREEN}✓ Модуль TCP Brutal уже установлен${NC}"

        # Проверка, активен ли brutal
        if [[ "$current_cc" != "brutal" ]]; then
            echo -e "${YELLOW}Brutal установлен, но не активен (текущий: ${current_cc})${NC}"
            read -p "Активировать Brutal как алгоритм по умолчанию? [Y/n]: " activate_confirm
            activate_confirm=${activate_confirm:-y}
            if [[ "$activate_confirm" =~ ^[Yy]$ ]]; then
                sysctl -w net.ipv4.tcp_congestion_control=brutal > /dev/null 2>&1
                sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1
                if ! grep -q "tcp_congestion_control=brutal" /etc/sysctl.conf; then
                    echo "net.ipv4.tcp_congestion_control=brutal" >> /etc/sysctl.conf
                    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
                fi
                echo -e "${GREEN}✓ Brutal активирован${NC}"
            fi
        else
            echo -e "${GREEN}✓ Brutal активен в системе${NC}"
        fi
    fi

    echo

    # === СТРАЖ: не писать brutal в конфиг, если модуль не активен ===
    local actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$actual_cc" != "brutal" ]]; then
        # На случай, если модуль установлен, но не прописан в автозагрузку
        if lsmod | grep -q "^brutal"; then
            echo "brutal" > /etc/modules-load.d/brutal.conf
        fi
        echo -e "${RED}Модуль brutal не активен (текущий cc: ${actual_cc})${NC}"
        echo -e "${YELLOW}Запись brutal в config.json отменена — иначе inbound перестанет принимать соединения.${NC}"
        return 1
    fi

    # Шаг 2: Проверка и настройка в config.json
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}Конфиг Xray не найден. Сначала установите Xray.${NC}"
        return 1
    fi

    echo -e "${CYAN}Настройка TCP Brutal в config.json...${NC}"

    # Поиск inbound'ов с tcp/raw транспортом
    local tcp_inbounds=$(jq -r '
        .inbounds[] |
        select(.streamSettings.network == "tcp" or .streamSettings.network == "raw") |
        .tag
    ' "$CONFIG_PATH")

    if [[ -z "$tcp_inbounds" ]]; then
        echo -e "${YELLOW}Не найдено inbound'ов с tcp/raw транспортом${NC}"
        return 0
    fi

    echo -e "${CYAN}Найдены inbound'ы с TCP/RAW транспортом:${NC}"
    local inbound_array=()
    local i=1
    while IFS= read -r tag; do
        if [[ -n "$tag" ]]; then
            # Проверка наличия brutal-opts
            local has_brutal=$(jq -r --arg tag "$tag" '
                .inbounds[] | select(.tag == $tag) |
                .smux."brutal-opts".enabled // "false"
            ' "$CONFIG_PATH")

            local status="выключен"
            [[ "$has_brutal" == "true" ]] && status="${GREEN}включен${NC}"

            echo -e "${CYAN}$i. $tag ${NC}[$status]"
            inbound_array+=("$tag")
            ((i++))
        fi
    done <<< "$tcp_inbounds"

    echo
    echo -e "${CYAN}Выберите inbound для настройки:${NC}"
    echo -e "${CYAN}0. Настроить все inbound'ы сразу${NC}"

    read -p "Выбор [1-$((i-1))] (Enter = все): " inbound_choice
    inbound_choice=${inbound_choice:-0}

    if [[ ! "$inbound_choice" =~ ^[0-9]+$ || "$inbound_choice" -gt "$((i-1))" ]]; then
        echo -e "${RED}Неверный выбор${NC}"
        return 1
    fi

    # Запрос значений up/down
    echo
    echo -e "${YELLOW}TCP Brutal требует указания пропускной способности канала.${NC}"
    echo -e "${YELLOW}Укажите скорость в человекочитаемом формате, например:${NC}"
    echo -e "  - 100 Mbps, 500 Mbps, 1 Gbps"
    echo -e "  - Можно указать разные значения для up (отдача) и down (загрузка)"
    echo

    read -p "Скорость UP (отдача с сервера) [1 Gbps]: " up_speed
    up_speed=${up_speed:-"1 Gbps"}

    read -p "Скорость DOWN (загрузка на сервер) [1 Gbps]: " down_speed
    down_speed=${down_speed:-"1 Gbps"}

    echo
    read -p "Включить TCP Brutal? [Y/n]: " enable_confirm
    enable_confirm=${enable_confirm:-y}

    local enabled="true"
    [[ ! "$enable_confirm" =~ ^[Yy]$ ]] && enabled="false"

    # Применение изменений
    local tmp_config=$(mktemp --suffix=.json)
    local tags_to_update=()

    if [[ "$inbound_choice" == "0" ]]; then
        # Все inbound'ы
        tags_to_update=("${inbound_array[@]}")
    else
        # Конкретный inbound
        tags_to_update=("${inbound_array[$((inbound_choice-1))]}")
    fi

    local update_count=0
    cp "$CONFIG_PATH" "$tmp_config"

    for tag in "${tags_to_update[@]}"; do
        local new_tmp=$(mktemp)

        if jq --arg tag "$tag" \
              --arg enabled "$enabled" \
              --arg up "$up_speed" \
              --arg down "$down_speed" \
            '.inbounds |= map(
                if .tag == $tag then
                    .smux = (.smux // {}) |
                    .smux."brutal-opts" = {
                        "enabled": ($enabled == "true"),
                        "up": $up,
                        "down": $down
                    }
                else .
                end
            )' "$tmp_config" > "$new_tmp" 2>/dev/null; then
            mv "$new_tmp" "$tmp_config"
            ((update_count++))
            local status_text="выключен"
            [[ "$enabled" == "true" ]] && status_text="включен"
            echo -e "${GREEN}✓ $tag: Brutal ${status_text} (up: ${up_speed}, down: ${down_speed})${NC}"
        else
            rm -f "$new_tmp"
            echo -e "${RED}✗ Ошибка настройки $tag${NC}"
        fi
    done

    if [[ $update_count -gt 0 ]]; then
        # Бэкап перед применением
        local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
        local backup_file="${BACKUP_DIR}/${timestamp}-config-before-brutal.json.bak"
        cp "$CONFIG_PATH" "$backup_file"
        echo -e "${GREEN}✓ Бэкап создан: $backup_file${NC}"

        # Проверка конфига ДО применения
        local test_output
        if ! test_output=$($XRAY_BIN run -test -config "$tmp_config" 2>&1); then
            echo -e "${RED}Новый конфиг не прошёл проверку xray! Изменения отменены.${NC}"
            echo -e "${YELLOW}Причина:${NC}"
            echo "$test_output" | tail -n 15
            rm -f "$tmp_config"
            return 1
        fi

        mv "$tmp_config" "$CONFIG_PATH"
        chmod 644 "$CONFIG_PATH"

        # Перезапуск Xray
        if systemctl restart xray; then
            echo -e "${GREEN}✓ Xray перезапущен с новыми настройками${NC}"
            log_message "TCP Brutal настроен для $update_count inbound'ов"
        else
            echo -e "${RED}Ошибка перезапуска Xray${NC}"
            echo -e "${YELLOW}Проверьте конфиг: journalctl -u xray -n 20${NC}"
        fi
    else
        rm -f "$tmp_config"
        echo -e "${RED}Не удалось применить изменения${NC}"
    fi
}

# --- Быстрый перезапуск Xray с выводом статуса ---
restart_xray_status() {
    echo -e "${CYAN}=== Перезапуск Xray ===${NC}"
    if [[ ! -f /etc/systemd/system/xray.service ]]; then
        echo -e "${RED}Сервис Xray не установлен. Сначала установите Xray.${NC}"
        return 1
    fi

    # Принудительное снятие статистики ДО перезапуска, чтобы не потерять трафик
    if [[ -x /usr/local/bin/xray-stats-collect.sh ]]; then
        /usr/local/bin/xray-stats-collect.sh > /dev/null 2>&1
    fi

    echo -e "${YELLOW}Перезапуск Xray...${NC}"
    if systemctl restart xray; then
        echo -e "${GREEN}✓ Xray перезапущен. Ожидание 3 секунд...${NC}"
        sleep 3
        echo
        echo -e "${CYAN}=== Статус Xray ===${NC}"
        systemctl status xray --no-pager
    else
        echo -e "${RED}✗ Ошибка перезапуска Xray${NC}"
        echo
        echo -e "${YELLOW}Детали ошибки:${NC}"
        journalctl -u xray.service -n 20 --no-pager
    fi
}

# --- Обновление routing ---
update_routing() {
    echo -e "${CYAN}=== Обновление routing ===${NC}"
    if [[ -z "$ROUTING_URL" ]]; then
        echo -e "${YELLOW}URL для routing не настроен. Используйте пункт меню 'Смена источника обновлений routing'${NC}"
        return 1
    fi
    echo -e "${YELLOW}Скачивание routing.json...${NC}"
    local tmp_file=$(mktemp)
    # -f: не сохранять тело при HTTP-ошибках (404/500)
    if ! curl -sfL "$ROUTING_URL" -o "$tmp_file"; then
        echo -e "${RED}Ошибка скачивания routing (HTTP или сеть)${NC}"
        rm -f "$tmp_file"
        return 1
    fi

    if ! jq empty "$tmp_file" 2>/dev/null; then
        echo -e "${RED}Скачанный файл не является валидным JSON${NC}"
        rm -f "$tmp_file"
        return 1
    fi

    local routing_obj=""
    if jq -e '.routing' "$tmp_file" > /dev/null 2>&1; then
        routing_obj=$(jq '.routing' "$tmp_file")
    else
        routing_obj=$(jq '.' "$tmp_file")
    fi

    # Проверка структуры
    if ! echo "$routing_obj" | jq -e 'type == "object" and (.rules | type == "array")' > /dev/null 2>&1; then
        echo -e "${RED}Скачанный файл не похож на routing: нет объекта с массивом rules.${NC}"
        echo -e "${YELLOW}Первые 200 байт ответа:${NC}"
        head -c 200 "$tmp_file"; echo
        rm -f "$tmp_file"
        return 1
    fi

    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local backup_file="${BACKUP_DIR}/${timestamp}-config-before-routing.json.bak"
    cp "$CONFIG_PATH" "$backup_file" && echo -e "${GREEN}✓ Бэкап: $backup_file${NC}"

    local tmp_config=$(mktemp --suffix=.json)
    if jq --argjson routing "$routing_obj" '.routing = $routing' "$CONFIG_PATH" > "$tmp_config" 2>/dev/null; then
        # Тест конфига перед применением
        local test_output
        if ! test_output=$($XRAY_BIN run -test -config "$tmp_config" 2>&1); then
            echo -e "${RED}Новый конфиг не прошёл проверку xray! Изменения отменены.${NC}"
            echo -e "${YELLOW}Причина:${NC}"
            echo "$test_output" | tail -n 15
            rm -f "$tmp_config" "$tmp_file"
            return 1
        fi
        mv "$tmp_config" "$CONFIG_PATH"
        chmod 644 "$CONFIG_PATH"
        systemctl restart xray
        echo -e "${GREEN}✓ Routing успешно обновлён!${NC}"
        log_message "Routing обновлён из $ROUTING_URL"
    else
        echo -e "${RED}Ошибка обновления конфига${NC}"
        rm -f "$tmp_config"
    fi
    rm -f "$tmp_file"
}

# --- Смена источника routing ---
change_routing_source() {
    echo -e "${CYAN}=== Смена источника routing ===${NC}"
    echo -e "${YELLOW}Введите URL для routing.json:${NC}"
    read -p "URL: " new_url

    if [[ -n "$new_url" ]]; then
        ROUTING_URL="$new_url"
        save_env_config
        echo -e "${GREEN}✓ URL сохранён: $ROUTING_URL${NC}"
        log_message "URL routing изменён на: $ROUTING_URL"
    else
        echo -e "${RED}URL не указан${NC}"
    fi
}

# --- Открытие config.json ---
open_config() {
    echo -e "${CYAN}=== Открытие config.json ===${NC}"

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}Конфиг не найден${NC}"
        return 1
    fi

    # Проверяем существование xray-env.conf
    if [[ ! -f "$ENV_CONFIG_PATH" ]]; then
        echo -e "${YELLOW}Файл конфигурации скрипта не найден. Создаём ${ENV_CONFIG_PATH}...${NC}"
        cat > "$ENV_CONFIG_PATH" << EOF
# Xray Environment Configuration
ROUTING_URL=""
DOMAIN=""
EDITOR=""
EDITOR_CONFIGURED="false"
LOG_ROTATE_ENABLED="true"
LOG_ROTATE_TIME="06:00"
LOG_ROTATE_KEEP="30"
EOF
        chmod 644 "$ENV_CONFIG_PATH"
        echo -e "${GREEN}✓ Файл создан${NC}"
        echo
    fi

    # Проверка: был ли редактор выбран через наше меню?
    if [[ "$EDITOR_CONFIGURED" != "true" ]]; then
        echo -e "${YELLOW}Текстовый редактор не настроен. Выберите редактор:${NC}"
        echo -e "${CYAN}1. nano${NC}"
        echo -e "${CYAN}2. micro${NC}"
        echo -e "${CYAN}3. vi${NC}"
        echo -e "${CYAN}4. vim${NC}"
        echo -e "${CYAN}5. neovim${NC}"

        read -p "Выбор [1-5]: " editor_choice

        case "$editor_choice" in
            1) EDITOR="nano" ;;
            2) EDITOR="micro" ;;
            3) EDITOR="vi" ;;
            4) EDITOR="vim" ;;
            5) EDITOR="nvim" ;;
            *)
                echo -e "${RED}Неверный выбор${NC}"
                return 1
                ;;
        esac

        EDITOR_CONFIGURED="true"
        save_env_config

        echo -e "${GREEN}✓ Редактор '${EDITOR}' сохранён.${NC}"
        echo -e "${YELLOW}Чтобы изменить редактор, отредактируйте файл:${NC}"
        echo -e "${CYAN}$ENV_CONFIG_PATH${NC}"
        echo -e "${YELLOW}изменив переменную EDITOR и оставив EDITOR_CONFIGURED=\"true\"${NC}"
        echo
        read -p "Нажмите Enter для продолжения..."
    fi

    # Проверка установки редактора
    if ! command -v "$EDITOR" &> /dev/null; then
        echo -e "${YELLOW}Редактор '$EDITOR' не установлен. Устанавливаем...${NC}"
        if ! apt-get install -y "$EDITOR" > /dev/null 2>&1; then
            echo -e "${RED}Не удалось установить '$EDITOR'${NC}"
            echo -e "${YELLOW}Отредактируйте ${ENV_CONFIG_PATH} вручную${NC}"
            return 1
        fi
        echo -e "${GREEN}✓ Редактор '$EDITOR' установлен${NC}"
    fi

    echo -e "${CYAN}Открытие конфига в ${EDITOR}...${NC}"
    "$EDITOR" "$CONFIG_PATH"
}

# --- Создание бэкапа ---
create_backup() {
    echo -e "${CYAN}=== Создание бэкапа ===${NC}"

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}Конфиг не найден${NC}"
        return 1
    fi

    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local backup_file="${BACKUP_DIR}/${timestamp}-config.json.bak"

    cp "$CONFIG_PATH" "$backup_file"
    echo -e "${GREEN}✓ Бэкап создан: $backup_file${NC}"
    log_message "Бэкап создан: $backup_file"
}

# --- Восстановление из бэкапа ---
restore_backup() {
    echo -e "${CYAN}=== Восстановление из бэкапа ===${NC}"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo -e "${RED}Папка бэкапов не найдена${NC}"
        return 1
    fi

    local backups=($(ls -1 "$BACKUP_DIR"/*.bak 2>/dev/null | sort -r))

    if [[ ${#backups[@]} -eq 0 ]]; then
        echo -e "${RED}Бэкапы не найдены${NC}"
        return 1
    fi

    echo -e "${CYAN}Доступные бэкапы:${NC}"
    for i in "${!backups[@]}"; do
        echo -e "${CYAN}$((i+1)). ${backups[$i]}${NC}"
    done

    read -p "Выберите номер бэкапа [1-${#backups[@]}]: " choice

    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#backups[@]}" ]]; then
        local selected_backup="${backups[$((choice-1))]}"
        cp "$selected_backup" "$CONFIG_PATH"
        systemctl restart xray
        echo -e "${GREEN}✓ Конфиг восстановлен из: $selected_backup${NC}"
        log_message "Конфиг восстановлен из: $selected_backup"
    else
        echo -e "${RED}Неверный выбор${NC}"
    fi
}

# --- Пакетное добавление пользователей ---
batch_add_users() {
    echo -e "${CYAN}=== Пакетное добавление пользователей ===${NC}"
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}Конфиг не найден${NC}"
        return 1
    fi

    # Ищем все VLESS-инбаунды
    local vless_inbounds_json
    vless_inbounds_json=$(jq -c '.inbounds[] | select(.protocol == "vless")' "$CONFIG_PATH" 2>/dev/null)

    if [[ -z "$vless_inbounds_json" ]]; then
        echo -e "${YELLOW}VLESS-inbounds не найдены${NC}"
        return 0
    fi

    local inbounds=()
    local tags=()
    local has_untagged=false

    while IFS= read -r inb; do
        local tag=$(echo "$inb" | jq -r '.tag // empty')
        if [[ -z "$tag" ]]; then
            has_untagged=true
            continue
        fi
        inbounds+=("$inb")
        tags+=("$tag")
    done <<< "$vless_inbounds_json"

    if [[ "$has_untagged" == "true" ]]; then
        echo -e "${YELLOW}⚠ Найден VLESS-inbound без tag, он пропущен${NC}"
    fi

    if [[ ${#tags[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Нет доступных VLESS-inbounds с тегами${NC}"
        return 0
    fi

    echo -e "${CYAN}Доступные VLESS-inbounds:${NC}"
    for i in "${!tags[@]}"; do
        echo -e "${CYAN}$((i+1)). ${tags[$i]}${NC}"
    done
    echo -e "${CYAN}0. Выход в главное меню${NC}"

    local choice
    while true; do
        read -p "Выберите inbound [1-${#tags[@]}] или 0 для выхода: " choice
        if [[ "$choice" == "0" ]]; then
            echo -e "${YELLOW}Операция отменена${NC}"
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#tags[@]}" ]]; then
            break
        else
            echo -e "${RED}Неверный ввод, повторите попытку${NC}"
        fi
    done

    local selected_idx=$((choice-1))
    local selected_tag="${tags[$selected_idx]}"
    local selected_inb="${inbounds[$selected_idx]}"

    # Проверка settings и clients
    local has_settings=$(echo "$selected_inb" | jq 'has("settings")')
    if [[ "$has_settings" != "true" ]]; then
        echo -e "${RED}Ошибка: в выбранном inbound отсутствует блок settings${NC}"
        return 1
    fi

    local clients_type=$(echo "$selected_inb" | jq -r '.settings.clients | type // "null"')
    if [[ "$clients_type" == "null" ]]; then
        read -p "В выбранном inbound нет массива clients. Создать его? [Y/n]: " create_clients
        create_clients=${create_clients:-y}
        if [[ ! "$create_clients" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Операция отменена${NC}"
            return 0
        fi
    elif [[ "$clients_type" != "array" ]]; then
        echo -e "${RED}Ошибка: settings.clients не является массивом${NC}"
        return 1
    fi

    echo -e "${YELLOW}Введите email'ы через пробел (0 для выхода):${NC}"
    read -p "Email'ы: " -r emails_input
    if [[ "$emails_input" == "0" ]]; then
        echo -e "${YELLOW}Операция отменена${NC}"
        return 0
    fi

    # Фильтрация пустых значений
    local users=()
    for u in $emails_input; do
        if [[ -n "$u" ]]; then
            users+=("$u")
        fi
    done

    if [[ ${#users[@]} -eq 0 ]]; then
        echo -e "${RED}Не введено ни одного email${NC}"
        return 1
    fi

    # Проверка дубликатов внутри введённого списка
    local unique_users=($(echo "${users[@]}" | tr ' ' '\n' | awk '!seen[$0]++'))
    if [[ ${#unique_users[@]} -ne ${#users[@]} ]]; then
        echo -e "${RED}⚠ Обнаружены дубликаты во введённом списке. Операция прервана.${NC}"
        return 1
    fi

    # Проверка дубликатов в выбранном inbound
    local existing_emails=$(echo "$selected_inb" | jq -r '.settings.clients[]?.email // empty' 2>/dev/null)
    for u in "${users[@]}"; do
        if echo "$existing_emails" | grep -qx "$u"; then
            echo -e "${RED}⚠ Email '$u' уже существует в $selected_tag. Операция прервана.${NC}"
            return 1
        fi
    done

    # Предложение бэкапа
    read -p "Создать бэкап config.json перед изменениями? [Y/n]: " backup_choice
    backup_choice=${backup_choice:-y}
    if [[ "$backup_choice" =~ ^[Yy]$ ]]; then
        local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
        local backup_file="${BACKUP_DIR}/${timestamp}-config.json.bak"
        if cp "$CONFIG_PATH" "$backup_file"; then
            echo -e "${GREEN}✓ Бэкап создан: $backup_file${NC}"
        else
            echo -e "${RED}✗ Ошибка создания бэкапа. Операция прервана.${NC}"
            return 1
        fi
    fi

    # Логика flow
    local tag_lower=$(echo "$selected_tag" | tr '[:upper:]' '[:lower:]')
    local flow_value="xtls-rprx-vision"
    if [[ "$tag_lower" == *"smux"* ]]; then
        flow_value=""
    fi

    local tmp_config=$(mktemp)
    local clients_array="[]"
    local current_date=$(date '+%Y-%m-%d %H:%M:%S')
    local users_list_success=true
    local added_report=()

    # Генерация UUID и подготовка JSON массива
    for email in "${users[@]}"; do
        local uuid=$(generate_uuid)

        added_report+=("${email} --- ${uuid}")

        clients_array=$(echo "$clients_array" | jq --arg e "$email" --arg u "$uuid" --arg f "$flow_value" \
            '. + [{"email": $e, "id": $u, "flow": $f, "level": 0}]')

        # Запись в users.list
        if ! echo "ADD:${selected_tag}:${email}:${uuid}:${current_date}" >> "$USERS_LIST"; then
            users_list_success=false
        fi
    done

    # Применение изменений к конфигу
    if jq --arg tag "$selected_tag" --argjson new_clients "$clients_array" '
        .inbounds |= map(
            if .tag == $tag then
                .settings = (.settings // {}) |
                .settings.clients = ((.settings.clients // []) + $new_clients)
            else .
            end
        )
    ' "$CONFIG_PATH" > "$tmp_config" 2>/dev/null; then
        mv "$tmp_config" "$CONFIG_PATH"
        local count=${#users[@]}
        local word="пользователей"

        if (( count % 10 == 1 && count % 100 != 11 )); then
            word="пользователь"
        elif (( count % 10 >= 2 && count % 10 <= 4 && (count % 100 < 10 || count % 100 >= 20) )); then
            word="пользователя"
        else
            word="пользователей"
        fi

        echo -e "${GREEN}✓ Успешно добавлено ${count} ${word}!${NC}"

        for line in "${added_report[@]}"; do
            echo -e "${CYAN}${line}${NC}"
        done

        log_message "Добавлено ${count} пользователей в $selected_tag"
    else
        rm -f "$tmp_config"
        echo -e "${RED}✗ Ошибка применения изменений к config.json${NC}"
        return 1
    fi

    if [[ "$users_list_success" == "false" ]]; then
        echo -e "${RED}⚠ Внимание: не удалось обновить $USERS_LIST${NC}"
    else
        echo -e "${CYAN}Изменения записаны в ${USERS_LIST}${NC}"
    fi

    echo -e "${YELLOW}Не забудьте перезапустить Xray: ${GREEN}systemctl restart xray${NC}"
}

# --- Пакетное удаление пользователей ---
batch_remove_users() {
    echo -e "${CYAN}=== Пакетное удаление пользователей ===${NC}"
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}Конфиг не найден${NC}"
        return 1
    fi

    local vless_inbounds_json
    vless_inbounds_json=$(jq -c '.inbounds[] | select(.protocol == "vless")' "$CONFIG_PATH" 2>/dev/null)

    if [[ -z "$vless_inbounds_json" ]]; then
        echo -e "${YELLOW}VLESS-inbounds не найдены${NC}"
        return 0
    fi

    local inbounds=()
    local tags=()
    local has_untagged=false

    while IFS= read -r inb; do
        local tag=$(echo "$inb" | jq -r '.tag // empty')
        if [[ -z "$tag" ]]; then
            has_untagged=true
            continue
        fi
        inbounds+=("$inb")
        tags+=("$tag")
    done <<< "$vless_inbounds_json"

    if [[ "$has_untagged" == "true" ]]; then
        echo -e "${YELLOW}⚠ Найден VLESS-inbound без tag, он пропущен${NC}"
    fi

    if [[ ${#tags[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Нет доступных VLESS-inbounds с тегами${NC}"
        return 0
    fi

    echo -e "${CYAN}Доступные VLESS-inbounds (можно выбрать несколько через пробел):${NC}"
    for i in "${!tags[@]}"; do
        echo -e "${CYAN}$((i+1)). ${tags[$i]}${NC}"
    done
    echo -e "${CYAN}0. Выход в главное меню${NC}"

    local selected_tags=()
    while true; do
        read -p "Выберите inbound'ы [1-${#tags[@]}] через пробел или 0 для выхода: " -r choices_input
        if [[ "$choices_input" == "0" ]]; then
            echo -e "${YELLOW}Операция отменена${NC}"
            return 0
        fi

        local valid=true
        local chosen_indices=()
        for c in $choices_input; do
            if [[ "$c" =~ ^[0-9]+$ && "$c" -ge 1 && "$c" -le "${#tags[@]}" ]]; then
                chosen_indices+=("$c")
            else
                valid=false
                break
            fi
        done

        if [[ "$valid" == "true" && ${#chosen_indices[@]} -gt 0 ]]; then
            local unique_indices=($(echo "${chosen_indices[@]}" | tr ' ' '\n' | awk '!seen[$0]++'))
            for idx in "${unique_indices[@]}"; do
                selected_tags+=("${tags[$((idx-1))]}")
            done
            break
        else
            echo -e "${RED}Неверный ввод, повторите попытку${NC}"
        fi
    done

    echo -e "${YELLOW}Введите email'ы или UUID'ы для удаления через пробел (0 для выхода):${NC}"
    read -p "Значения: " -r search_input
    if [[ "$search_input" == "0" ]]; then
        echo -e "${YELLOW}Операция отменена${NC}"
        return 0
    fi

    local search_values=()
    for v in $search_input; do
        if [[ -n "$v" ]]; then
            search_values+=("$v")
        fi
    done

    if [[ ${#search_values[@]} -eq 0 ]]; then
        echo -e "${RED}Не введено ни одного значения${NC}"
        return 1
    fi

    # Предложение бэкапа
    read -p "Создать бэкап config.json перед изменениями? [Y/n]: " backup_choice
    backup_choice=${backup_choice:-y}
    if [[ "$backup_choice" =~ ^[Yy]$ ]]; then
        local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
        local backup_file="${BACKUP_DIR}/${timestamp}-config.json.bak"
        if cp "$CONFIG_PATH" "$backup_file"; then
            echo -e "${GREEN}✓ Бэкап создан: $backup_file${NC}"
        else
            echo -e "${RED}✗ Ошибка создания бэкапа. Операция прервана.${NC}"
            return 1
        fi
    fi

    local tmp_config=$(mktemp)
    cp "$CONFIG_PATH" "$tmp_config"

    local found_count=0
    local not_found_values=()
    local current_date=$(date '+%Y-%m-%d %H:%M:%S')
    local users_list_success=true

    for value in "${search_values[@]}"; do
        local found_in_any=false
        local is_uuid=false

        if [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            is_uuid=true
        fi

        for tag in "${selected_tags[@]}"; do
            local client_info=""
            if [[ "$is_uuid" == "true" ]]; then
                client_info=$(jq -r --arg tag "$tag" --arg uuid "$value" '
                    .inbounds[] | select(.tag == $tag) | .settings.clients[]? | select(.id == $uuid) | "\(.email // "no-email")\t\(.id)"
                ' "$tmp_config" 2>/dev/null)
            else
                client_info=$(jq -r --arg tag "$tag" --arg email "$value" '
                    .inbounds[] | select(.tag == $tag) | .settings.clients[]? | select(.email == $email) | "\(.email // "no-email")\t\(.id)"
                ' "$tmp_config" 2>/dev/null)
            fi

            if [[ -n "$client_info" ]]; then
                found_in_any=true
                while IFS= read -r info; do
                    local c_email=$(echo "$info" | cut -d$'\t' -f1)
                    local c_uuid=$(echo "$info" | cut -d$'\t' -f2)

                    # Удаление из конфига
                    if [[ "$is_uuid" == "true" ]]; then
                        jq --arg tag "$tag" --arg uuid "$value" '
                            .inbounds |= map(if .tag == $tag then .settings.clients |= map(select(.id != $uuid)) else . end)
                        ' "$tmp_config" > "${tmp_config}.tmp" && mv "${tmp_config}.tmp" "$tmp_config"
                    else
                        jq --arg tag "$tag" --arg email "$value" '
                            .inbounds |= map(if .tag == $tag then .settings.clients |= map(select(.email != $email)) else . end)
                        ' "$tmp_config" > "${tmp_config}.tmp" && mv "${tmp_config}.tmp" "$tmp_config"
                    fi

                    # Запись в users.list
                    if ! echo "DEL:${tag}:${c_email}:${c_uuid}:${current_date}" >> "$USERS_LIST"; then
                        users_list_success=false
                    fi
                    ((found_count++))
                done <<< "$client_info"
            else
                echo -e "${RED}⚠ $value не найден в $tag${NC}"
            fi
        done

        if [[ "$found_in_any" == "false" ]]; then
            not_found_values+=("$value")
        fi
    done

    if [[ $found_count -gt 0 ]]; then
        mv "$tmp_config" "$CONFIG_PATH"
        echo -e "${GREEN}✓ Удалено $found_count записей(и)${NC}"
        log_message "Удалено $found_count записей(и)"
    else
        rm -f "$tmp_config"
    fi
    rm -f "${tmp_config}.tmp"

    if [[ ${#not_found_values[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠ Не найдено ни в одном из выбранных inbound'ов: ${not_found_values[*]}${NC}"
    fi

    if [[ $found_count -gt 0 ]]; then
        if [[ "$users_list_success" == "false" ]]; then
            echo -e "${RED}⚠ Внимание: не удалось обновить $USERS_LIST${NC}"
        else
            echo -e "${CYAN}Изменения записаны в ${USERS_LIST}${NC}"
        fi
        echo -e "${YELLOW}Не забудьте перезапустить Xray: ${GREEN}systemctl restart xray${NC}"
    fi
}

# --- Выбор файла access.log (текущий + ротированные) ---
CHOSEN_LOG=""
choose_access_log() {
    CHOSEN_LOG=""
    local files=()
    [[ -f /var/log/xray/access.log ]] && files+=("/var/log/xray/access.log")
    while IFS= read -r f; do
        files+=("$f")
    done < <(ls -1 /var/log/xray/access-????-??-??.log 2>/dev/null | sort -r)

    if [[ ${#files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Файлы access.log не найдены${NC}"
        return 1
    fi

    echo -e "${CYAN}Доступные файлы логов:${NC}"
    local i=1
    local f base
    for f in "${files[@]}"; do
        base=$(basename "$f")
        if [[ "$base" == "access.log" ]]; then
            echo -e "${CYAN}${i}. ${base} (текущий)${NC}"
        else
            echo -e "${CYAN}${i}. ${base}${NC}"
        fi
        ((i++))
    done

    local choice
    read -p "Выберите файл [1-${#files[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#files[@]} ]]; then
        CHOSEN_LOG="${files[$((choice-1))]}"
        return 0
    fi
    echo -e "${RED}Неверный выбор${NC}"
    return 1
}

# --- Строки пользователя из access.log ---
# Современный формат Xray: "... from IP:port accepted tcp:domain:443 [inbound-tag] email: user@x"
# Легаси-формат: "... IP:port accepted tcp:domain:443 [user@x]"
grep_user_lines() {
    local email="$1" file="$2" out="$3"
    grep -F -- "email: ${email}" "$file" 2>/dev/null > "$out"
    if [[ ! -s "$out" ]]; then
        grep -F -- "${email}]" "$file" 2>/dev/null > "$out"
    fi
    if [[ ! -s "$out" ]]; then
        grep -F -- "$email" "$file" 2>/dev/null > "$out"
    fi
}

# --- Статистика пользователя по времени ---
user_stats_by_time() {
    local email="$1"
    choose_access_log || return 0

    echo -e "${YELLOW}Укажите период:${NC}"
    echo -e "${YELLOW}  - дата, с которой вывести записи (YYYY-MM-DD)${NC}"
    echo -e "${YELLOW}  - количество последних дней (число)${NC}"
    echo -e "${YELLOW}  - Enter: весь файл${NC}"
    read -p "Период: " period

    local since=""
    if [[ "$period" =~ ^[0-9]+$ ]]; then
        since=$(date -d "${period} days ago" +%Y/%m/%d 2>/dev/null)
    elif [[ "$period" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        since="${period//-//}"
    elif [[ -n "$period" ]]; then
        echo -e "${RED}Не распознан формат периода — будет показан весь файл${NC}"
    fi

    local tmp
    tmp=$(mktemp)
    grep_user_lines "$email" "$CHOSEN_LOG" "$tmp"
    if [[ -n "$since" ]]; then
        awk -v s="$since" 'substr($1,1,10) >= s' "$tmp" > "${tmp}.f" && mv "${tmp}.f" "$tmp"
    fi

    local count
    count=$(wc -l < "$tmp")
    echo -e "${YELLOW}Файл: $(basename "$CHOSEN_LOG") | записей: ${count}${NC}"
    if [[ -n "$since" ]]; then
        echo -e "${YELLOW}Период: с ${since//\//-}${NC}"
    fi
    if (( count == 0 )); then
        local total_lines
        total_lines=$(wc -l < "$CHOSEN_LOG" 2>/dev/null || echo 0)
        if [[ "$total_lines" =~ ^[0-9]+$ ]] && (( total_lines == 0 )); then
            echo -e "${RED}Файл пуст.${NC}"
            echo -e "${YELLOW}Проверьте, что в config.json задан log.access и Xray перезапущен после изменений.${NC}"
        else
            echo -e "${YELLOW}Записей для ${email} не найдено (всего строк в файле: ${total_lines}).${NC}"
            echo -e "${YELLOW}Последние строки файла для сверки формата:${NC}"
            tail -n 3 "$CHOSEN_LOG"
        fi
    else
        echo -e "${YELLOW}═══════════════════════════${NC}"
        cat "$tmp"
    fi
    rm -f "$tmp"
}

# --- Статистика пользователя по доменам ---
user_stats_by_domain() {
    local email="$1"
    choose_access_log || return 0

    read -p "Сколько последних уникальных доменов вывести (0-1000, 0 = все) [100]: " dom_count
    dom_count=${dom_count:-100}
    if [[ ! "$dom_count" =~ ^[0-9]+$ ]] || (( dom_count < 0 || dom_count > 1000 )); then
        echo -e "${RED}Неверное значение (нужно число 0-1000)${NC}"
        return 1
    fi

    local tmp
    tmp=$(mktemp)
    grep_user_lines "$email" "$CHOSEN_LOG" "$tmp"

    local domains
    domains=$(awk '{for (i = 1; i <= NF; i++) if ($i ~ /^(tcp|udp):/) { d = $i; sub(/^(tcp|udp):/, "", d); sub(/:[0-9]+$/, "", d); if (d ~ /^[0-9.]+$/ || index(d, ":") > 0) next; print d; break } }' "$tmp" | \
        tac | awk '!seen[$0]++')
    rm -f "$tmp"

    if (( dom_count > 0 )); then
        domains=$(echo "$domains" | head -n "$dom_count")
    fi

    local total
    total=$(printf '%s\n' "$domains" | sed '/^$/d' | wc -l)

    if (( total == 0 )); then
        local total_lines
        total_lines=$(wc -l < "$CHOSEN_LOG" 2>/dev/null || echo 0)
        if [[ "$total_lines" =~ ^[0-9]+$ ]] && (( total_lines == 0 )); then
            echo -e "${RED}Файл пуст.${NC}"
            echo -e "${YELLOW}Проверьте, что в config.json задан log.access и Xray перезапущен после изменений.${NC}"
        else
            echo -e "${YELLOW}Доменов для ${email} не найдено (всего строк в файле: ${total_lines}).${NC}"
            echo -e "${YELLOW}Последние строки файла для сверки формата:${NC}"
            tail -n 3 "$CHOSEN_LOG"
        fi
        return 0
    fi

    echo -e "${YELLOW}Последние домены для ${email} (уникальных: ${total}):${NC}"
    echo -e "${YELLOW}═══════════════════════════${NC}"
    printf '%s\n' "$domains" | while IFS= read -r d; do
        [[ -n "$d" ]] && echo -e "  ${GREEN}• ${d}${NC}"
    done
}

# --- Статистика пользователя ---
user_stats() {
    echo -e "${CYAN}=== Статистика пользователя ===${NC}"

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}Конфиг не найден${NC}"
        return 1
    fi

    read -p "Введите email или UUID: " search_value

    local uuid=""
    local email=""

    if [[ "$search_value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        uuid="$search_value"
        email=$(jq -r --arg uuid "$uuid" '
            .inbounds[] |
            select(.settings.clients != null) |
            .settings.clients[] |
            select(.id == $uuid) |
            .email
        ' "$CONFIG_PATH" | head -n 1)
    else
        email="$search_value"
        uuid=$(jq -r --arg email "$email" '
            .inbounds[] |
            select(.settings.clients != null) |
            .settings.clients[] |
            select(.email == $email) |
            .id
        ' "$CONFIG_PATH" | head -n 1)
    fi

    if [[ -z "$uuid" || -z "$email" ]]; then
        echo -e "${RED}Пользователь не найден${NC}"
        return 1
    fi

    echo -e "${CYAN}Email: ${GREEN}${email}${NC}"
    echo -e "${CYAN}UUID:  ${GREEN}${uuid}${NC}"
    echo

    local access_path
    access_path=$(jq -r '.log.access // empty' "$CONFIG_PATH" 2>/dev/null)
    if [[ -z "$access_path" ]]; then
        echo -e "${RED}Внимание: в config.json не задан log.access — access.log не пишется,${NC}"
        echo -e "${RED}статистика по логам будет пустой.${NC}"
        echo
    fi

    # Получение статистики через API
    echo -e "${CYAN}Получение статистики трафика...${NC}"

    local stats_raw=$(xray api statsquery --server="$API_SERVER" 2>/dev/null)

    if [[ -z "$stats_raw" ]]; then
        echo -e "${YELLOW}Не удалось получить статистику (Xray может быть не запущен или API недоступен)${NC}"
    else
        local user_stats=$(echo "$stats_raw" | jq -r --arg email "$email" '
            .stat[] |
            select(.name | contains($email)) |
            .name as $name | .value as $value |
            if ($name | contains("uplink")) then
                "↑ Upload: \($value) bytes"
            elif ($name | contains("downlink")) then
                "↓ Download: \($value) bytes"
            else
                "\($name): \($value)"
            end
        ' 2>/dev/null)

        if [[ -n "$user_stats" ]]; then
            echo -e "${YELLOW}Статистика трафика для ${email}:${NC}"
            echo "$user_stats" | while IFS= read -r line; do
                if [[ "$line" =~ ^[↑↓] ]]; then
                    local bytes=$(echo "$line" | grep -oE '[0-9]+')
                    local direction=$(echo "$line" | cut -d: -f1)
                    if [[ -n "$bytes" ]]; then
                        local human=$(numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes} bytes")
                        echo -e "${GREEN}${direction}: ${human}${NC}"
                    else
                        echo -e "${GREEN}${line}${NC}"
                    fi
                else
                    echo -e "${GREEN}${line}${NC}"
                fi
            done

            local total=$(echo "$stats_raw" | jq -r --arg email "$email" '
                [.stat[] | select(.name | contains($email)) | .value] | add // 0
            ' 2>/dev/null)

            if [[ -n "$total" && "$total" != "0" ]]; then
                local human_total=$(numfmt --to=iec-i --suffix=B "$total" 2>/dev/null || echo "${total} bytes")
                echo -e "${YELLOW}═══════════════════════════${NC}"
                echo -e "${YELLOW}Σ Всего: ${GREEN}${human_total}${NC}"
            fi
        else
            echo -e "${YELLOW}Статистика трафика отсутствует (пользователь ещё не использовал сервис)${NC}"
        fi
    fi

    echo

    # Статистика по access.log
    echo -e "${CYAN}Статистика по access.log:${NC}"
    echo -e "${CYAN}1. По времени${NC}"
    echo -e "${CYAN}2. По доменам${NC}"
    echo -e "${CYAN}0. Назад${NC}"
    read -p "Выбор [0-2]: " log_choice
    case "$log_choice" in
        1) user_stats_by_time "$email" ;;
        2) user_stats_by_domain "$email" ;;
        0) return 0 ;;
        *) echo -e "${RED}Неверный выбор${NC}" ;;
    esac
}

# --- Статистика сервера ---
server_stats() {
    echo -e "${CYAN}=== Статистика сервера ===${NC}"

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}Конфиг не найден${NC}"
        return 1
    fi

    # Проверка, запущен ли Xray
    if ! systemctl is-active --quiet xray; then
        echo -e "${YELLOW}Xray не запущен. Статистика недоступна.${NC}"
        read -p "Запустить Xray? [Y/n]: " start_confirm
        start_confirm=${start_confirm:-y}
        if [[ "$start_confirm" =~ ^[Yy]$ ]]; then
            systemctl start xray
            sleep 2
            if ! systemctl is-active --quiet xray; then
                echo -e "${RED}Не удалось запустить Xray${NC}"
                return 1
            fi
            echo -e "${GREEN}✓ Xray запущен${NC}"
        else
            return 0
        fi
    fi

    echo -e "${CYAN}Получение общей статистики...${NC}"
    echo

    local all_stats=$(xray api statsquery --server="$API_SERVER" 2>/dev/null)

    if [[ -z "$all_stats" ]]; then
        echo -e "${RED}Не удалось получить статистику от Xray API${NC}"
        echo -e "${YELLOW}Проверьте, что API доступен на ${API_SERVER}${NC}"
        return 1
    fi

    local has_stat=$(echo "$all_stats" | jq 'has("stat")' 2>/dev/null)
    if [[ "$has_stat" != "true" ]]; then
        echo -e "${YELLOW}Статистика пуста или API не вернул данные${NC}"
        echo -e "${YELLOW}Возможно, Xray был перезапущен и счётчики сброшены${NC}"
        return 0
    fi

    format_bytes() {
        local bytes=$1
        if [[ -z "$bytes" || "$bytes" == "null" || "$bytes" == "0" ]]; then
            echo "0 B"
        else
            numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes} B"
        fi
    }

    # ═══════════════════════════════════════════
    # Общий inbound/outbound трафик
    # ═══════════════════════════════════════════
    echo -e "${YELLOW}═══════════════════════════════════${NC}"
    echo -e "${YELLOW}  Трафик по inbound'ам${NC}"
    echo -e "${YELLOW}═══════════════════════════════════${NC}"

    local inbound_stats=$(echo "$all_stats" | jq -r '
        .stat[] |
        select(.name | test("^inbound>>>")) |
        .name as $name | .value as $value |
        ($name | split(">>>")) as $parts |
        {inbound: $parts[1], direction: $parts[3], bytes: $value}
    ' 2>/dev/null)

    if [[ -n "$inbound_stats" ]]; then
        echo "$inbound_stats" | jq -rs '
            group_by(.inbound) |
            .[] |
            {
                inbound: .[0].inbound,
                up: (map(select(.direction == "uplink")) | .[0].bytes // 0),
                down: (map(select(.direction == "downlink")) | .[0].bytes // 0)
            } |
            "\(.inbound): ↑ \(.up) | ↓ \(.down)"
        ' 2>/dev/null | while IFS= read -r line; do
            local inbound_name=$(echo "$line" | cut -d: -f1)
            local stats_part=$(echo "$line" | cut -d: -f2-)

            local up=$(echo "$stats_part" | grep -oE '↑ [0-9]+' | awk '{print $2}')
            local down=$(echo "$stats_part" | grep -oE '↓ [0-9]+' | awk '{print $2}')

            local up_h=$(format_bytes "$up")
            local down_h=$(format_bytes "$down")

            echo -e "  ${CYAN}${inbound_name}${NC}"
            echo -e "    ${GREEN}↑ Upload: ${up_h}${NC}"
            echo -e "    ${GREEN}↓ Download: ${down_h}${NC}"
        done
    else
        echo -e "  ${YELLOW}Нет данных по inbound'ам${NC}"
    fi

    echo
    echo -e "${YELLOW}═══════════════════════════════════${NC}"
    echo -e "${YELLOW}  Трафик по outbound'ам${NC}"
    echo -e "${YELLOW}═══════════════════════════════════${NC}"

    local outbound_stats=$(echo "$all_stats" | jq -r '
        .stat[] |
        select(.name | test("^outbound>>>")) |
        .name as $name | .value as $value |
        ($name | split(">>>")) as $parts |
        {outbound: $parts[1], direction: $parts[3], bytes: $value}
    ' 2>/dev/null)

    if [[ -n "$outbound_stats" ]]; then
        echo "$outbound_stats" | jq -rs '
            group_by(.outbound) |
            .[] |
            {
                outbound: .[0].outbound,
                up: (map(select(.direction == "uplink")) | .[0].bytes // 0),
                down: (map(select(.direction == "downlink")) | .[0].bytes // 0)
            } |
            "\(.outbound): ↑ \(.up) | ↓ \(.down)"
        ' 2>/dev/null | while IFS= read -r line; do
            local outbound_name=$(echo "$line" | cut -d: -f1)
            local stats_part=$(echo "$line" | cut -d: -f2-)

            local up=$(echo "$stats_part" | grep -oE '↑ [0-9]+' | awk '{print $2}')
            local down=$(echo "$stats_part" | grep -oE '↓ [0-9]+' | awk '{print $2}')

            local up_h=$(format_bytes "$up")
            local down_h=$(format_bytes "$down")

            echo -e "  ${CYAN}${outbound_name}${NC}"
            echo -e "    ${GREEN}↑ Upload: ${up_h}${NC}"
            echo -e "    ${GREEN}↓ Download: ${down_h}${NC}"
        done
    else
        echo -e "  ${YELLOW}Нет данных по outbound'ам${NC}"
    fi

    echo
    echo -e "${YELLOW}═══════════════════════════════════${NC}"
    echo -e "${YELLOW}  Top-30 пользователей по трафику${NC}"
    echo -e "${YELLOW}═══════════════════════════════════${NC}"

    local user_stats=$(echo "$all_stats" | jq -r '
        .stat[] |
        select(.name | test("^user>>>")) |
        .name as $name | .value as $value |
        ($name | split(">>>")) as $parts |
        {user: $parts[1], direction: $parts[3], bytes: $value}
    ' 2>/dev/null)

    if [[ -n "$user_stats" ]]; then
        local top_users=$(echo "$user_stats" | jq -rs '
            group_by(.user) |
            .[] |
            {
                user: .[0].user,
                up: (map(select(.direction == "uplink")) | .[0].bytes // 0),
                down: (map(select(.direction == "downlink")) | .[0].bytes // 0),
                total: ((map(.bytes) | add) // 0)
            }
        ' 2>/dev/null | jq -s 'sort_by(.total) | reverse | .[0:30]')

        local rank=1
        echo "$top_users" | jq -c '.[]' 2>/dev/null | while IFS= read -r user_json; do
            local user=$(echo "$user_json" | jq -r '.user')
            local up=$(echo "$user_json" | jq -r '.up')
            local down=$(echo "$user_json" | jq -r '.down')
            local total=$(echo "$user_json" | jq -r '.total')

            local up_h=$(format_bytes "$up")
            local down_h=$(format_bytes "$down")
            local total_h=$(format_bytes "$total")

            echo -e "  ${BRIGHT_RED}${rank}. ${CYAN}${user}${NC}"
            echo -e "     ${GREEN}↑ ${up_h} | ↓ ${down_h} | Σ ${total_h}${NC}"
            ((rank++))
        done

        local total_users=$(echo "$user_stats" | jq -rs '[.[].user] | unique | length' 2>/dev/null)
        echo
        echo -e "  ${YELLOW}Всего пользователей с трафиком: ${GREEN}${total_users}${NC}"
    else
        echo -e "  ${YELLOW}Нет данных по пользователям${NC}"
        echo -e "  ${YELLOW}Возможно, пользователи ещё не использовали сервис${NC}"
    fi

    echo
    echo -e "${YELLOW}═══════════════════════════════════${NC}"
    echo -e "${YELLOW}  Итоговый трафик сервера${NC}"
    echo -e "${YELLOW}═══════════════════════════════════${NC}"

    # inbound downlink = трафик к пользователям (download),
    # inbound uplink = трафик от пользователей (upload)
    local total_download=$(echo "$all_stats" | jq -r '
        [.stat[] | select(.name | test("^inbound>>>")) | select(.name | test("downlink$")) | .value] | add // 0
    ' 2>/dev/null)

    local total_upload=$(echo "$all_stats" | jq -r '
        [.stat[] | select(.name | test("^inbound>>>")) | select(.name | test("uplink$")) | .value] | add // 0
    ' 2>/dev/null)

    local total_users_traffic=$(echo "$all_stats" | jq -r '
        [.stat[] | select(.name | test("^user>>>")) | .value] | add // 0
    ' 2>/dev/null)

    local total_download_h=$(format_bytes "$total_download")
    local total_upload_h=$(format_bytes "$total_upload")
    local total_users_h=$(format_bytes "$total_users_traffic")

    echo -e "  ${CYAN}Всего download:  ${GREEN}${total_download_h}${NC}"
    echo -e "  ${CYAN}Всего upload:    ${GREEN}${total_upload_h}${NC}"
    echo -e "  ${CYAN}Всего по users:  ${GREEN}${total_users_h}${NC}"
    echo
    echo -e "  ${YELLOW}Примечание: статистика выше сбрасывается при перезапуске Xray${NC}"
    echo -e "  ${YELLOW}Накопленная статистика (последние 30 дней) хранится в:${NC}"
    echo -e "  ${CYAN}${STATS_DIR}/stats-$(date +%Y-%m-%d).txt${NC}"

    echo
    read -p "Показать накопленную статистику за последние 30 дней? [y/N]: " acc_choice
    if [[ "$acc_choice" =~ ^[Yy]$ ]]; then
        local stats_file="${STATS_DIR}/stats-$(date +%Y-%m-%d).txt"
        if [[ ! -f "$stats_file" && -x /usr/local/bin/xray-stats-collect.sh ]]; then
            /usr/local/bin/xray-stats-collect.sh
        fi
        echo
        if [[ -f "$stats_file" ]]; then
            cat "$stats_file"
        else
            echo -e "${YELLOW}Накопленных данных пока нет${NC}"
        fi
    fi
}

# --- Генерация VLESS-ссылок ---
generate_vless_links() {
    echo -e "${CYAN}=== Генерация VLESS-ссылок ===${NC}"

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}Конфиг не найден${NC}"
        return 1
    fi

    read -p "Введите IP или домен сервера: " server_address
    if [[ -z "$server_address" ]]; then
        echo -e "${RED}Адрес сервера не указан${NC}"
        return 1
    fi

    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local links_file="${BACKUP_DIR}/vless-links-${timestamp}.txt"
    local total_links=0

    # Получение всех VLESS-inbounds с их клиентами
    local inbounds_json=$(jq -c '.inbounds[] | select(.protocol == "vless")' "$CONFIG_PATH" 2>/dev/null)

    if [[ -z "$inbounds_json" ]]; then
        echo -e "${YELLOW}VLESS-inbounds не найдены в конфиге${NC}"
        return 0
    fi

    echo
    echo -e "${YELLOW}Генерация ссылок...${NC}"
    echo

    while IFS= read -r inbound; do
        local tag=$(echo "$inbound" | jq -r '.tag // "unnamed"')
        local port=$(echo "$inbound" | jq -r '.port')
        local network=$(echo "$inbound" | jq -r '.streamSettings.network // "tcp"')
        local security=$(echo "$inbound" | jq -r '.streamSettings.security // "none"')

        local public_key=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.publicKey // empty')
        local short_id=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.shortIds[0] // empty')
        local server_name=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.serverNames[0] // empty')
        local sni=$(echo "$inbound" | jq -r '.streamSettings.tlsSettings.serverName // empty')
        local fp=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.fingerprint // "chrome"')

        if [[ "$security" == "reality" && -n "$public_key" ]]; then
            echo -e "${CYAN}═══ Inbound: ${tag} (Reality) ═══${NC}" | tee -a "$links_file"
        elif [[ "$security" == "tls" ]]; then
            echo -e "${CYAN}═══ Inbound: ${tag} (TLS) ═══${NC}" | tee -a "$links_file"
        else
            echo -e "${CYAN}═══ Inbound: ${tag} ═══${NC}" | tee -a "$links_file"
        fi

        local clients=$(echo "$inbound" | jq -c '.settings.clients[]?' 2>/dev/null)
        local link_count=0

        while IFS= read -r client; do
            local uuid=$(echo "$client" | jq -r '.id')
            local email=$(echo "$client" | jq -r '.email // "unnamed"')
            local flow=$(echo "$client" | jq -r '.flow // ""')

            local vless_link=""

            if [[ "$security" == "reality" ]]; then
                vless_link="vless://${uuid}@${server_address}:${port}?type=${network}&security=reality&pbk=${public_key}&fp=${fp}&sni=${server_name}&sid=${short_id}"
                if [[ -n "$flow" ]]; then
                    vless_link="${vless_link}&flow=${flow}"
                fi
            elif [[ "$security" == "tls" ]]; then
                vless_link="vless://${uuid}@${server_address}:${port}?type=${network}&security=tls&sni=${sni}&fp=${fp}"
                if [[ -n "$flow" ]]; then
                    vless_link="${vless_link}&flow=${flow}"
                fi
            else
                vless_link="vless://${uuid}@${server_address}:${port}?type=${network}&security=none"
            fi

            vless_link="${vless_link}#${email}"

            echo -e "${GREEN}${email}:${NC}"
            echo -e "${CYAN}${vless_link}${NC}"
            echo

            echo "${email}:" >> "$links_file"
            echo "${vless_link}" >> "$links_file"
            echo >> "$links_file"

            ((link_count++))
            ((total_links++))
        done <<< "$clients"

        echo -e "${YELLOW}Сгенерировано ссылок для ${tag}: ${link_count}${NC}"
        echo
    done <<< "$inbounds_json"

    echo -e "${GREEN}═══════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Итого сгенерировано ссылок: ${total_links}${NC}"
    echo -e "${YELLOW}Ссылки сохранены в: ${links_file}${NC}"
}

# --- Генерация Mihomo proxy ---
generate_mihomo_proxies() {
    echo -e "${CYAN}=== Генерация Mihomo proxy ===${NC}"

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}Конфиг не найден${NC}"
        return 1
    fi

    read -p "Введите IP или домен сервера: " server_address
    if [[ -z "$server_address" ]]; then
        echo -e "${RED}Адрес сервера не указан${NC}"
        return 1
    fi

    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local proxy_file="${BACKUP_DIR}/mihomo-proxies-${timestamp}.yaml"
    local total_proxies=0

    # Получение всех VLESS-inbounds
    local inbounds_json=$(jq -c '.inbounds[] | select(.protocol == "vless")' "$CONFIG_PATH" 2>/dev/null)

    if [[ -z "$inbounds_json" ]]; then
        echo -e "${YELLOW}VLESS-inbounds не найдены в конфиге${NC}"
        return 0
    fi

    echo
    echo -e "${YELLOW}Генерация Mihomo proxy...${NC}"
    echo

    echo "proxies:" > "$proxy_file"

    while IFS= read -r inbound; do
        local tag=$(echo "$inbound" | jq -r '.tag // "unnamed"')
        local port=$(echo "$inbound" | jq -r '.port')
        local network=$(echo "$inbound" | jq -r '.streamSettings.network // "tcp"')
        local security=$(echo "$inbound" | jq -r '.streamSettings.security // "none"')

        local public_key=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.publicKey // empty')
        local short_id=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.shortIds[0] // empty')
        local server_name=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.serverNames[0] // empty')
        local sni=$(echo "$inbound" | jq -r '.streamSettings.tlsSettings.serverName // empty')
        local fp=$(echo "$inbound" | jq -r '.streamSettings.realitySettings.fingerprint // "chrome"')

        local clients=$(echo "$inbound" | jq -c '.settings.clients[]?' 2>/dev/null)
        local proxy_count=0

        while IFS= read -r client; do
            local uuid=$(echo "$client" | jq -r '.id')
            local email=$(echo "$client" | jq -r '.email // "unnamed"')
            local flow=$(echo "$client" | jq -r '.flow // ""')

            # Уникальное имя прокси
            local proxy_name="${email} | ${server_address}:${port}"

            {
                echo "  - name: \"${proxy_name}\""
                echo "    type: vless"
                echo "    server: ${server_address}"
                echo "    port: ${port}"
                echo "    uuid: ${uuid}"
                echo "    network: ${network}"
            } >> "$proxy_file"

            if [[ "$security" == "reality" ]]; then
                {
                    echo "    tls: true"
                    echo "    servername: ${server_name}"
                    echo "    reality-opts:"
                    echo "      public-key: ${public_key}"
                    echo "      short-id: ${short_id}"
                } >> "$proxy_file"
            elif [[ "$security" == "tls" ]]; then
                {
                    echo "    tls: true"
                    echo "    servername: ${sni}"
                } >> "$proxy_file"
            fi

            {
                echo "    client-fingerprint: ${fp}"
                echo "    udp: true"
            } >> "$proxy_file"

            if [[ -n "$flow" ]]; then
                echo "    flow: ${flow}" >> "$proxy_file"
            fi

            echo >> "$proxy_file"

            ((proxy_count++))
            ((total_proxies++))
        done <<< "$clients"

        echo -e "${YELLOW}Сгенерировано proxy для ${tag}: ${proxy_count}${NC}"
    done <<< "$inbounds_json"

    echo
    echo -e "${GREEN}═══════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Итого сгенерировано proxy: ${total_proxies}${NC}"
    echo -e "${YELLOW}Файл сохранён в: ${proxy_file}${NC}"
    echo
    echo -e "${CYAN}Добавьте этот файл в ваш Mihomo конфиг через proxy-providers:${NC}"
    echo -e "${YELLOW}proxy-providers:${NC}"
    echo -e "${YELLOW}  my-proxies:${NC}"
    echo -e "${YELLOW}    type: file${NC}"
    echo -e "${YELLOW}    path: ./mihomo-proxies.yaml${NC}"
    echo -e "${YELLOW}    health-check:${NC}"
    echo -e "${YELLOW}      enable: true${NC}"
    echo -e "${YELLOW}      url: https://www.gstatic.com/generate_204${NC}"
    echo -e "${YELLOW}      interval: 300${NC}"
}

# =============================================================================
# Пункт 16. Меню ротации логов
# =============================================================================
log_rotation_menu() {
    while true; do
        echo -e "${CYAN}=== Ротация логов ===${NC}"

        local enabled="${LOG_ROTATE_ENABLED:-true}"
        if [[ "$enabled" == "true" ]]; then
            echo -e "  Ротация: ${GREEN}включена${NC}"
        else
            echo -e "  Ротация: ${RED}выключена${NC}"
        fi
        echo -e "  Время ротации: ${CYAN}${LOG_ROTATE_TIME:-06:00}${NC}"
        echo -e "  Хранить архивов: ${CYAN}${LOG_ROTATE_KEEP:-30}${NC}"

        local timer_enabled timer_active next_run
        timer_enabled=$(systemctl is-enabled xray-logrotate.timer 2>/dev/null)
        timer_active=$(systemctl is-active xray-logrotate.timer 2>/dev/null)
        echo -e "  Systemd timer: ${YELLOW}${timer_enabled:-не установлен}/${timer_active:-—}${NC}"

        next_run=$(systemctl list-timers xray-logrotate.timer --no-pager 2>/dev/null | awk '/xray-logrotate\.timer/{print $1" "$2}')
        echo -e "  Следующий запуск: ${CYAN}${next_run:-—}${NC}"

        local arch_count arch_size
        arch_count=$(ls -1 /var/log/xray/access-????-??-??.log 2>/dev/null | wc -l)
        arch_size=$(du -ch /var/log/xray/access-????-??-??.log 2>/dev/null | tail -1 | cut -f1)
        echo -e "  Архивов access-*.log: ${CYAN}${arch_count}${NC} (суммарно: ${CYAN}${arch_size:-0}${NC})"
        echo -e "  ${YELLOW}error.log не ротируется никогда${NC}"
        echo
        echo -e "${CYAN}1. ${NC}Включить/выключить ротацию"
        echo -e "${CYAN}2. ${NC}Изменить время ротации"
        echo -e "${CYAN}3. ${NC}Изменить глубину хранения"
        echo -e "${CYAN}4. ${NC}Ротировать сейчас"
        echo -e "${CYAN}0. ${NC}Назад"
        echo

        local choice
        read -p "Выбор [0-4]: " choice

        case "$choice" in
            1)
                if [[ "${LOG_ROTATE_ENABLED:-true}" == "true" ]]; then
                    LOG_ROTATE_ENABLED="false"
                    save_env_config
                    systemctl disable --now xray-logrotate.timer > /dev/null 2>&1
                    echo -e "${YELLOW}Ротация выключена${NC}"
                else
                    LOG_ROTATE_ENABLED="true"
                    save_env_config
                    write_logrotate_timer_file
                    systemctl enable --now xray-logrotate.timer > /dev/null 2>&1
                    echo -e "${GREEN}✓ Ротация включена${NC}"
                fi
                ;;
            2)
                read -p "Время ротации (HH:MM) [${LOG_ROTATE_TIME:-06:00}]: " new_time
                new_time=${new_time:-${LOG_ROTATE_TIME:-06:00}}
                if [[ ! "$new_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    echo -e "${RED}Неверный формат времени (нужно HH:MM)${NC}"
                else
                    LOG_ROTATE_TIME="$new_time"
                    save_env_config
                    write_logrotate_timer_file
                    systemctl restart xray-logrotate.timer > /dev/null 2>&1
                    echo -e "${GREEN}✓ Время ротации: ${new_time}${NC}"
                fi
                ;;
            3)
                read -p "Сколько архивов хранить [${LOG_ROTATE_KEEP:-30}]: " new_keep
                new_keep=${new_keep:-${LOG_ROTATE_KEEP:-30}}
                if [[ ! "$new_keep" =~ ^[0-9]+$ ]] || (( new_keep < 1 )); then
                    echo -e "${RED}Нужно положительное число${NC}"
                else
                    LOG_ROTATE_KEEP="$new_keep"
                    save_env_config
                    ls -1 /var/log/xray/access-????-??-??.log 2>/dev/null | sort | head -n "-${new_keep}" | xargs -r rm -f
                    echo -e "${GREEN}✓ Глубина хранения: ${new_keep}${NC}"
                fi
                ;;
            4)
                if [[ -x /usr/local/bin/xray-rotate-logs.sh ]]; then
                    /usr/local/bin/xray-rotate-logs.sh
                    echo -e "${GREEN}✓ Ротация выполнена${NC}"
                else
                    echo -e "${RED}Скрипт ротации не найден${NC}"
                fi
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}Неверный выбор${NC}"
                ;;
        esac

        echo
        read -p "Нажмите Enter для продолжения..."
        echo
    done
}

# --- Пункт 17. Просмотр access.log в реальном времени ---
view_access_log() {
    echo -e "${CYAN}=== Просмотр access.log (реальное время, последние 100 строк) ===${NC}"
    if [[ ! -f /var/log/xray/access.log ]]; then
        echo -e "${YELLOW}/var/log/xray/access.log не найден${NC}"
        return 0
    fi
    echo -e "${YELLOW}Ctrl+C для выхода из просмотра${NC}"
    tail -n 100 -f /var/log/xray/access.log
}

# --- Пункт 18. Поиск по access.log ---
search_access_log() {
    echo -e "${CYAN}=== Поиск по access.log ===${NC}"
    choose_access_log || return 0

    echo -e "${YELLOW}Что искать? Можно указать:${NC}"
    echo -e "${YELLOW}  - дату или время (YYYY-MM-DD или YYYY/MM/DD HH:MM)${NC}"
    echo -e "${YELLOW}  - домен (example.com)${NC}"
    echo -e "${YELLOW}  - email пользователя${NC}"
    echo -e "${YELLOW}  - любую часть строки${NC}"
    read -p "Поисковый запрос: " pattern
    if [[ -z "$pattern" ]]; then
        return 0
    fi

    local tmp
    tmp=$(mktemp)

    if [[ "$pattern" =~ ^[0-9]{4}[-/][0-9]{2}[-/][0-9]{2} ]]; then
        # Дата/время — якорим к началу строки, приводим к формату лога
        local p="${pattern:0:10}"
        p="${p//-//}"
        if [[ "$pattern" =~ ^[0-9]{4}[-/][0-9]{2}[-/][0-9]{2}[[:space:]]+([0-9]{2}:[0-9]{2}) ]]; then
            p="${p} ${BASH_REMATCH[1]}"
        fi
        grep -- "^${p}" "$CHOSEN_LOG" 2>/dev/null > "$tmp"
    else
        grep -F -- "$pattern" "$CHOSEN_LOG" 2>/dev/null > "$tmp"
    fi

    local count
    count=$(wc -l < "$tmp")
    if (( count == 0 )); then
        echo -e "${YELLOW}Совпадений не найдено${NC}"
    else
        echo -e "${YELLOW}Файл: $(basename "$CHOSEN_LOG") | совпадений: ${count}${NC}"
        echo -e "${YELLOW}═══════════════════════════${NC}"
        cat "$tmp"
    fi
    rm -f "$tmp"
}

# --- Пункт 19. Просмотр error.log ---
view_error_log() {
    echo -e "${CYAN}=== Просмотр error.log ===${NC}"
    if [[ ! -f /var/log/xray/error.log ]]; then
        echo -e "${YELLOW}/var/log/xray/error.log не найден${NC}"
        return 0
    fi

    local editor="${EDITOR:-}"
    if [[ -z "$editor" ]]; then
        editor="nano"
    fi
    if ! command -v "$editor" > /dev/null 2>&1; then
        echo -e "${YELLOW}Редактор '$editor' не найден. Устанавливаем nano...${NC}"
        apt-get install -y nano > /dev/null 2>&1
        editor="nano"
    fi

    echo -e "${CYAN}Открытие error.log в ${editor}...${NC}"
    "$editor" /var/log/xray/error.log
}

# --- Меню ---
show_menu() {
    clear
    show_banner
    echo -e "Текущая версия Xray: ${GREEN}$(get_xray_version)${NC}"
    echo -e "Репозиторий: ${CYAN}https://github.com/${XRAY_FORK_REPO}${NC}"
    echo
    echo -e "-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
    echo -e "${BRIGHT_RED}1. ${CYAN}Установка Xray${NC}"
    echo -e "${BRIGHT_RED}2. ${CYAN}Обновление Xray${NC}"
    echo -e "${BRIGHT_RED}3. ${CYAN}Настройка TCP Brutal${NC}"
    echo -e "${BRIGHT_RED}4. ${CYAN}Установка WARP от xxphantom${NC}"
    echo -e "-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
    echo -e "${BRIGHT_RED}5. ${CYAN}Открыть config.json${NC}"
    echo -e "${BRIGHT_RED}6. ${CYAN}Обновление массива routing${NC}"
    echo -e "${BRIGHT_RED}7. ${CYAN}Смена источника обновлений routing${NC}"
    echo -e "${BRIGHT_RED}8. ${CYAN}Сделать бэкап config.json${NC}"
    echo -e "${BRIGHT_RED}9. ${CYAN}Восстановить config.json из бэкапа${NC}"
    echo -e "-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
    echo -e "${BRIGHT_RED}10. ${CYAN}Пакетное добавление пользователей${NC}"
    echo -e "${BRIGHT_RED}11. ${CYAN}Пакетное удаление пользователей${NC}"
    echo -e "${BRIGHT_RED}12. ${CYAN}Просмотр статистики пользователя${NC}"
    echo -e "${BRIGHT_RED}13. ${CYAN}Просмотр статистики сервера${NC}"
    echo -e "${BRIGHT_RED}14. ${CYAN}Выдать ключ vless://${NC}"
    echo -e "${BRIGHT_RED}15. ${CYAN}Выдать Mihomo proxy${NC}"
    echo -e "-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
    echo -e "${BRIGHT_RED}16. ${CYAN}Ротация логов${NC}"
    echo -e "${BRIGHT_RED}17. ${CYAN}Просмотр access.log${NC}"
    echo -e "${BRIGHT_RED}18. ${CYAN}Поиск по access.log${NC}"
    echo -e "${BRIGHT_RED}19. ${CYAN}Просмотр error.log${NC}"
    echo -e "-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
    echo -e "${BRIGHT_RED}20. ${CYAN}Быстрый перезапуск Xray${NC}"
    echo -e "${BRIGHT_RED}0. ${CYAN}Выход${NC}"
    echo
}

# --- Основная функция ---
main() {
    check_root
    create_directories
    check_dependencies
    detect_architecture
    load_env_config

    # Самовосстановление сервисов обслуживания (ротация + статистика),
    # чтобы они появились и на серверах, где Xray установлен ранее
    if [[ -f "$XRAY_BIN" ]]; then
        setup_log_rotation
        setup_stats_collection
    fi

    while true; do
        show_menu

        read -p "Выберите пункт меню [0-20]: " choice

        case $choice in
            1) install_xray ;;
            2) update_xray ;;
            3) setup_tcp_brutal ;;
            4) install_warp ;;
            5) open_config ;;
            6) update_routing ;;
            7) change_routing_source ;;
            8) create_backup ;;
            9) restore_backup ;;
            10) batch_add_users ;;
            11) batch_remove_users ;;
            12) user_stats ;;
            13) server_stats ;;
            14) generate_vless_links ;;
            15) generate_mihomo_proxies ;;
            16) log_rotation_menu ;;
            17) view_access_log ;;
            18) search_access_log ;;
            19) view_error_log ;;
            20) restart_xray_status ;;
            0)
                echo -e "${YELLOW}Выход...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Неверный выбор, попробуйте снова${NC}"
                ;;
        esac

        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

main "$@"
