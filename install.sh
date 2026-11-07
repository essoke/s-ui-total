#!/usr/bin/env bash
# ==============================================================================
# S-UI Anti-DPI RU Reality Stack - Master Installer
# Target OS: Ubuntu 20.04+ / Debian 11+
# ==============================================================================

set -eo pipefail

# Определение рабочей директории скрипта
if [[ -n "${BASH_SOURCE[0]}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="/etc/s-ui-total"
    mkdir -p "$SCRIPT_DIR"
fi

export SCRIPT_DIR

# Проверка, запущен ли скрипт через пайп (curl | bash)
if [[ ! -f "$SCRIPT_DIR/modules/preflight.sh" ]]; then
    echo "Загрузка модулей установки из репозитория..."
    mkdir -p "$SCRIPT_DIR"
    local repo_url="${REPO_URL:-https://github.com/essoke/s-ui-total.git}"
    git clone --depth 1 "$repo_url" "$SCRIPT_DIR" 2>/dev/null || true
fi

# Подключение модулей
# shellcheck source=/dev/null
source "$SCRIPT_DIR/modules/preflight.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/modules/system_tuning.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/modules/firewall.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/modules/ssl.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/modules/nginx.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/modules/warp.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/modules/sui_panel.sh"

show_welcome_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
  ____        _   _ ___   _____ ___ _____  _    _     
 / ___|      | | | |_ _| |_   _/ _ \_   _|/ \  | |    
 \___ \ _____| | | || |    | || | | || | / _ \ | |    
  ___) |_____| |_| || |    | || |_| || |/ ___ \| |___ 
 |____/       \___/|___|   |_| \___/ |_/_/   \_\_____|
EOF
    echo -e "${NC}"
    echo -e "${WHITE}  S-UI Anti-DPI RU Reality Stack | Установочный комплекс${NC}"
    echo -e "${WHITE}  Архитектура: Nginx L4 Stream + Self-Steal Reality + Hysteria 2${NC}"
    echo -e "${CYAN}================================================================${NC}"
}

interactive_configuration() {
    log_step "Интерактивная конфигурация и выбор зависимостей"

    # 1. Запрос домена
    echo -e "${WHITE}Использование собственного домена позволяет активировать ${BOLD}Self-Steal Reality${NC}:"
    echo -e "Маскировка под ваш собственный субдомен с настоящим SSL и защитой от активного зондирования ТСПУ."
    read -rp "У вас есть собственный домен? (y/N): " has_domain

    if [[ "$has_domain" =~ ^[Yy]$ ]]; then
        read -rp "Введите ваш основной домен (например, mysite.com): " PRIMARY_DOMAIN
        PRIMARY_DOMAIN=$(echo "$PRIMARY_DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

        local default_steal="cdn.${PRIMARY_DOMAIN}"
        read -rp "Введите субдомен для Self-Steal [$default_steal]: " STEAL_DOMAIN
        STEAL_DOMAIN="${STEAL_DOMAIN:-$default_steal}"
        STEAL_DOMAIN=$(echo "$STEAL_DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

        read -rp "Введите Email для регистрации сертификата Let's Encrypt [опционально]: " SSL_EMAIL
    else
        PRIMARY_DOMAIN=""
        STEAL_DOMAIN=""
        SSL_EMAIL=""
        log_info "Установка в режиме IP (будет сгенерирован самоподписанный TLS-сертификат)."
    fi

    # 2. Выбор маскировочного SNI для Classic Reality
    echo -e "\n${WHITE}Маскировочный SNI для резервного Classic Reality (внешний проверенный хост):${NC}"
    echo -e "  1) dl.google.com (Google CDN - Рекомендуется)"
    echo -e "  2) gateway.icloud.com (Apple iCloud)"
    echo -e "  3) www.microsoft.com (Microsoft)"
    echo -e "  4) speedtest.net (Ookla Speedtest)"
    echo -e "  5) Ввести собственный"
    read -rp "Выберите вариант [1-5, по умолчанию 1]: " sni_choice

    case "$sni_choice" in
        2) CLASSIC_SNI="gateway.icloud.com" ;;
        3) CLASSIC_SNI="www.microsoft.com" ;;
        4) CLASSIC_SNI="speedtest.net" ;;
        5) read -rp "Введите желаемый SNI: " CLASSIC_SNI ;;
        *) CLASSIC_SNI="dl.google.com" ;;
    esac

    # 3. Выбор модулей и зависимостей
    echo -e "\n${BOLD}${CYAN}--- Выбор устанавливаемых модулей и оптимизаций ---${NC}"

    read -rp "Включить сетевую оптимизацию ядра (BBR + расширенные UDP-буферы)? [Y/n]: " opt_bbr
    ENABLE_BBR="y"
    [[ "$opt_bbr" =~ ^[Nn]$ ]] && ENABLE_BBR="n"

    read -rp "Настроить фаервол UFW, Fail2ban и Port Hopping NAT (20000:50000/udp)? [Y/n]: " opt_fw
    ENABLE_FW="y"
    [[ "$opt_fw" =~ ^[Nn]$ ]] && ENABLE_FW="n"

    read -rp "Подключить Cloudflare WARP Outbound (для разблокировки ChatGPT / Claude / AI)? [Y/n]: " opt_warp
    ENABLE_WARP="y"
    [[ "$opt_warp" =~ ^[Nn]$ ]] && ENABLE_WARP="n"

    export PRIMARY_DOMAIN STEAL_DOMAIN SSL_EMAIL CLASSIC_SNI ENABLE_BBR ENABLE_FW ENABLE_WARP
}

main() {
    show_welcome_banner

    # 1. Системные проверки
    check_root
    check_os
    check_architecture
    check_virtualization
    install_dependencies
    detect_server_ip

    # 2. Интерактивный опросник
    interactive_configuration

    # 3. Сетевой тюнинг
    if [[ "$ENABLE_BBR" == "y" ]]; then
        apply_system_tuning
    fi

    # 4. Фаервол и безопасность
    if [[ "$ENABLE_FW" == "y" ]]; then
        setup_firewall
    fi

    # 5. SSL сертификаты
    log_step "Подготовка SSL / TLS сертификатов"
    if [[ -n "$PRIMARY_DOMAIN" ]]; then
        verify_domain_dns "$PRIMARY_DOMAIN" || true
        issue_letsencrypt_cert "$PRIMARY_DOMAIN" "$SSL_EMAIL"
        setup_ssl_autorenewal
    else
        generate_self_signed_cert "$SERVER_IP"
    fi

    # 6. Установка S-UI, Sing-box и генерация криптографических ключей
    install_sui_core
    generate_credentials

    # 7. Cloudflare WARP
    if [[ "$ENABLE_WARP" == "y" ]]; then
        setup_cloudflare_warp || true
    fi

    # 8. Развертывание Nginx L4 Stream Router и Vhost
    install_nginx
    configure_nginx_base
    configure_nginx_stream_router "$PRIMARY_DOMAIN" "$STEAL_DOMAIN" "$CLASSIC_SNI"
    configure_nginx_l7_vhost "$PRIMARY_DOMAIN" "$STEAL_DOMAIN" "$SUI_LOCAL_PORT" "$SUI_PATH" "$XHTTP_PATH"
    apply_nginx_config

    # 9. Применение конфигурации Sing-box и запуск S-UI
    deploy_singbox_config
    generate_client_exports
    save_sui_environment
    start_sui_services

    # 10. Установка глобальной утилиты управления sui
    log_step "Регистрация консольной утилиты управления"
    cp -f "$SCRIPT_DIR/bin/sui" /usr/local/bin/sui
    chmod +x /usr/local/bin/sui
    log_ok "Утилита управления успешно установлена в ${BOLD}/usr/local/bin/sui${NC} (вызов командой 'sui')."

    # 11. Итоговый отчет
    local host="${PRIMARY_DOMAIN:-$SERVER_IP}"
    echo -e "\n${GREEN}${BOLD}================================================================${NC}"
    echo -e "${GREEN}${BOLD}      УСТАНОВКА И НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНЫ!                   ${NC}"
    echo -e "${GREEN}${BOLD}================================================================${NC}"
    echo -e "${WHITE}Панель управления S-UI:${NC}   ${BOLD}https://${host}/${SUI_PATH}/${NC}"
    echo -e "${WHITE}Публичный IP:${NC}             ${BOLD}${SERVER_IP}${NC}"
    echo -e "${WHITE}Файл клиентского профиля:${NC} ${BOLD}https://${host}/${SUB_TOKEN}.json${NC}"
    echo -e "${CYAN}----------------------------------------------------------------${NC}"

    echo -e "\n${BOLD}${CYAN}--- Ключевые протоколы подключения ---${NC}"
    if [[ -n "$STEAL_DOMAIN" ]]; then
        echo -e "\n${GREEN}${BOLD}[1] VLESS-Reality Self-Steal (Основной протокол против ТСПУ):${NC}"
        echo -e "${CYAN}${VLESS_STEAL_LINK}${NC}"
        qrencode -t ANSIUTF8 "${VLESS_STEAL_LINK}" || true
    fi

    echo -e "\n${GREEN}${BOLD}[2] VLESS-Reality Classic (Маскировка под ${CLASSIC_SNI}):${NC}"
    echo -e "${CYAN}${VLESS_CLASSIC_LINK}${NC}"
    qrencode -t ANSIUTF8 "${VLESS_CLASSIC_LINK}" || true

    echo -e "\n${GREEN}${BOLD}[3] Hysteria 2 (UDP 443 + Port Hopping 20000-50000):${NC}"
    echo -e "${CYAN}${HY2_LINK}${NC}"
    qrencode -t ANSIUTF8 "${HY2_LINK}" || true

    echo -e "\n${YELLOW}${BOLD}Для дальнейшего управления сервером просто введите в консоли:${NC} ${BOLD}sui${NC}"
    echo -e "${CYAN}================================================================${NC}\n"
}

main "$@"
