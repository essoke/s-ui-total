#!/usr/bin/env bash
# ==============================================================================
# S-UI Anti-DPI RU Reality Stack
# Module: SSL / TLS Certificate Manager (Let's Encrypt & Self-Signed Fallback)
# ==============================================================================

# Проверка резолва DNS A-записи домена на IP сервера
verify_domain_dns() {
    local domain="$1"
    local expected_ip="$SERVER_IP"

    log_info "Проверка DNS A-записи для $domain..."
    local resolved_ip
    resolved_ip=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)

    if [[ -z "$resolved_ip" ]]; then
        # Пробуем через публичный DNS Cloudflare / Google
        resolved_ip=$(dig @1.1.1.1 +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    fi

    if [[ "$resolved_ip" != "$expected_ip" ]]; then
        log_warn "Внимание: A-запись домена '$domain' ($resolved_ip) не совпадает с IP сервера ($expected_ip)!"
        echo -e "${YELLOW}Убедитесь, что вы создали A-запись в панели регистратора/Cloudflare (с отключенным проксированием 'DNS only / Gray cloud').${NC}"
        read -rp "Продолжить выпуск сертификата несмотря на расхождение DNS? (y/N): " force_dns
        if [[ ! "$force_dns" =~ ^[Yy]$ ]]; then
            return 1
        fi
    else
        log_ok "DNS A-запись для $domain успешно указывает на $expected_ip."
    fi
    return 0
}

# Генерация самоподписанного сертификата высокой криптостойкости (ECDSA prime256v1)
generate_self_signed_cert() {
    local cert_name="$1"
    local cert_dir="/etc/s-ui/ssl/$cert_name"
    mkdir -p "$cert_dir"

    log_info "Генерация самоподписанного ECDSA TLS-сертификата для $cert_name..."
    openssl ecparam -name prime256v1 -genkey -noout -out "$cert_dir/privkey.pem" >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "$cert_dir/privkey.pem" \
        -out "$cert_dir/fullchain.pem" \
        -subj "/CN=$cert_name/O=Cloud Infrastructure Services/C=US" >/dev/null 2>&1

    chmod 600 "$cert_dir/privkey.pem"
    chmod 644 "$cert_dir/fullchain.pem"
    log_ok "Самоподписанный TLS-сертификат создан: $cert_dir/fullchain.pem"
}

# Получение реального сертификата Let's Encrypt через Certbot
issue_letsencrypt_cert() {
    local domain="$1"
    local email="$2"
    local webroot_dir="/var/www/acme"

    mkdir -p "$webroot_dir"
    chown -R www-data:www-data "$webroot_dir" 2>/dev/null || true

    # Установка certbot если еще не установлен
    if ! command -v certbot >/dev/null 2>&1; then
        log_info "Установка Certbot..."
        apt-get install -y --no-install-recommends certbot python3-certbot-nginx >/dev/null 2>&1
    fi

    log_info "Запрос сертификата Let's Encrypt для $domain..."

    local email_arg="--register-unsafely-without-email"
    if [[ -n "$email" && "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        email_arg="--email $email"
    fi

    # Сначала пытаемся через webroot (если Nginx уже слушает порт 80)
    local cert_issued=0
    if certbot certonly --webroot -w "$webroot_dir" -d "$domain" \
        --non-interactive --agree-tos $email_arg --force-renewal >/dev/null 2>&1; then
        cert_issued=1
    else
        # Если Nginx еще не поднят или ошибка вебрута, временно останавливаем Nginx и пробуем standalone
        systemctl stop nginx >/dev/null 2>&1 || true
        if certbot certonly --standalone -d "$domain" \
            --non-interactive --agree-tos $email_arg --force-renewal >/dev/null 2>&1; then
            cert_issued=1
        fi
        systemctl start nginx >/dev/null 2>&1 || true
    fi

    if [[ "$cert_issued" -eq 1 ]]; then
        local cert_dir="/etc/s-ui/ssl/$domain"
        mkdir -p "$cert_dir"
        cp -f "/etc/letsencrypt/live/$domain/fullchain.pem" "$cert_dir/fullchain.pem"
        cp -f "/etc/letsencrypt/live/$domain/privkey.pem" "$cert_dir/privkey.pem"
        chmod 600 "$cert_dir/privkey.pem"
        chmod 644 "$cert_dir/fullchain.pem"
        log_ok "Сертификат Let's Encrypt для $domain успешно получен!"
        return 0
    else
        log_warn "Не удалось получить сертификат Let's Encrypt для $domain."
        log_warn "Используем самоподписанный сертификат в качестве резервного решения."
        generate_self_signed_cert "$domain"
        return 1
    fi
}

# Настройка автоматического продления сертификатов через cron
setup_ssl_autorenewal() {
    log_info "Настройка задания автопродления сертификатов (cron)..."
    local CRON_FILE="/etc/cron.d/sui-cert-renew"
    cat << 'EOF' > "$CRON_FILE"
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 1,15 * * root certbot renew --quiet --deploy-hook "systemctl reload nginx; systemctl restart s-ui"
EOF
    chmod 644 "$CRON_FILE"
    systemctl restart cron >/dev/null 2>&1 || true
    log_ok "Автопродление сертификатов Let's Encrypt активировано."
}
