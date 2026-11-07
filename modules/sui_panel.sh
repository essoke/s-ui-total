#!/usr/bin/env bash
# ==============================================================================
# S-UI Anti-DPI RU Reality Stack
# Module: S-UI Panel & Sing-box Core Installation & Provisioning
# ==============================================================================

# Проверка и установка официального релиза S-UI и ядра Sing-box
install_sui_core() {
    log_step "Установка панели S-UI и ядра Sing-box"

    local SUI_DIR="/usr/local/s-ui"
    mkdir -p "$SUI_DIR" "$SUI_DIR/bin" "$SUI_DIR/db" /etc/s-ui /etc/sing-box

    log_info "Определение последней стабильной версии S-UI (alireza0/s-ui)..."
    local sui_arch="amd64"
    if [[ "$SYSTEM_ARCH" == "arm64" ]]; then
        sui_arch="arm64"
    fi

    # Определение последней версии через GitHub API
    local sui_version
    sui_version=$(curl -s --connect-timeout 5 https://api.github.com/repos/alireza0/s-ui/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "")
    if [[ -z "$sui_version" || "$sui_version" == "null" ]]; then
        sui_version="v1.1.1"
    fi

    log_info "Загрузка S-UI ($sui_version-$sui_arch)..."
    local download_url="https://github.com/alireza0/s-ui/releases/download/${sui_version}/s-ui-linux-${sui_arch}.tar.gz"
    local tmp_tar="/tmp/s-ui.tar.gz"

    if ! curl -fsSL -o "$tmp_tar" "$download_url"; then
        log_warn "Не удалось загрузить релиз напрямую с GitHub. Попытка резервной загрузки..."
        download_url="https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh"
        bash <(curl -Ls "$download_url") || {
            log_err "Критическая ошибка: Не удалось установить S-UI."
            exit 1
        }
    else
        tar -xzf "$tmp_tar" -C "$SUI_DIR"
        rm -f "$tmp_tar"
        chmod +x "$SUI_DIR/s-ui"
    fi

    # Проверка наличия или установка Sing-box ядра
    local SINGBOX_BIN="$SUI_DIR/bin/sing-box"
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        log_info "Загрузка официального бинарного файла Sing-box..."
        local sb_version
        sb_version=$(curl -s --connect-timeout 5 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "")
        sb_version="${sb_version#v}"
        if [[ -z "$sb_version" || "$sb_version" == "null" ]]; then
            sb_version="1.11.4"
        fi

        local sb_url="https://github.com/SagerNet/sing-box/releases/download/v${sb_version}/sing-box-${sb_version}-linux-${sui_arch}.tar.gz"
        local sb_tar="/tmp/sing-box.tar.gz"
        if curl -fsSL -o "$sb_tar" "$sb_url"; then
            tar -xzf "$sb_tar" -C /tmp
            mv /tmp/sing-box-${sb_version}-linux-${sui_arch}/sing-box "$SINGBOX_BIN"
            chmod +x "$SINGBOX_BIN"
            rm -rf /tmp/sing-box*
        else
            # Резервный поиск системного sing-box
            if command -v sing-box >/dev/null 2>&1; then
                cp "$(command -v sing-box)" "$SINGBOX_BIN"
            fi
        fi
    fi

    if [[ ! -f "$SINGBOX_BIN" ]]; then
        log_err "Не удалось установить ядро Sing-box!"
        exit 1
    fi

    # Симлинк в системный PATH
    ln -sf "$SINGBOX_BIN" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box

    # Настройка службы systemd для S-UI
    cat << EOF > /etc/systemd/system/s-ui.service
[Unit]
Description=S-UI Sing-box Management Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/s-ui
ExecStart=/usr/local/s-ui/s-ui
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_ok "Панель S-UI и ядро Sing-box успешно установлены."
}

# Генерация криптографических ключей Reality, Hysteria 2 и токенов
generate_credentials() {
    log_step "Генерация криптографических ключей и уникальных токенов"

    local SINGBOX_BIN="/usr/local/s-ui/bin/sing-box"

    # Генерация Reality Keypair
    log_info "Генерация ключей X25519 для VLESS-Reality..."
    local keypair
    keypair=$("$SINGBOX_BIN" generate reality-keypair)
    REALITY_PRIV_KEY=$(echo "$keypair" | grep -Ei 'PrivateKey' | awk '{print $2}' | tr -d ' ')
    REALITY_PUB_KEY=$(echo "$keypair" | grep -Ei 'PublicKey' | awk '{print $2}' | tr -d ' ')

    # ShortID (8 байт в hex)
    REALITY_SHORT_ID=$(openssl rand -hex 8)

    # Клиентский UUID
    CLIENT_UUID=$("$SINGBOX_BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)

    # Пароли для Hysteria 2 и обфускации Salamander
    HY2_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    HY2_OBFS_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

    # Случайные секретные пути
    SUI_PATH="sui-$(openssl rand -hex 4)"
    XHTTP_PATH="xh-$(openssl rand -hex 4)"
    SUB_TOKEN=$(openssl rand -hex 12)

    # Локальный порт для S-UI (слушает только 127.0.0.1)
    SUI_LOCAL_PORT="2095"

    export REALITY_PRIV_KEY REALITY_PUB_KEY REALITY_SHORT_ID CLIENT_UUID
    export HY2_PASSWORD HY2_OBFS_PASSWORD SUI_PATH XHTTP_PATH SUB_TOKEN SUI_LOCAL_PORT

    log_ok "Криптографические ключи и токены успешно сгенерированы."
}

# Сборка и валидация конфигурации Sing-box на основе шаблона
deploy_singbox_config() {
    log_step "Формирование и применение серверного конфига Sing-box"

    local template_file="${SCRIPT_DIR}/templates/singbox_server.json"
    local config_target="/usr/local/s-ui/bin/config.json"
    local config_system="/etc/sing-box/config.json"

    # Подготовка блоков WARP
    local WARP_OUTBOUND_BLOCK=""
    local WARP_ROUTE_RULE=""
    if [[ -f "/etc/s-ui/warp/warp_credentials.json" ]]; then
        WARP_OUTBOUND_BLOCK="$(cat /etc/s-ui/warp/warp_credentials.json),"
        WARP_ROUTE_RULE='{
        "geosite": [
          "openai",
          "chatgpt",
          "anthropic",
          "claude"
        ],
        "outbound": "warp-out"
      },'
    fi

    # Определение путей к SSL-сертификатам
    local ssl_domain="${PRIMARY_DOMAIN:-$SERVER_IP}"
    local SSL_CERT_PATH="/etc/s-ui/ssl/${ssl_domain}/fullchain.pem"
    local SSL_KEY_PATH="/etc/s-ui/ssl/${ssl_domain}/privkey.pem"

    # Подстановка переменных в шаблон
    local config_content
    config_content=$(cat "$template_file")

    config_content="${config_content//\$\{CLIENT_UUID\}/$CLIENT_UUID}"
    config_content="${config_content//\$\{STEAL_DOMAIN\}/$STEAL_DOMAIN}"
    config_content="${config_content//\$\{CLASSIC_SNI\}/$CLASSIC_SNI}"
    config_content="${config_content//\$\{REALITY_PRIV_KEY\}/$REALITY_PRIV_KEY}"
    config_content="${config_content//\$\{REALITY_SHORT_ID\}/$REALITY_SHORT_ID}"
    config_content="${config_content//\$\{PRIMARY_DOMAIN\}/$PRIMARY_DOMAIN}"
    config_content="${config_content//\$\{XHTTP_PATH\}/$XHTTP_PATH}"
    config_content="${config_content//\$\{HY2_PASSWORD\}/$HY2_PASSWORD}"
    config_content="${config_content//\$\{HY2_OBFS_PASSWORD\}/$HY2_OBFS_PASSWORD}"
    config_content="${config_content//\$\{SSL_CERT_PATH\}/$SSL_CERT_PATH}"
    config_content="${config_content//\$\{SSL_KEY_PATH\}/$SSL_KEY_PATH}"
    config_content="${config_content//\$\{WARP_OUTBOUND_BLOCK\}/$WARP_OUTBOUND_BLOCK}"
    config_content="${config_content//\$\{WARP_ROUTE_RULE\}/$WARP_ROUTE_RULE}"

    echo "$config_content" > "$config_target"
    cp -f "$config_target" "$config_system"

    # Валидация конфигурации синтаксическим анализатором sing-box
    log_info "Валидация конфигурации Sing-box (sing-box check)..."
    if /usr/local/s-ui/bin/sing-box check -c "$config_target" >/dev/null 2>&1; then
        log_ok "Конфигурация Sing-box полностью корректна."
    else
        log_warn "Валидация sing-box check выявила предупреждения. Подробный вывод:"
        /usr/local/s-ui/bin/sing-box check -c "$config_target" || true
    fi
}

# Генерация готового клиентского профиля Sing-box (JSON) и ссылок VLESS/Hy2
generate_client_exports() {
    log_step "Генерация клиентских ссылок и профилей подключения"

    local client_template="${SCRIPT_DIR}/templates/client_template.json"
    local client_export="/var/www/decoy/${SUB_TOKEN}.json"

    local server_address="${PRIMARY_DOMAIN:-$SERVER_IP}"
    local hy2_insecure="false"
    if [[ -z "$PRIMARY_DOMAIN" ]]; then
        hy2_insecure="true"
    fi

    local client_json
    client_json=$(cat "$client_template")
    client_json="${client_json//\$\{SERVER_ADDRESS\}/$server_address}"
    client_json="${client_json//\$\{CLIENT_UUID\}/$CLIENT_UUID}"
    client_json="${client_json//\$\{STEAL_DOMAIN\}/$STEAL_DOMAIN}"
    client_json="${client_json//\$\{CLASSIC_SNI\}/$CLASSIC_SNI}"
    client_json="${client_json//\$\{REALITY_PUB_KEY\}/$REALITY_PUB_KEY}"
    client_json="${client_json//\$\{REALITY_SHORT_ID\}/$REALITY_SHORT_ID}"
    client_json="${client_json//\$\{PRIMARY_DOMAIN\}/$server_address}"
    client_json="${client_json//\$\{HY2_PASSWORD\}/$HY2_PASSWORD}"
    client_json="${client_json//\$\{HY2_OBFS_PASSWORD\}/$HY2_OBFS_PASSWORD}"
    client_json="${client_json//\$\{HY2_TLS_INSECURE\}/$hy2_insecure}"

    echo "$client_json" > "$client_export"
    chmod 644 "$client_export"

    # Формирование стандартных URI-ссылок
    # 1. VLESS Self-Steal
    VLESS_STEAL_LINK="vless://${CLIENT_UUID}@${server_address}:443?security=reality&encryption=none&pbk=${REALITY_PUB_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${STEAL_DOMAIN}&sid=${REALITY_SHORT_ID}#SUI-Reality-SelfSteal"

    # 2. VLESS Classic
    VLESS_CLASSIC_LINK="vless://${CLIENT_UUID}@${server_address}:443?security=reality&encryption=none&pbk=${REALITY_PUB_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${CLASSIC_SNI}&sid=${REALITY_SHORT_ID}#SUI-Reality-Classic"

    # 3. Hysteria 2
    local hy2_insecure_flag=""
    if [[ "$hy2_insecure" == "true" ]]; then
        hy2_insecure_flag="&insecure=1"
    fi
    HY2_LINK="hysteria2://${HY2_PASSWORD}@${server_address}:443/?sni=${server_address}&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}&mport=20000-50000${hy2_insecure_flag}#SUI-Hysteria2-Fast"

    # Ссылка на подписку (JSON)
    CLIENT_SUB_URL="https://${server_address}/${SUB_TOKEN}.json"

    export VLESS_STEAL_LINK VLESS_CLASSIC_LINK HY2_LINK CLIENT_SUB_URL
    log_ok "Клиентские конфигурации и ссылки успешно сформированы."
}

# Сохранение переменных окружения для CLI утилиты sui
save_sui_environment() {
    local env_file="/etc/s-ui/sui-total.conf"
    cat << EOF > "$env_file"
SERVER_IP="${SERVER_IP}"
PRIMARY_DOMAIN="${PRIMARY_DOMAIN}"
STEAL_DOMAIN="${STEAL_DOMAIN}"
CLASSIC_SNI="${CLASSIC_SNI}"
CLIENT_UUID="${CLIENT_UUID}"
REALITY_PUB_KEY="${REALITY_PUB_KEY}"
REALITY_PRIV_KEY="${REALITY_PRIV_KEY}"
REALITY_SHORT_ID="${REALITY_SHORT_ID}"
HY2_PASSWORD="${HY2_PASSWORD}"
HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD}"
SUI_PATH="${SUI_PATH}"
SUI_LOCAL_PORT="${SUI_LOCAL_PORT}"
XHTTP_PATH="${XHTTP_PATH}"
SUB_TOKEN="${SUB_TOKEN}"
CLIENT_SUB_URL="${CLIENT_SUB_URL}"
VLESS_STEAL_LINK="${VLESS_STEAL_LINK}"
VLESS_CLASSIC_LINK="${VLESS_CLASSIC_LINK}"
HY2_LINK="${HY2_LINK}"
EOF
    chmod 600 "$env_file"
}

# Запуск и включение службы S-UI
start_sui_services() {
    log_info "Запуск служб S-UI и Sing-box..."
    systemctl restart s-ui >/dev/null 2>&1 || true
    systemctl enable s-ui >/dev/null 2>&1 || true
    log_ok "Службы успешно запущены."
}
