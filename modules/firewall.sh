#!/usr/bin/env bash
# ==============================================================================
# S-UI Anti-DPI RU Reality Stack
# Module: Firewall & Security (UFW, Port Hopping NAT, Fail2ban)
# ==============================================================================

# Определение активного порта SSH, чтобы гарантированно не заблокировать доступ
detect_ssh_port() {
    local ssh_port=""
    if [[ -f /etc/ssh/sshd_config ]]; then
        ssh_port=$(grep -Ei '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | head -n1 | awk '{print $2}')
    fi

    if [[ -z "$ssh_port" ]]; then
        # Проверяем также sshd_config.d если есть
        if compgen -G "/etc/ssh/sshd_config.d/*.conf" >/dev/null 2>&1; then
            ssh_port=$(grep -Eih '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config.d/*.conf | head -n1 | awk '{print $2}')
        fi
    fi

    if [[ -z "$ssh_port" ]]; then
        ssh_port="22"
    fi

    echo "$ssh_port"
}

# Настройка правил фаервола, Port Hopping и защиты Fail2ban
setup_firewall() {
    log_step "Настройка сетевой безопасности (UFW + iptables NAT + Fail2ban)"

    local ssh_port
    ssh_port=$(detect_ssh_port)
    log_info "Определен порт SSH: ${BOLD}$ssh_port${NC}"

    # 1. Отключение и сброс предыдущих правил UFW
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw default allow routed >/dev/null 2>&1

    # 2. Открытие необходимых портов
    log_info "Разрешение SSH (порт $ssh_port/tcp)..."
    ufw allow "$ssh_port"/tcp comment "SSH Server" >/dev/null 2>&1

    log_info "Разрешение веб-портов (80/tcp ACME, 443/tcp Nginx L4 Stream Router)..."
    ufw allow 80/tcp comment "HTTP ACME Challenge" >/dev/null 2>&1
    ufw allow 443/tcp comment "HTTPS / VLESS Reality / xHTTP" >/dev/null 2>&1

    log_info "Разрешение Hysteria 2 (443/udp + Port Hopping 20000:50000/udp)..."
    ufw allow 443/udp comment "Hysteria 2 QUIC Primary" >/dev/null 2>&1
    ufw allow 20000:50000/udp comment "Hysteria 2 Port Hopping Range" >/dev/null 2>&1

    # 3. Настройка Port Hopping NAT через iptables (редирект диапазона 20000:50000 на 443 UDP)
    log_info "Настройка перенаправления портов (iptables NAT: 20000-50000/udp -> 443/udp)..."
    
    # Удаление старых аналогичных правил во избежание дублирования
    iptables -t nat -D PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443 >/dev/null 2>&1 || true
    iptables -t nat -A PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443

    # Интеграция правила NAT в /etc/ufw/before.rules для автосохранения UFW
    local UFW_BEFORE="/etc/ufw/before.rules"
    if [[ -f "$UFW_BEFORE" ]]; then
        if ! grep -q "Hysteria 2 Port Hopping" "$UFW_BEFORE"; then
            sed -i '/^COMMIT/i \
# Hysteria 2 Port Hopping NAT\
*nat\
:PREROUTING ACCEPT [0:0]\
-A PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443\
COMMIT\
' "$UFW_BEFORE" 2>/dev/null || true
        fi
    fi

    # Сохранение правил iptables для автозагрузки
    mkdir -p /etc/iptables 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    # 4. Включение UFW
    log_info "Активация UFW..."
    ufw --force enable >/dev/null 2>&1
    log_ok "Фаервол UFW успешно активирован."

    # 5. Настройка Fail2ban для защиты SSH
    log_info "Конфигурация Fail2ban (защита от брутфорса SSH)..."
    local JAIL_CONF="/etc/fail2ban/jail.d/99-sui-ssh.local"
    cat << EOF > "$JAIL_CONF"
[sshd]
enabled = true
port = $ssh_port
mode = aggressive
filter = sshd
maxretry = 4
findtime = 600
bantime = 86400
ignoreip = 127.0.0.1/8 ::1
EOF

    systemctl restart fail2ban >/dev/null 2>&1 || true
    systemctl enable fail2ban >/dev/null 2>&1 || true
    log_ok "Служба Fail2ban сконфигурирована и перезапущена."
}
