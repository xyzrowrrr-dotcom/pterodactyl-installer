
#!/usr/bin/env bash
# Pterodactyl Auto Installer - Ubuntu 22.04 / 24.04
# Panel 1.x Stable + Wings 1.x
# Review this script before running.

set -Eeuo pipefail

PANEL_DIR="/var/www/pterodactyl"
PHPV="8.3"
LOG="/var/log/pterodactyl-installer.log"

mkdir -p /var/log
exec > >(tee -a "$LOG") 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

trap 'r=$?; echo "[ERROR] Baris ${LINENO}, exit ${r}. Log: ${LOG}"; exit "$r"' ERR

root_check(){
    [[ "$EUID" -eq 0 ]] || die "Jalankan sebagai root."
}

os_check(){
    source /etc/os-release

    [[ "$ID" == "ubuntu" ]] || die "Hanya Ubuntu yang didukung."

    [[ "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ]] \
        || die "Gunakan Ubuntu 22.04 atau 24.04."

    command -v systemctl >/dev/null || die "systemd tidak ditemukan."
}

ask(){
    local var="$1"
    local prompt="$2"
    local default="${3:-}"
    local value

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value
        value="${value:-$default}"
    else
        read -r -p "$prompt: " value
    fi

    printf -v "$var" '%s' "$value"
}

secret(){
    local var="$1"
    local prompt="$2"
    local value

    read -r -s -p "$prompt: " value
    echo
    printf -v "$var" '%s' "$value"
}

valid_domain(){
    [[ "$1" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]
}

base_packages(){
    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        curl wget ca-certificates gnupg \
        software-properties-common \
        tar unzip git cron jq openssl \
        python3
}

install_php(){
    if [[ "$VERSION_ID" == "22.04" ]]; then
        add-apt-repository -y ppa:ondrej/php
    fi

    apt-get update

    apt-get install -y \
        nginx mariadb-server redis-server \
        "php${PHPV}" \
        "php${PHPV}-cli" \
        "php${PHPV}-common" \
        "php${PHPV}-gd" \
        "php${PHPV}-mysql" \
        "php${PHPV}-mbstring" \
        "php${PHPV}-bcmath" \
        "php${PHPV}-xml" \
        "php${PHPV}-fpm" \
        "php${PHPV}-curl" \
        "php${PHPV}-zip" \
        "php${PHPV}-intl" \
        "php${PHPV}-redis"

    systemctl enable --now nginx
    systemctl enable --now mariadb
    systemctl enable --now redis-server
    systemctl enable --now "php${PHPV}-fpm"

    if ! command -v composer >/dev/null 2>&1; then
        curl -fsSL https://getcomposer.org/installer \
            -o /tmp/composer-setup.php

        php /tmp/composer-setup.php \
            --install-dir=/usr/local/bin \
            --filename=composer

        rm -f /tmp/composer-setup.php
    fi
}

prepare_directory(){
    if [[ -e "$PANEL_DIR" ]]; then
        [[ -d "$PANEL_DIR" ]] || die "Path Panel bukan direktori."

        if find "$PANEL_DIR" -mindepth 1 -maxdepth 1 \
            -print -quit | grep -q .; then
            die "Direktori Panel sudah berisi file. Tidak akan ditimpa."
        fi

        rmdir "$PANEL_DIR"
        info "Direktori kosong lama berhasil dibersihkan."
    fi

    [[ ! -e /etc/nginx/sites-available/pterodactyl.conf ]] \
        || die "Konfigurasi Nginx Panel sudah ada."
}

prepare_database(){
    local exists tables user_exists

    systemctl enable --now mariadb

    exists="$(mariadb -Nse \
        "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='panel';")"

    if [[ -z "$exists" ]]; then
        mariadb -e "
            CREATE DATABASE panel
            CHARACTER SET utf8mb4
            COLLATE utf8mb4_unicode_ci;
        "
    else
        tables="$(mariadb -Nse \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='panel';")"

        [[ "$tables" == "0" ]] || die \
            "Database panel sudah berisi tabel. Installer berhenti demi keamanan."

        warn "Database panel kosong sudah ada. Akan digunakan kembali."
    fi

    user_exists="$(mariadb -Nse \
        "SELECT COUNT(*) FROM mysql.user WHERE User='pterodactyl' AND Host='127.0.0.1';")"

    if [[ "$user_exists" == "0" ]]; then
        mariadb -e "
            CREATE USER 'pterodactyl'@'127.0.0.1'
            IDENTIFIED BY '${DBPASS}';
        "
    else
        # Database telah dipastikan kosong.
        mariadb -e "
            ALTER USER 'pterodactyl'@'127.0.0.1'
            IDENTIFIED BY '${DBPASS}';
        "
    fi

    mariadb -e "
        GRANT ALL PRIVILEGES ON panel.*
        TO 'pterodactyl'@'127.0.0.1';
        FLUSH PRIVILEGES;
    "
}

configure_env(){
    export DOMAIN DBPASS TIMEZONE

    python3 <<'PY'
import os

path = "/var/www/pterodactyl/.env"

values = {
    "APP_ENV": "production",
    "APP_DEBUG": "false",
    "APP_URL": "https://" + os.environ["DOMAIN"],
    "APP_TIMEZONE": os.environ["TIMEZONE"],
    "DB_CONNECTION": "mysql",
    "DB_HOST": "127.0.0.1",
    "DB_PORT": "3306",
    "DB_DATABASE": "panel",
    "DB_USERNAME": "pterodactyl",
    "DB_PASSWORD": os.environ["DBPASS"],
    "CACHE_DRIVER": "redis",
    "SESSION_DRIVER": "redis",
    "QUEUE_CONNECTION": "redis",
    "MAIL_MAILER": "log",
}

with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines()

seen = set()
output = []

for line in lines:
    if "=" in line and not line.startswith("#"):
        key = line.split("=", 1)[0]
        if key in values:
            output.append(key + "=" + values[key])
            seen.add(key)
            continue
    output.append(line)

for key, value in values.items():
    if key not in seen:
        output.append(key + "=" + value)

with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(output) + "\n")
PY
}

configure_nginx(){
    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${PANEL_DIR}/public;
    index index.php;

    client_max_body_size 100m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
    }

    location ~ /\. {
        deny all;
    }
}
EOF

    ln -sfn \
        /etc/nginx/sites-available/pterodactyl.conf \
        /etc/nginx/sites-enabled/pterodactyl.conf

    if [[ -e /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
    fi

    nginx -t
    systemctl reload nginx
}

configure_queue(){
    (
        crontab -l 2>/dev/null |
            grep -v 'artisan schedule:run' || true

        echo '* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1'
    ) | crontab -

    cat > /etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    chown -R www-data:www-data "$PANEL_DIR"
    chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"

    systemctl daemon-reload
    systemctl enable --now pteroq
}

install_panel(){
    root_check
    os_check
    prepare_directory

    local DOMAIN EMAIL USERNAME FIRST LAST PASS TIMEZONE SSL

    ask DOMAIN "Domain Panel"
    valid_domain "$DOMAIN" || die "Domain tidak valid."

    ask EMAIL "Email admin"
    [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
        || die "Email tidak valid."

    ask USERNAME "Username admin" "admin"
    ask FIRST "Nama depan" "Admin"
    ask LAST "Nama belakang" "Panel"

    secret PASS "Password admin"

    [[ ${#PASS} -ge 8 ]] || die "Password minimal 8 karakter."

    ask TIMEZONE "Timezone" "Asia/Jakarta"

    [[ -e "/usr/share/zoneinfo/${TIMEZONE}" ]] \
        || die "Timezone tidak dikenal."

    DBPASS="$(openssl rand -hex 24)"

    base_packages
    install_php

    info "Menyiapkan database..."
    prepare_database

    info "Mengunduh Panel Pterodactyl 1.x..."

    mkdir -p "$PANEL_DIR"
    cd "$PANEL_DIR"

    curl -fL --retry 3 \
        https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz \
        -o panel.tar.gz

    tar -xzf panel.tar.gz
    rm -f panel.tar.gz

    [[ -f .env.example ]] || die "File .env.example tidak ditemukan."

    cp .env.example .env

    info "Menginstal Composer..."

    COMPOSER_ALLOW_SUPERUSER=1 composer install \
        --no-dev \
        --optimize-autoloader \
        --no-interaction

    configure_env

    php artisan key:generate --force
    php artisan config:clear
    php artisan migrate --seed --force

    php artisan p:user:make \
        --email="$EMAIL" \
        --username="$USERNAME" \
        --name-first="$FIRST" \
        --name-last="$LAST" \
        --password="$PASS" \
        --admin=1

    unset PASS DBPASS

    configure_nginx
    configure_queue

    echo
    warn "Pastikan DNS domain sudah mengarah ke IP VPS."
    ask SSL "Pasang SSL Let's Encrypt? (y/n)" "y"

    if [[ "$SSL" =~ ^[Yy]$ ]]; then
        apt-get install -y certbot python3-certbot-nginx

        certbot --nginx \
            -d "$DOMAIN" \
            --non-interactive \
            --agree-tos \
            -m "$EMAIL" \
            --redirect
    fi

    ok "Instalasi Panel selesai."
    echo "Panel: https://${DOMAIN}"
    echo "Log: ${LOG}"
    warn "Backup database dan APP_KEY dari file .env."
}

install_docker(){
    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com \
            -o /tmp/get-docker.sh

        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
    fi

    systemctl enable --now docker
}

install_wings(){
    root_check
    os_check

    local PANEL_URL NODE_ID TOKEN ARCH

    [[ ! -f /etc/pterodactyl/config.yml ]] \
        || die "config.yml sudah ada. Tidak akan ditimpa."

    ask PANEL_URL "URL Panel (https://panel.domain.com)"
    [[ "$PANEL_URL" =~ ^https?://[^/]+/?$ ]] \
        || die "URL Panel tidak valid."

    PANEL_URL="${PANEL_URL%/}"

    ask NODE_ID "Node ID"
    [[ "$NODE_ID" =~ ^[0-9]+$ ]] || die "Node ID tidak valid."

    secret TOKEN "Token Auto-Deploy dari tab Configuration"

    [[ -n "$TOKEN" ]] || die "Token kosong."

    base_packages
    install_docker

    mkdir -p /etc/pterodactyl

    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) die "Arsitektur CPU tidak didukung." ;;
    esac

    curl -fL --retry 3 \
        "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}" \
        -o /usr/local/bin/wings

    chmod 755 /usr/local/bin/wings

    cd /etc/pterodactyl

    info "Mengambil konfigurasi Wings dari Panel..."

    wings configure \
        --panel-url "$PANEL_URL" \
        --token "$TOKEN" \
        --node "$NODE_ID"

    unset TOKEN

    [[ -s /etc/pterodactyl/config.yml ]] \
        || die "config.yml tidak berhasil dibuat."

    cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wings

    ok "Wings berhasil dipasang."
    warn "Pastikan port daemon dan SFTP node dibuka pada firewall."
}

expand_ports(){
    local spec="$1"
    local part start end port
    local -a parts result

    IFS=',' read -r -a parts <<< "$spec"

    for part in "${parts[@]}"; do
        part="${part//[[:space:]]/}"

        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"

            [[ "$start" -ge 1 && "$end" -le 65535 && "$start" -le "$end" ]] \
                || die "Rentang port tidak valid."

            (( end - start + 1 <= 1000 )) \
                || die "Maksimal 1000 port dalam satu proses."

            for ((port=start; port<=end; port++)); do
                result+=("$port")
            done

        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            [[ "$part" -ge 1 && "$part" -le 65535 ]] \
                || die "Port tidak valid."

            result+=("$part")
        else
            die "Format port tidak valid: $part"
        fi
    done

    ((${#result[@]} > 0)) || die "Daftar port kosong."

    printf '%s\n' "${result[@]}" |
        sort -nu |
        jq -R . |
        jq -s .
}

create_node(){
    root_check
    os_check

    command -v jq >/dev/null || {
        apt-get update
        apt-get install -y jq
    }

    local URL API NAME LOC FQDN SCHEME MEM MO DISK DO DPORT SFTP IP PORTS ALIAS
    local PORT_JSON BODY RESP CODE NODE_ID

    ask URL "URL Panel"
    URL="${URL%/}"

    [[ "$URL" =~ ^https?://[^/]+$ ]] || die "URL Panel tidak valid."

    secret API "Application API key (ptla_)"
    [[ -n "$API" ]] || die "API key kosong."

    ask NAME "Nama Node" "Node-1"
    ask LOC "Location ID"
    [[ "$LOC" =~ ^[0-9]+$ ]] || die "Location ID tidak valid."

    ask FQDN "FQDN atau IP Node"
    [[ -n "$FQDN" ]] || die "FQDN kosong."

    ask SCHEME "Skema (http/https)" "https"
    [[ "$SCHEME" == "http" || "$SCHEME" == "https" ]] \
        || die "Skema tidak valid."

    ask MEM "RAM total dalam MiB" "8192"
    ask MO "RAM overallocation (%)" "0"
    ask DISK "Disk total dalam MiB" "51200"
    ask DO "Disk overallocation (%)" "0"
    ask DPORT "Daemon port" "8080"
    ask SFTP "SFTP port" "2022"

    ask IP "Allocation IP node"
    [[ -n "$IP" && "$IP" != "127.0.0.1" ]] || die "IP tidak valid."

    ask PORTS "Rentang port (25565-25600)"
    ask ALIAS "Alias allocation" "$IP"

    for n in "$MEM" "$MO" "$DISK" "$DO" "$DPORT" "$SFTP"; do
        [[ "$n" =~ ^[0-9]+$ ]] || die "Nilai harus angka."
    done

    [[ "$MEM" -gt 0 && "$DISK" -gt 0 ]] || die "RAM/disk harus lebih dari nol."
    [[ "$DPORT" -ge 1 && "$DPORT" -le 65535 ]] || die "Daemon port salah."
    [[ "$SFTP" -ge 1 && "$SFTP" -le 65535 ]] || die "SFTP port salah."

    PORT_JSON="$(expand_ports "$PORTS")"

    BODY="$(jq -n \
        --arg name "$NAME" \
        --argjson loc "$LOC" \
        --arg fqdn "$FQDN" \
        --arg scheme "$SCHEME" \
        --argjson mem "$MEM" \
        --argjson mo "$MO" \
        --argjson disk "$DISK" \
        --argjson do "$DO" \
        --argjson dp "$DPORT" \
        --argjson sftp "$SFTP" \
        '{
            name:$name,
            location_id:$loc,
            fqdn:$fqdn,
            scheme:$scheme,
            behind_proxy:false,
            memory:$mem,
            memory_overallocate:$mo,
            disk:$disk,
            disk_overallocate:$do,
            daemon_listen:$dp,
            daemon_sftp:$sftp,
            upload_size:100,
            maintenance_mode:false
        }')"

    RESP="$(mktemp)"

    CODE="$(curl -sS -o "$RESP" -w '%{http_code}' \
        -X POST "$URL/api/application/nodes" \
        -H "Authorization: Bearer $API" \
        -H "Accept: application/vnd.pterodactyl.v1+json" \
        -H "Content-Type: application/json" \
        --data "$BODY")"

    if [[ "$CODE" != "201" ]]; then
        cat "$RESP"
        rm -f "$RESP"
        unset API
        die "Gagal membuat Node. HTTP $CODE"
    fi

    NODE_ID="$(jq -r '.attributes.id // empty' "$RESP")"
    rm -f "$RESP"

    [[ "$NODE_ID" =~ ^[0-9]+$ ]] || die "Node ID tidak terbaca."

    BODY="$(jq -n \
        --arg ip "$IP" \
        --arg alias "$ALIAS" \
        --argjson ports "$PORT_JSON" \
        '{ip:$ip,alias:$alias,ports:$ports}')"

    RESP="$(mktemp)"

    CODE="$(curl -sS -o "$RESP" -w '%{http_code}' \
        -X POST "$URL/api/application/nodes/$NODE_ID/allocations" \
        -H "Authorization: Bearer $API" \
        -H "Accept: application/vnd.pterodactyl.v1+json" \
        -H "Content-Type: application/json" \
        --data "$BODY")"

    unset API

    if [[ "$CODE" != "204" ]]; then
        cat "$RESP"
        rm -f "$RESP"
        die "Node #$NODE_ID dibuat, tetapi allocation gagal. HTTP $CODE"
    fi

    rm -f "$RESP"

    ok "Node #$NODE_ID berhasil dibuat."
    warn "Lanjutkan konfigurasi Wings pada VPS Node."
}

check_status(){
    echo
    echo "===== STATUS PTERODACTYL ====="

    for svc in nginx mariadb redis-server \
        "php${PHPV}-fpm" pteroq docker wings; do

        if systemctl list-unit-files \
            "${svc}.service" --no-legend 2>/dev/null |
            grep -q "${svc}.service"; then

            printf '%-20s' "$svc"
            systemctl is-active "$svc" || true
        fi
    done

    echo
    [[ -d "$PANEL_DIR" ]] && echo "Panel directory: ada"
    [[ -s /etc/pterodactyl/config.yml ]] && echo "Wings config: ada"
    echo "Log: $LOG"
}

install_both(){
    install_panel

    echo
    warn "Buat Node di Admin > Nodes terlebih dahulu."
    read -r -p "Tekan Enter jika token Auto-Deploy sudah siap..."

    install_wings
}

menu(){
    while true; do
        clear || true

        echo "========================================"
        echo "     PTERODACTYL AUTO INSTALLER"
        echo "========================================"
        echo "[1] Install Panel"
        echo "[2] Install Wings"
        echo "[3] Install Panel + Wings"
        echo "[4] Create Node"
        echo "[5] Check Status"
        echo "[6] Exit"
        echo "========================================"

        read -r -p "Pilih menu [1-6]: " choice

        case "$choice" in
            1) install_panel ;;
            2) install_wings ;;
            3) install_both ;;
            4) create_node ;;
            5) check_status ;;
            6) exit 0 ;;
            *) warn "Pilihan tidak valid." ;;
        esac

        echo
        read -r -p "Tekan Enter untuk kembali ke menu..."
    done
}

root_check
os_check
menu
