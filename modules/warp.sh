#!/usr/bin/env bash
# ==============================================================================
# S-UI Anti-DPI RU Reality Stack
# Module: Cloudflare WARP Outbound (WireGuard Integration for AI / ChatGPT Unblock)
# ==============================================================================

# Установка и генерация учетной записи Cloudflare WARP
setup_cloudflare_warp() {
    log_step "Настройка Cloudflare WARP Outbound (Разблокировка ChatGPT / Claude / AI)"

    local WARP_DIR="/etc/s-ui/warp"
    mkdir -p "$WARP_DIR"
    cd "$WARP_DIR" || return 1

    # Проверка, есть ли уже сгенерированный профиль
    if [[ -f "$WARP_DIR/warp_credentials.json" ]]; then
        log_ok "Найдены существующие учетные данные Cloudflare WARP."
        return 0
    fi

    log_info "Загрузка генератора профилей Cloudflare WARP (wgcf)..."
    local wgcf_arch="linux_amd64"
    if [[ "$SYSTEM_ARCH" == "arm64" ]]; then
        wgcf_arch="linux_arm64"
    fi

    local WGCF_BIN="/usr/local/bin/wgcf"
    if ! command -v wgcf >/dev/null 2>&1; then
        local wgcf_url="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_${wgcf_arch}"
        if ! curl -fsSL -o "$WGCF_BIN" "$wgcf_url"; then
            log_warn "Не удалось загрузить wgcf с GitHub (возможен лимит API или сбой сети)."
            log_warn "WARP outbound будет пропущен, запросы к AI пойдут через прямой IP VPS."
            return 1
        fi
        chmod +x "$WGCF_BIN"
    fi

    log_info "Регистрация нового аккаунта Cloudflare WARP..."
    export WGCF_NON_INTERACTIVE=true
    if ! "$WGCF_BIN" register --accept-tos >/dev/null 2>&1; then
        log_warn "Регистрация в Cloudflare API завершилась с ошибкой."
        return 1
    fi

    log_info "Генерация WireGuard профиля..."
    if ! "$WGCF_BIN" generate >/dev/null 2>&1; then
        log_warn "Не удалось сгенерировать wgcf-profile.conf."
        return 1
    fi

    local WG_CONF="$WARP_DIR/wgcf-profile.conf"
    if [[ ! -f "$WG_CONF" ]]; then
        log_warn "Файл $WG_CONF не найден."
        return 1
    fi

    # Извлечение параметров WireGuard из сгенерированного файла
    local private_key
    private_key=$(grep -Ei '^[[:space:]]*PrivateKey[[:space:]]*=' "$WG_CONF" | awk -F '=' '{print $2}' | tr -d ' ')
    local ipv4_address
    ipv4_address=$(grep -Ei '^[[:space:]]*Address[[:space:]]*=' "$WG_CONF" | head -n1 | awk -F '=' '{print $2}' | tr -d ' ' | cut -d, -f1)
    local ipv6_address
    ipv6_address=$(grep -Ei '^[[:space:]]*Address[[:space:]]*=' "$WG_CONF" | head -n1 | awk -F '=' '{print $2}' | tr -d ' ' | cut -d, -f2)
    local public_key
    public_key=$(grep -Ei '^[[:space:]]*PublicKey[[:space:]]*=' "$WG_CONF" | awk -F '=' '{print $2}' | tr -d ' ')
    local endpoint
    endpoint=$(grep -Ei '^[[:space:]]*Endpoint[[:space:]]*=' "$WG_CONF" | awk -F '=' '{print $2}' | tr -d ' ')

    # Сохраняем в JSON для интеграции в Sing-box
    cat << EOF > "$WARP_DIR/warp_credentials.json"
{
  "type": "wireguard",
  "tag": "warp-out",
  "server": "162.159.192.1",
  "server_port": 2408,
  "local_address": [
    "${ipv4_address}",
    "${ipv6_address}"
  ],
  "private_key": "${private_key}",
  "peer_public_key": "${public_key:-bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=}",
  "mtu": 1280
}
EOF

    log_ok "Учетные данные Cloudflare WARP успешно сформированы и сохранены!"
    return 0
}
