#!/usr/bin/env bash
# ==============================================================================
# S-UI Anti-DPI RU Reality Stack
# Module: Preflight Checks (OS, Root, Dependencies, System Validation)
# ==============================================================================

# Цветовая палитра для вывода
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export PURPLE='\033[0;35m'
export CYAN='\033[0;36m'
export WHITE='\033[1;37m'
export BOLD='\033[1m'
export NC='\033[0m' # No Color

# Вспомогательные функции логирования
log_info() {
    echo -e "${BLUE}[ИНФО]${NC} $1"
}

log_ok() {
    echo -e "${GREEN}[ OK ]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"
}

log_err() {
    echo -e "${RED}[ОШИБКА]${NC} $1" >&2
}

log_step() {
    echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"
}

# 1. Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Этот скрипт должен быть запущен с правами суперпользователя (root)!"
        echo -e "${YELLOW}Попробуйте запустить:${NC} sudo bash $0"
        exit 1
    fi
    log_ok "Права root подтверждены."
}

# 2. Проверка операционной системы (Только Ubuntu и Debian)
check_os() {
    log_step "Проверка операционной системы"

    if [[ ! -f /etc/os-release ]]; then
        log_err "Не удалось определить операционную систему (/etc/os-release отсутствует)."
        exit 1
    fi

    # Чтение данных дистрибутива
    # shellcheck source=/dev/null
    . /etc/os-release

    OS_ID="${ID,,}"
    OS_VERSION="${VERSION_ID}"
    OS_CODENAME="${VERSION_CODENAME:-}"

    # Ограничение: Только Ubuntu и Debian
    case "$OS_ID" in
        ubuntu)
            # Поддерживаются версии 20.04, 22.04, 24.04 и новее
            local major_version
            major_version=$(echo "$OS_VERSION" | cut -d. -f1)
            if [[ "$major_version" -lt 20 ]]; then
                log_err "Ubuntu версии $OS_VERSION не поддерживается. Требуется Ubuntu 20.04 LTS или новее."
                exit 1
            fi
            log_ok "Обнаружена ОС: Ubuntu $OS_VERSION ($VERSION_CODENAME)"
            ;;
        debian)
            # Поддерживаются версии 11 (Bullseye), 12 (Bookworm), 13 (Trixie)
            local major_version
            major_version=$(echo "$OS_VERSION" | cut -d. -f1)
            if [[ "$major_version" -lt 11 ]]; then
                log_err "Debian версии $OS_VERSION не поддерживается. Требуется Debian 11 (Bullseye) или новее."
                exit 1
            fi
            log_ok "Обнаружена ОС: Debian $OS_VERSION ($VERSION_CODENAME)"
            ;;
        *)
            log_err "Операционная система '$ID' не поддерживается!"
            echo -e "${YELLOW}Данный установочный комплекс рассчитан исключительно на Ubuntu (20.04+) и Debian (11+).${NC}"
            exit 1
            ;;
    esac

    export OS_ID OS_VERSION OS_CODENAME
}

# 3. Проверка архитектуры процессора
check_architecture() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            export SYSTEM_ARCH="amd64"
            ;;
        aarch64|arm64)
            export SYSTEM_ARCH="arm64"
            ;;
        *)
            log_err "Неподдерживаемая архитектура процессора: $arch. Поддерживаются только x86_64 и arm64."
            exit 1
            ;;
    esac
    log_ok "Архитектура процессора: $SYSTEM_ARCH ($arch)"
}

# 4. Проверка виртуализации
check_virtualization() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local virt
        virt=$(systemd-detect-virt)
        if [[ "$virt" == "openvz" || "$virt" == "lxc" ]]; then
            log_warn "Обнаружена контейнерная виртуализация ($virt)."
            log_warn "Некоторые оптимизации ядра (BBR, тюнинг буферов) могут не поддерживаться хост-системой."
        else
            log_ok "Виртуализация: $virt (KVM/Baremetal/VMware — полная совместимость с BBR и nftables)"
        fi
    fi
}

# 5. Установка и верификация базовых системных зависимостей
install_dependencies() {
    log_step "Проверка и установка базовых системных пакетов"

    # Список критически необходимых утилит
    local REQUIRED_PACKAGES=(
        curl
        wget
        jq
        openssl
        git
        tar
        socat
        cron
        dnsutils
        qrencode
        iptables
        iptables-persistent
        net-tools
        ufw
        fail2ban
        ca-certificates
        lsb-release
        gnupg2
        bc
    )

    log_info "Обновление индексов пакетов (apt-get update)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1

    local PACKAGES_TO_INSTALL=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            PACKAGES_TO_INSTALL+=("$pkg")
        fi
    done

    if [[ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]]; then
        log_info "Установка недостающих пакетов: ${PACKAGES_TO_INSTALL[*]}..."
        apt-get install -y --no-install-recommends "${PACKAGES_TO_INSTALL[@]}" >/dev/null 2>&1
    fi

    # Верификация установки
    local FAILED_PACKAGES=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            FAILED_PACKAGES+=("$pkg")
        fi
    done

    if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
        log_err "Не удалось установить следующие обязательные пакеты: ${FAILED_PACKAGES[*]}"
        exit 1
    fi

    log_ok "Все обязательные зависимости успешно проверены и установлены."
}

# 6. Определение публичного IP сервера
detect_server_ip() {
    log_info "Определение публичного IP-адреса сервера..."
    SERVER_IP=$(curl -4 -s --connect-timeout 5 https://api.ipify.org || \
                curl -4 -s --connect-timeout 5 https://icanhazip.com || \
                curl -4 -s --connect-timeout 5 https://ifconfig.me || \
                hostname -I | awk '{print $1}')

    if [[ -z "$SERVER_IP" ]]; then
        log_err "Не удалось автоматически определить публичный IPv4 адрес сервера."
        read -rp "Пожалуйста, введите публичный IP-адрес сервера вручную: " SERVER_IP
    fi

    export SERVER_IP
    log_ok "Публичный IPv4 сервера: ${BOLD}${SERVER_IP}${NC}"
}
