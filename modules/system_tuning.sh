#!/usr/bin/env bash
# ==============================================================================
# S-UI Anti-DPI RU Reality Stack
# Module: System & Kernel Tuning (BBR, High-Performance TCP/UDP Buffers)
# ==============================================================================

# Применяет сетевые оптимизации ядра для максимальной пропускной способности,
# устойчивости VLESS Reality к потерям пакетов и разгона Hysteria 2 (UDP-буферы).
apply_system_tuning() {
    log_step "Сетевая оптимизация ядра Linux (BBR + расширенные TCP/UDP буферы)"

    # 1. Проверка поддержки BBR в ядре
    local available_congestion
    available_congestion=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")

    local bbr_module="bbr"
    if ! modprobe tcp_bbr >/dev/null 2>&1; then
        log_warn "Модуль ядра tcp_bbr не удалось загрузить через modprobe (возможно, встроен в ядро)."
    fi

    # 2. Формирование постоянного конфигурационного файла sysctl
    local SYSCTL_CONF="/etc/sysctl.d/99-sui-network.conf"
    log_info "Создание оптимизированной конфигурации $SYSCTL_CONF..."

    cat << 'EOF' > "$SYSCTL_CONF"
# --- Базовая маршрутизация и форвардинг пакетов ---
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.route_localnet = 1

# --- Контроль перегрузок TCP (BBR + FQ) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Высокопроизводительные буферы памяти для UDP (критично для Hysteria 2 и Discord/TG calls) ---
# Увеличение максимального размера приемного и передающего буфера до 32 МБ
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# --- Буферы памяти для TCP (VLESS-Reality / xHTTP) ---
# мин, дефолт, макс (до 32 МБ)
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# --- Очереди соединений и оптимизация сетевой карты ---
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# --- Защита от дропа соединений и тайм-ауты Keepalive ---
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# --- Быстрый старт и автоподбор MTU ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# --- Увеличение лимитов открытых файлов ядра ---
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
EOF

    # 3. Применение настроек ядра
    log_info "Применение параметров sysctl..."
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1

    # 4. Проверка статуса BBR
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
    local current_qdisc
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "неизвестно")

    if [[ "$current_cc" == "bbr" ]]; then
        log_ok "TCP BBR успешно активирован (Алгоритм: $current_cc, Дисциплина: $current_qdisc)."
    else
        log_warn "Текущий алгоритм контроля перегрузок: $current_cc (BBR может требовать перезагрузки VPS)."
    fi

    # 5. Настройка системных лимитов дескрипторов файлов (ulimit / limits.conf)
    local LIMITS_CONF="/etc/security/limits.d/99-sui-limits.conf"
    log_info "Настройка лимитов ulimit (nofile 1048576) в $LIMITS_CONF..."

    cat << 'EOF' > "$LIMITS_CONF"
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc 524288
* hard nproc 524288
root soft nproc 524288
root hard nproc 524288
EOF

    # Применение в текущей сессии
    ulimit -n 65535 >/dev/null 2>&1 || true
    log_ok "Лимиты файловых дескрипторов успешно увеличены."
}
