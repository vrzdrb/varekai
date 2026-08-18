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
}

# --- Сохранение переменных окружения ---
save_env_config() {
    cat > "$ENV_CONFIG_PATH" << EOF
# Xray Environment Configuration
ROUTING_URL="${ROUTING_URL:-}"
DOMAIN="${DOMAIN:-}"
EDITOR="${EDITOR:-}"
EDITOR_CONFIGURED="${EDITOR_CONFIGURED:-false}"
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

    setup_logrotate
    setup_logs

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

# --- Настройка logrotate ---
setup_logrotate() {
    cat > /etc/logrotate.d/xray << EOF
/var/log/xray/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0600 root root
}
EOF
    log_message "Logrotate настроен"
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
    local xhttp_uuid=$(generate_uuid)

    local short_ids=$(generate_short_ids)
    local short_id_1=$(echo "$short_ids" | awk '{print $1}')
    local short_id_2=$(echo "$short_ids" | awk '{print $2}')
    local short_id_3=$(echo "$short_ids" | awk '{print $3}')

    local xhttp_path=$(generate_path)

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
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "ruleTag": "bt",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      },
      {
        "ruleTag": "warp-domain",
        "domain": [
          "geosite:google-gemini",
          "geosite:google-deepmind",
          "domain:gstatic.com",
          "domain:notebooklm.google.com",
          "domain:notebooklm.google",
          "domain:waa-pa.clients6.google.com",
          "domain:ogads-pa.clients6.google.com",
          "domain:alkalicore-pa.clients6.google.com",
          "domain:alkalimakersuite-pa.clients6.google.com",
          "domain:webchannel-alkalimakersuite-pa.clients6.google.com",
          "domain:sentry.io",
          "domain:clients6.google.com"
        ],
        "outboundTag": "warp-out"
      },
      {
        "ruleTag": "apple",
        "domain": ["geosite:apple"],
        "outboundTag": "direct"
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
          "regexp:\\\\.ru$",
          "regexp:\\\\.su$",
          "regexp:\\\\.рф$",
          "regexp:\\\\.tatar$",
          "regexp:one.me",
          "regexp:wechat.com",
          "regexp:tencent.com",
          "api.beacondb.net",
          "api.ipapi.is",
          "www.iplocate.io",
          "ipv4-internet.yandex.net",
          "ipv6-internet.yandex.net",
          "2ip.ru",
          "ifconfig.me",
          "ipv4.ifconfig.me",
          "ipv6.ifconfig.me",
          "checkip.amazonaws.com",
          "api.ipify.org",
          "api-ipv4.ip.sb",
          "api-ipv6.ip.sb",
          "whatismyip.com",
          "ipinfo.io",
          "checkip.dyndns.org",
          "checkip.dyn.com",
          "ip.comss.net",
          "whatismyip.akamai.com",
          "ipify.org",
          "checkip.org",
          "2ip.ua",
          "51degrees.com",
          "abstractapi.com",
          "apiip.net",
          "apivoid.com",
          "ipleak.net",
          "check-host.net",
          "2ip.io",
          "checkip.ru",
          "country.is",
          "curlmyip.net",
          "dadata.ru",
          "db-ip.com",
          "extreme-ip-lookup.com",
          "find-my-ip.com",
          "find-my-ip.net",
          "findip.net",
          "flagfox.net",
          "fraudguard.io",
          "fraudlogix.com",
          "freegeoip.app",
          "freeipapi.com",
          "geodatatool.com",
          "geojs.io",
          "geolocation-db.com",
          "geoplugin.com",
          "geoplugin.net",
          "getipintel.net",
          "greip.io",
          "hackertarget.com",
          "httpbin.org",
          "icanhazip.com",
          "ident.me",
          "ifconfig.co",
          "ifconfig.es",
          "ifconfig.io",
          "ip-adress.com",
          "ip-api.com",
          "ip-api.io",
          "ip-api.ru",
          "ip-check.info",
          "ip-score.com",
          "ip.me",
          "ip.sb",
          "ip2c.org",
          "ip2location.com",
          "ip2location.io",
          "ip2ruscity.com",
          "ip4.me",
          "ip6.me",
          "ip6only.me",
          "ip8.com",
          "ipaddr.site",
          "ipaddress.com",
          "ipaddress.my",
          "ipaddress.sh",
          "ipapi.co",
          "ipapi.com",
          "ipapi.is",
          "ipbase.com",
          "ipcalf.com",
          "ipchicken.com",
          "ipdata.co",
          "ipecho.net",
          "ipfind.io",
          "ipfinder.io",
          "ipgeolocation.io",
          "bigdatacloud.net",
          "ipligence.com",
          "iplocate.io",
          "iplocation.com",
          "iplocation.io",
          "iplocation.net",
          "ipqualityscore.com",
          "ipquery.io",
          "ipregistry.co",
          "iproyal.com",
          "ipstack.com",
          "ipverify.com",
          "ipwho.is",
          "ipwhois.io",
          "ipxapi.com",
          "l2.io",
          "maxmind.com",
          "mon-ip.com",
          "monip.org",
          "my-ip.io",
          "myexternalip.com",
          "myip.com",
          "myip.expert",
          "myip.ms",
          "myip.ru",
          "myip.wtf",
          "myipaddress.com",
          "myiplookup.com",
          "mylocation.org",
          "nodedata.io",
          "osint.sh",
          "proxycheck.io",
          "realip.cc",
          "seeip.org",
          "showip.net",
          "showmyip.com",
          "showmyipaddress.com",
          "spur.us",
          "sxgeo.city",
          "sypexgeo.net",
          "tnx.nl",
          "tracemyip.org",
          "trustmyip.com",
          "wgetip.com",
          "whatismyip.net",
          "whatismyip.org",
          "whatismyipaddress.com",
          "whatismyipaddress.net",
          "whatismyisp.com",
          "whatismyv6.com",
          "whatsmyip.com",
          "whatsmyip.org",
          "where-am-i.co",
          "whoer.net",
          "whoerip.com",
          "whoisxmlapi.com",
          "wieistmeineip.de",
          "wtfismyip.com",
          "ipip.net",
          "my.ipinfo.app",
          "ip.hetzner.com",
          "ip.mail.ru",
          "ip.nic.ru",
          "ip.pe.kr",
          "ip.tyk.nu",
          "ipgeo.vercel.app",
          "geoip.noc.gov.ru",
          "iplark.com",
          "ipw.cn",
          "whois.pconline.com.cn",
          "myip.la",
          "ip.mail.ru",
          "api.sypexgeo.net"
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
      "tag": "VLESS-Vision-REALITY",
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
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "@uds2xhttp.sock",
            "xver": 1
          }
        ]
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
    },
    {
      "tag": "VLESS-XHTTP-REALITY",
      "listen": "@uds2xhttp.sock",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "vless@xhttp.reality",
            "id": "$xhttp_uuid",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "host": "",
          "path": "$xhttp_path",
          "mode": "auto"
        },
        "sockopt": {
          "acceptProxyProtocol": true
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

                # Сохранение в sysctl.conf для персистентности
                if ! grep -q "tcp_congestion_control=brutal" /etc/sysctl.conf; then
                    echo "net.ipv4.tcp_congestion_control=brutal" >> /etc/sysctl.conf
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

    read -p "Выбор [0-$((i-1))]: " inbound_choice

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
    local tmp_config=$(mktemp)
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
        mv "$tmp_config" "$CONFIG_PATH"

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

    echo -e "${YELLOW}Перезапуск Xray...${NC}"
    if systemctl restart xray; then
        echo -e "${GREEN}✓ Xray перезапущен. Ожидание 5 секунд...${NC}"
        sleep 5

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

    if ! curl -sL "$ROUTING_URL" -o "$tmp_file"; then
        echo -e "${RED}Ошибка скачивания routing${NC}"
        rm "$tmp_file"
        return 1
    fi

    if ! jq . "$tmp_file" > /dev/null 2>&1; then
        echo -e "${RED}Невалидный JSON${NC}"
        rm "$tmp_file"
        return 1
    fi

    local routing_obj=""
    if jq -e '.routing' "$tmp_file" > /dev/null 2>&1; then
        routing_obj=$(jq '.routing' "$tmp_file")
    else
        routing_obj=$(jq '.' "$tmp_file")
    fi

    local tmp_config=$(mktemp)
    if jq --argjson routing "$routing_obj" '.routing = $routing' "$CONFIG_PATH" > "$tmp_config" 2>&1; then
        mv "$tmp_config" "$CONFIG_PATH"
        systemctl restart xray
        echo -e "${GREEN}✓ Routing успешно обновлён!${NC}"
        log_message "Routing обновлён"
    else
        echo -e "${RED}Ошибка обновления конфига${NC}"
        rm "$tmp_config"
    fi

    rm "$tmp_file"
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
EOF
        chmod 644 "$ENV_CONFIG_PATH"
        echo -e "${GREEN}✓ Файл создан${NC}"
        echo
    fi

    # КЛЮЧЕВАЯ ПРОВЕРКА: был ли редактор выбран через наше меню?
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

        # Помечаем, что редактор выбран через меню
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

    echo -e "${YELLOW}В какие inbound'ы добавлять пользователей?${NC}"
    echo -e "${CYAN}1. Только VLESS-Vision-REALITY${NC}"
    echo -e "${CYAN}2. Только VLESS-XHTTP-REALITY${NC}"
    echo -e "${CYAN}3. Оба inbound'а${NC}"

    read -p "Выбор [1-3]: " inbound_choice

    if [[ ! "$inbound_choice" =~ ^[1-3]$ ]]; then
        echo -e "${RED}Неверный выбор${NC}"
        return 1
    fi

    read -p "Количество пользователей (макс. 128): " count

    if [[ ! "$count" =~ ^[0-9]+$ || "$count" -lt 1 || "$count" -gt 128 ]]; then
        echo -e "${RED}Неверное количество${NC}"
        return 1
    fi

    echo -e "${YELLOW}Введите $count email'ов через пробел:${NC}"
    read -p "Email'ы: " -a users

    if [[ ${#users[@]} -eq 0 ]]; then
        echo -e "${RED}Не введено ни одного email${NC}"
        return 1
    fi

    if [[ ${#users[@]} -ne $count ]]; then
        echo -e "${YELLOW}Внимание: указано $count, но введено ${#users[@]} email'ов${NC}"
        read -p "Продолжить с ${#users[@]} пользователями? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Операция отменена${NC}"
            return 1
        fi
    fi

    local added_count=0

    for email in "${users[@]}"; do
        local uuid=$(generate_uuid)
        local tmp_config=$(mktemp)

        case "$inbound_choice" in
            1)
                # Только Vision
                if jq --arg email "$email" --arg uuid "$uuid" \
                    '.inbounds |= map(if .tag == "VLESS-Vision-REALITY" then .settings.clients += [{"email": $email, "id": $uuid, "flow": "", "level": 0}] else . end)' \
                    "$CONFIG_PATH" > "$tmp_config" 2>/dev/null; then
                    mv "$tmp_config" "$CONFIG_PATH"
                    echo "$email:$uuid:$(date '+%Y-%m-%d %H:%M:%S')" >> "$USERS_LIST"
                    echo -e "${GREEN}✓ Добавлен: $email (UUID: $uuid)${NC}"
                    ((added_count++))
                else
                    rm -f "$tmp_config"
                    echo -e "${RED}✗ Ошибка добавления: $email${NC}"
                fi
                ;;
            2)
                # Только XHTTP
                if jq --arg email "$email" --arg uuid "$uuid" \
                    '.inbounds |= map(if .tag == "VLESS-XHTTP-REALITY" then .settings.clients += [{"email": $email, "id": $uuid, "level": 0}] else . end)' \
                    "$CONFIG_PATH" > "$tmp_config" 2>/dev/null; then
                    mv "$tmp_config" "$CONFIG_PATH"
                    echo "$email:$uuid:$(date '+%Y-%m-%d %H:%M:%S')" >> "$USERS_LIST"
                    echo -e "${GREEN}✓ Добавлен: $email (UUID: $uuid)${NC}"
                    ((added_count++))
                else
                    rm -f "$tmp_config"
                    echo -e "${RED}✗ Ошибка добавления: $email${NC}"
                fi
                ;;
            3)
                # Оба inbound'а
                if jq --arg email "$email" --arg uuid "$uuid" \
                    '.inbounds |= map(
                        if .tag == "VLESS-Vision-REALITY" then
                            .settings.clients += [{"email": $email, "id": $uuid, "flow": "", "level": 0}]
                        elif .tag == "VLESS-XHTTP-REALITY" then
                            .settings.clients += [{"email": $email, "id": $uuid, "level": 0}]
                        else .
                        end
                    )' \
                    "$CONFIG_PATH" > "$tmp_config" 2>/dev/null; then
                    mv "$tmp_config" "$CONFIG_PATH"
                    echo "$email:$uuid:$(date '+%Y-%m-%d %H:%M:%S')" >> "$USERS_LIST"
                    echo -e "${GREEN}✓ Добавлен: $email (UUID: $uuid)${NC}"
                    ((added_count++))
                else
                    rm -f "$tmp_config"
                    echo -e "${RED}✗ Ошибка добавления: $email${NC}"
                fi
                ;;
        esac
    done

    if [[ $added_count -gt 0 ]]; then
        systemctl restart xray
        echo -e "${GREEN}✓ Успешно добавлено $added_count из ${#users[@]} пользователей${NC}"
        log_message "Добавлено $added_count пользователей"
    else
        echo -e "${RED}✗ Не удалось добавить ни одного пользователя${NC}"
    fi
}

# --- Пакетное удаление пользователей ---
batch_remove_users() {
    echo -e "${CYAN}=== Пакетное удаление пользователей ===${NC}"

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}Конфиг не найден${NC}"
        return 1
    fi

    echo -e "${YELLOW}Введите email'ы или UUID'ы для удаления (через пробел):${NC}"
    read -p "Значения: " -a search_values

    if [[ ${#search_values[@]} -eq 0 ]]; then
        echo -e "${RED}Не введено ни одного значения${NC}"
        return 1
    fi

    local found_count=0
    local not_found=()

    local tmp_config=$(mktemp)
    cp "$CONFIG_PATH" "$tmp_config"

    for value in "${search_values[@]}"; do
        if [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            if jq --arg uuid "$value" \
                '(.inbounds[].settings.clients) |= map(select(.id != $uuid))' \
                "$tmp_config" > "${tmp_config}.tmp" 2>&1; then
                mv "${tmp_config}.tmp" "$tmp_config"
                ((found_count++))
                echo -e "${GREEN}✓ Удалён по UUID: $value${NC}"
            else
                not_found+=("$value")
            fi
        else
            if jq --arg email "$value" \
                '(.inbounds[].settings.clients) |= map(select(.email != $email))' \
                "$tmp_config" > "${tmp_config}.tmp" 2>&1; then
                mv "${tmp_config}.tmp" "$tmp_config"
                ((found_count++))
                echo -e "${GREEN}✓ Удалён по email: $value${NC}"
            else
                not_found+=("$value")
            fi
        fi
    done

    if [[ $found_count -gt 0 ]]; then
        mv "$tmp_config" "$CONFIG_PATH"
        systemctl restart xray
        echo -e "${GREEN}✓ Удалено $found_count пользователей${NC}"
        log_message "Удалено $found_count пользователей"
    else
        rm "$tmp_config"
    fi

    if [[ ${#not_found[@]} -gt 0 ]]; then
        echo -e "${RED}Не найдены:${NC}"
        for val in "${not_found[@]}"; do
            echo -e "${RED}  - $val${NC}"
        done
    fi
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

    # Получение статистики через API
    echo -e "${CYAN}Получение статистики трафика...${NC}"

    # Xray api возвращает объект с полем "stat", содержащим массив
    local stats_raw=$(xray api statsquery --server="$API_SERVER" 2>/dev/null)

    if [[ -z "$stats_raw" ]]; then
        echo -e "${YELLOW}Не удалось получить статистику (Xray может быть не запущен или API недоступен)${NC}"
    else
        # Фильтруем статистику по email пользователя
        # Формат имени: user>>>email>>>traffic>>>uplink / user>>>email>>>traffic>>>downlink
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
                # Конвертация байтов в человекочитаемый формат
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

            # Итоговая сумма
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

    # Поиск IP-адресов в логах
    echo -e "${CYAN}Поиск IP-адресов в access.log...${NC}"

    # Собираем все файлы логов (обычные и сжатые)
    local log_files=()
    [[ -f /var/log/xray/access.log ]] && log_files+=(/var/log/xray/access.log)
    [[ -f /var/log/xray/access.log.1 ]] && log_files+=(/var/log/xray/access.log.1)
    [[ -f /var/log/xray/access.log.2.gz ]] && log_files+=(/var/log/xray/access.log.2.gz)
    [[ -f /var/log/xray/access.log.3.gz ]] && log_files+=(/var/log/xray/access.log.3.gz)
    # Добавим все доступные .gz файлы
    for gz in /var/log/xray/access.log.*.gz; do
        [[ -f "$gz" ]] && log_files+=("$gz")
    done

    if [[ ${#log_files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Файлы логов не найдены${NC}"
        return 0
    fi

    # Определяем период по датам файлов
    local oldest_date=""
    local newest_date=""

    for log_file in "${log_files[@]}"; do
        if [[ -f "$log_file" ]]; then
            local file_date=$(stat -c %y "$log_file" 2>/dev/null | cut -d' ' -f1)
            if [[ -n "$file_date" ]]; then
                if [[ -z "$oldest_date" ]] || [[ "$file_date" < "$oldest_date" ]]; then
                    oldest_date="$file_date"
                fi
                if [[ -z "$newest_date" ]] || [[ "$file_date" > "$newest_date" ]]; then
                    newest_date="$file_date"
                fi
            fi
        fi
    done

    # Временный файл для объединённых логов
    local tmp_logs=$(mktemp)

    # Собираем содержимое всех логов в один файл
    for log_file in "${log_files[@]}"; do
        if [[ "$log_file" == *.gz ]]; then
            zcat "$log_file" 2>/dev/null >> "$tmp_logs"
        else
            cat "$log_file" 2>/dev/null >> "$tmp_logs"
        fi
    done

    # Поиск строк с email (или UUID) и извлечение IP
    # Формат access.log: "2024/01/01 14:10:15 1.2.3.4:54321 accepted tcp:example.com:443 [email]"
    # IP находится в 3-м поле (после даты и времени)
    local ips=$(grep -E "$email|$uuid" "$tmp_logs" 2>/dev/null | \
        awk '{print $3}' | \
        cut -d: -f1 | \
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$' | \
        sort -u)

    rm -f "$tmp_logs"

    if [[ -n "$ips" ]]; then
        local ip_count=$(echo "$ips" | wc -l)
        echo -e "${YELLOW}Найдено уникальных IP-адресов: ${GREEN}${ip_count}${NC}"
        echo -e "${YELLOW}Список IP:${NC}"
        echo "$ips" | while IFS= read -r ip; do
            if [[ -n "$ip" ]]; then
                echo -e "  ${GREEN}• ${ip}${NC}"
            fi
        done
    else
        echo -e "${YELLOW}IP-адреса не найдены в логах${NC}"
        echo -e "${YELLOW}Возможно, пользователь ещё не подключался или логи были ротированы${NC}"
    fi

    echo
    if [[ -n "$oldest_date" && -n "$newest_date" ]]; then
        if [[ "$oldest_date" == "$newest_date" ]]; then
            echo -e "${CYAN}Период логов: ${GREEN}${oldest_date}${NC}"
        else
            echo -e "${CYAN}Период логов: ${GREEN}${oldest_date}${CYAN} — ${GREEN}${newest_date}${NC}"
        fi
    fi
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

    # Получение всех статистик
    local all_stats=$(xray api statsquery --server="$API_SERVER" 2>/dev/null)

    if [[ -z "$all_stats" ]]; then
        echo -e "${RED}Не удалось получить статистику от Xray API${NC}"
        echo -e "${YELLOW}Проверьте, что API доступен на ${API_SERVER}${NC}"
        return 1
    fi

    # Проверка наличия поля stat
    local has_stat=$(echo "$all_stats" | jq 'has("stat")' 2>/dev/null)
    if [[ "$has_stat" != "true" ]]; then
        echo -e "${YELLOW}Статистика пуста или API не вернул данные${NC}"
        echo -e "${YELLOW}Возможно, Xray был перезапущен и счётчики сброшены${NC}"
        return 0
    fi

    # Вспомогательная функция для конвертации байтов
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
    echo -e "${YELLOW}  Top-10 пользователей по трафику${NC}"
    echo -e "${YELLOW}═══════════════════════════════════${NC}"

    # Извлечение статистики пользователей
    local user_stats=$(echo "$all_stats" | jq -r '
        .stat[] |
        select(.name | test("^user>>>")) |
        .name as $name | .value as $value |
        ($name | split(">>>")) as $parts |
        {user: $parts[1], direction: $parts[3], bytes: $value}
    ' 2>/dev/null)

    if [[ -n "$user_stats" ]]; then
        # Группировка по пользователям и подсчёт общего трафика
        local top_users=$(echo "$user_stats" | jq -rs '
            group_by(.user) |
            .[] |
            {
                user: .[0].user,
                up: (map(select(.direction == "uplink")) | .[0].bytes // 0),
                down: (map(select(.direction == "downlink")) | .[0].bytes // 0),
                total: ((map(.bytes) | add) // 0)
            }
        ' 2>/dev/null | jq -s 'sort_by(.total) | reverse | .[0:10]')

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

        # Подсчёт общего числа пользователей
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

    # Общий трафик всех inbound'ов
    local total_inbound=$(echo "$all_stats" | jq -r '
        [.stat[] | select(.name | test("^inbound>>>")) | .value] | add // 0
    ' 2>/dev/null)

    # Общий трафик всех outbound'ов
    local total_outbound=$(echo "$all_stats" | jq -r '
        [.stat[] | select(.name | test("^outbound>>>")) | .value] | add // 0
    ' 2>/dev/null)

    # Общий трафик всех пользователей
    local total_users_traffic=$(echo "$all_stats" | jq -r '
        [.stat[] | select(.name | test("^user>>>")) | .value] | add // 0
    ' 2>/dev/null)

    local total_inbound_h=$(format_bytes "$total_inbound")
    local total_outbound_h=$(format_bytes "$total_outbound")
    local total_users_h=$(format_bytes "$total_users_traffic")

    echo -e "  ${CYAN}Всего inbound:   ${GREEN}${total_inbound_h}${NC}"
    echo -e "  ${CYAN}Всего outbound:  ${GREEN}${total_outbound_h}${NC}"
    echo -e "  ${CYAN}Всего по users:  ${GREEN}${total_users_h}${NC}"
    echo
    echo -e "  ${YELLOW}Примечание: статистика сбрасывается при перезапуске Xray${NC}"
}

# --- Генерация VLESS ссылок ---
generate_vless_links() {
    echo -e "${CYAN}=== Генерация VLESS ссылок ===${NC}"

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}Конфиг не найден${NC}"
        return 1
    fi

    echo -e "${YELLOW}Получение IP сервера...${NC}"
    local server_ip=$(curl -s ifconfig.me)

    if [[ -z "$server_ip" ]]; then
        echo -e "${RED}Не удалось получить IP${NC}"
        return 1
    fi

    echo -e "${GREEN}IP сервера: $server_ip${NC}"

    local domain=$(jq -r '.inbounds[] | select(.tag == "VLESS-Vision-REALITY") | .streamSettings.realitySettings.serverNames[0]' "$CONFIG_PATH")
    local private_key=$(jq -r '.inbounds[] | select(.tag == "VLESS-Vision-REALITY") | .streamSettings.realitySettings.privateKey' "$CONFIG_PATH")
    local public_key=$(xray x25519 -i "$private_key" | sed -ne '2s/.*:\s*//p')
    local short_ids=$(jq -r '.inbounds[] | select(.tag == "VLESS-Vision-REALITY") | .streamSettings.realitySettings.shortIds[0]' "$CONFIG_PATH")
    local xhttp_path=$(jq -r '.inbounds[] | select(.tag == "VLESS-XHTTP-REALITY") | .streamSettings.xhttpSettings.path' "$CONFIG_PATH")

    echo -e "${YELLOW}Выберите fingerprint:${NC}"
    echo -e "${CYAN}1. chrome${NC}"
    echo -e "${CYAN}2. firefox${NC}"
    echo -e "${CYAN}3. safari${NC}"
    echo -e "${CYAN}4. edge${NC}"
    echo -e "${CYAN}5. random${NC}"

    read -p "Выбор [1-5]: " fp_choice

    local fp=""
    case "$fp_choice" in
        1) fp="chrome" ;;
        2) fp="firefox" ;;
        3) fp="safari" ;;
        4) fp="edge" ;;
        5) fp="random" ;;
        *)
            echo -e "${RED}Неверный выбор${NC}"
            return 1
            ;;
    esac

    echo -e "${YELLOW}Введите email'ы клиентов (через пробел):${NC}"
    read -p "Email'ы: " -a emails

    if [[ ${#emails[@]} -eq 0 ]]; then
        echo -e "${RED}Не введено ни одного email${NC}"
        return 1
    fi

    for email in "${emails[@]}"; do
        # Исправленный запрос с проверкой на существование .settings.clients
        local uuid=$(jq -r --arg email "$email" \
            '.inbounds[] | select(.settings.clients != null) | .settings.clients[] | select(.email == $email) | .id' \
            "$CONFIG_PATH" | head -n 1)

        if [[ -z "$uuid" ]]; then
            echo -e "${RED}Пользователь $email не найден${NC}"
            continue
        fi

        echo -e "${CYAN}Ссылки для $email:${NC}"

        local vision_link="vless://${uuid}@${server_ip}:443?type=tcp&security=reality&sni=${domain}&fp=${fp}&pbk=${public_key}&sid=${short_ids}&flow=#${email}"
        echo -e "${GREEN}VLESS-TCP-Reality:${NC}"
        echo "$vision_link"

        local xhttp_link="vless://${uuid}@${server_ip}:443?type=xhttp&security=reality&sni=${domain}&fp=${fp}&pbk=${public_key}&sid=${short_ids}&path=${xhttp_path}&mode=auto&flow=#${email}"
        echo -e "${GREEN}VLESS-XHTTP-Reality:${NC}"
        echo "$xhttp_link"

        echo
    done
}

# --- Главное меню ---
show_menu() {
    clear
    show_banner

    local xray_version=$(get_xray_version)
    echo -e "${BRIGHT_RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Xray Version: ${GREEN}${xray_version}${NC}"
    echo -e "${CYAN}Fork: ${GREEN}github.com/${XRAY_FORK_REPO}${NC}"
    echo -e "${BRIGHT_RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
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
    echo -e "-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-"
    echo -e "${BRIGHT_RED}15. ${CYAN}Быстрый перезапуск Xray${NC}"
    echo -e "${BRIGHT_RED}0. ${CYAN}Выход${NC}"
    echo
}

# --- Основная функция ---
# --- Основная функция ---
main() {
    check_root
    create_directories
    load_env_config
    check_dependencies
    detect_architecture

    while true; do
        show_menu
        read -p "Выберите пункт меню [0-15]: " choice

        case "$choice" in
            1) install_xray ;;           # Установка Xray
            2) update_xray ;;            # Обновление Xray
            3) setup_tcp_brutal ;;       # Настройка TCP Brutal
            4) install_warp ;;           # Установка WARP от xxphantom
            5) open_config ;;            # Открыть config.json
            6) update_routing ;;         # Обновление массива routing
            7) change_routing_source ;;  # Смена источника обновлений routing
            8) create_backup ;;          # Сделать бэкап config.json
            9) restore_backup ;;         # Восстановить config.json из бэкапа
            10) batch_add_users ;;       # Пакетное добавление пользователей
            11) batch_remove_users ;;    # Пакетное удаление пользователей
            12) user_stats ;;            # Просмотр статистики пользователя
            13) server_stats ;;          # Просмотр статистики сервера
            14) generate_vless_links ;;  # Выдать ключ vless://
            15) restart_xray_status ;;   # Быстрый перезапуск Xray
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}Неверный выбор${NC}"
                ;;
        esac

        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Запуск
main "$@"


