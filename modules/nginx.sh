#!/usr/bin/env bash
# ==============================================================================
# S-UI Anti-DPI RU Reality Stack
# Module: Nginx L4 Stream SNI Router & Anti-Loop Fallback Engine
# ==============================================================================

# Установка и подготовка Nginx с поддержкой ngx_stream_module
install_nginx() {
    log_step "Установка и настройка Nginx (Stream L4 + HTTP/2 Upstream)"

    if ! dpkg -s nginx >/dev/null 2>&1; then
        log_info "Установка Nginx из официального репозитория..."
        apt-get install -y --no-install-recommends nginx >/dev/null 2>&1
    fi

    # Проверка наличия stream модуля
    mkdir -p /etc/nginx/modules-enabled /etc/nginx/stream.d /etc/nginx/conf.d /var/www/decoy /var/www/acme

    # Проверка динамической загрузки ngx_stream_module если требуется
    local stream_so=""
    for cand in /etc/nginx/modules/ngx_stream_module.so \
                /usr/lib/nginx/modules/ngx_stream_module.so \
                /usr/share/nginx/modules/ngx_stream_module.so; do
        if [[ -f "$cand" ]]; then
            stream_so="$cand"
            break
        fi
    done

    local load_module_directive=""
    if [[ -n "$stream_so" ]] && ! grep -qs "ngx_stream_module" /etc/nginx/modules-enabled/*.conf 2>/dev/null; then
        echo "load_module $stream_so;" > /etc/nginx/modules-enabled/50-mod-stream.conf
        load_module_directive="include /etc/nginx/modules-enabled/*.conf;"
    fi

    # Развертывание Decoy-сайта
    local DECOY_INDEX="/var/www/decoy/index.html"
    if [[ -f "${SCRIPT_DIR}/templates/decoy_site/index.html" ]]; then
        cp -f "${SCRIPT_DIR}/templates/decoy_site/index.html" "$DECOY_INDEX"
    else
        cat << 'EOF' > "$DECOY_INDEX"
<!DOCTYPE html><html><head><title>Edge Service Active</title></head>
<body style="font-family:sans-serif;background:#0d1117;color:#c9d1d9;text-align:center;padding:50px;">
<h1>System Operational</h1><p>Edge Gateway Status: 200 OK</p></body></html>
EOF
    fi
    chown -R www-data:www-data /var/www/decoy /var/www/acme
    chmod -R 755 /var/www/decoy /var/www/acme

    log_ok "Пакет Nginx и файлы маскировочного сайта успешно подготовлены."
}

# Генерация базового /etc/nginx/nginx.conf
configure_nginx_base() {
    log_info "Генерация главного конфигурационного файла /etc/nginx/nginx.conf..."

    cat << 'EOF' > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
worker_rlimit_nofile 1048576;

include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server_tokens off;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 300s;
    keepalive_requests 10000;
    reset_timedout_connection on;

    # Скрытие серверных заголовков
    more_clear_headers 'Server' 'X-Powered-By' 2>/dev/null;

    # Логирование (отключаем access-log для максимальной анонимности и снижения I/O)
    access_log off;
    error_log /var/log/nginx/error.log crit;

    # Поддержка Proxy Protocol
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    set_real_ip_from unix:;
    real_ip_header proxy_protocol;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    include /etc/nginx/conf.d/*.conf;
}

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF
}

# Генерация L4 Stream Router (/etc/nginx/stream.d/00-stream-router.conf)
configure_nginx_stream_router() {
    local primary_domain="$1"
    local steal_domain="$2"
    local classic_sni="$3"
    local steal_port="45443"
    local classic_port="46443"

    log_info "Генерация Nginx L4 Stream SNI Router..."

    # Формирование таблицы сопоставления SNI -> Inbound
    local stream_map="        \"\"                                nginx_http_backend;\n"
    
    if [[ -n "$primary_domain" ]]; then
        stream_map+="        ${primary_domain}                 nginx_http_backend;\n"
    fi

    if [[ -n "$steal_domain" ]]; then
        stream_map+="        ${steal_domain}                   reality_steal_backend;\n"
    fi

    if [[ -n "$classic_sni" ]]; then
        stream_map+="        ${classic_sni}                    reality_classic_backend;\n"
    fi

    # Дефолтный маршрут
    local default_backend="nginx_http_backend"
    if [[ -z "$primary_domain" && -n "$classic_sni" ]]; then
        default_backend="reality_classic_backend"
    fi

    cat << EOF > /etc/nginx/stream.d/00-stream-router.conf
# ==============================================================================
# S-UI Anti-DPI Stream Router: L4 SNI Multiplexer (Port 443 TCP)
# ==============================================================================

map \$ssl_preread_server_name \$backend_gate {
    hostnames;
$(echo -e "$stream_map")    default                           ${default_backend};
}

upstream nginx_http_backend {
    server unix:/dev/shm/nginx-http.sock;
}

upstream reality_steal_backend {
    server 127.0.0.1:${steal_port};
}

upstream reality_classic_backend {
    server 127.0.0.1:${classic_port};
}

server {
    listen 443 backlog=65535 reuseport;
    proxy_protocol on;
    proxy_pass \$backend_gate;
    ssl_preread on;
}
EOF
}

# Генерация L7 веб-сервера (/etc/nginx/conf.d/01-web-l7.conf)
configure_nginx_l7_vhost() {
    local primary_domain="$1"
    local steal_domain="$2"
    local sui_port="$3"
    local sui_path="$4"
    local xhttp_path="$5"
    local ssl_domain="${primary_domain:-$SERVER_IP}"
    local cert_file="/etc/s-ui/ssl/${ssl_domain}/fullchain.pem"
    local key_file="/etc/s-ui/ssl/${ssl_domain}/privkey.pem"

    log_info "Генерация Nginx L7 Vhost (Decoy, Anti-Loop Fallback 9443, S-UI Reverse Proxy)..."

    # Формирование директив server_name
    local server_names="$primary_domain"
    if [[ -n "$steal_domain" ]]; then
        server_names+=" $steal_domain"
    fi
    if [[ -z "$server_names" ]]; then
        server_names="_"
    fi

    cat << EOF > /etc/nginx/conf.d/01-web-l7.conf
# 1. HTTP Port 80 (ACME Challenge + Drop)
server {
    listen 80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# 2. Zero-SNI Shield: сброс соединений от прямых сканеров по IP или чужих SNI
server {
    listen unix:/dev/shm/nginx-http.sock ssl default_server proxy_protocol;
    server_name _;
    ssl_reject_handshake on;
}

# 3. Основной виртуальный хост: L7 Web + Anti-Loop Fallback (Порт 9443)
server {
    listen unix:/dev/shm/nginx-http.sock ssl proxy_protocol;
    listen 127.0.0.1:9443 ssl proxy_protocol;
    
    server_name ${server_names};

    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # Защитные HTTP заголовки для маскировки
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Корневой Decoy-сайт
    root /var/www/decoy;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Реверс-прокси к панели управления S-UI
    location /${sui_path}/ {
        proxy_pass http://127.0.0.1:${sui_port}/${sui_path}/;
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # VLESS xHTTP (Stream-One) Upstream endpoint
    location /${xhttp_path} {
        client_max_body_size 0;
        client_body_buffer_size 512k;
        client_body_timeout 300s;

        proxy_pass http://127.0.0.1:50443;
        proxy_http_version 1.1;

        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
EOF
}

# Проверка и перезапуск Nginx
apply_nginx_config() {
    log_info "Тестирование конфигурации Nginx (nginx -t)..."
    if nginx -t >/dev/null 2>&1; then
        systemctl restart nginx >/dev/null 2>&1
        systemctl enable nginx >/dev/null 2>&1
        log_ok "Конфигурация Nginx валидна, служба успешно запущена и включена в автозагрузку."
    else
        log_err "Ошибка в конфигурации Nginx! Вывод nginx -t:"
        nginx -t
        return 1
    fi
}
