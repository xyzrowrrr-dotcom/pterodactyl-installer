#!/usr/bin/env bash
# Pterodactyl Panel + Wings Auto Installer
# Ubuntu 22.04 / 24.04
# Review and test before production use.

set -Eeuo pipefail

PANEL_VERSION="1.15.2"
PANEL_DIR="/var/www/pterodactyl"
LOG_FILE="/var/log/pterodactyl-installer.log"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROTECT_PAYLOAD="${SCRIPT_DIR}/protect-payload.tar.gz"
PROTECT_BACKUP_ROOT="/var/backups/pterodactyl-protect"
PROTECT_STATE_FILE="/var/lib/pterodactyl-protect/active-backup"

mkdir -p /var/log
exec > >(tee -a "$LOG_FILE") 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
fail(){ echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

on_error(){
  local rc=$?
  echo -e "${RED}[ERROR]${NC} Gagal pada baris ${BASH_LINENO[0]:-$LINENO} (exit $rc). Log: $LOG_FILE" >&2
  exit "$rc"
}
trap on_error ERR

require_root(){
  [[ "$EUID" -eq 0 ]] || fail "Jalankan sebagai root."
}

check_os(){
  [[ -r /etc/os-release ]] || fail "Tidak dapat membaca OS."
  . /etc/os-release

  [[ "$ID" == "ubuntu" ]] || fail "Hanya Ubuntu yang didukung."
  [[ "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ]] ||
    fail "Hanya Ubuntu 22.04/24.04 yang didukung."

  command -v systemctl >/dev/null ||
    fail "systemd tidak tersedia."
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

ask_secret(){
  local var="$1"
  local prompt="$2"
  local value

  read -r -s -p "$prompt: " value
  echo
  printf -v "$var" '%s' "$value"
}

valid_domain(){
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

valid_email(){
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

need_fresh_panel(){
  if [[ -e "$PANEL_DIR" ]]; then
    [[ -d "$PANEL_DIR" ]] ||
      fail "$PANEL_DIR bukan direktori."

    if find "$PANEL_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      fail "$PANEL_DIR tidak kosong. Installer berhenti agar data lama tidak tertimpa."
    fi

    info "Folder Panel sudah ada dan kosong. Akan digunakan kembali."
  fi

  [[ ! -e /etc/nginx/sites-enabled/pterodactyl.conf ]] ||
    fail "Konfigurasi Nginx Pterodactyl sudah ada."
}

apt_base(){
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y \
    curl ca-certificates gnupg software-properties-common \
    apt-transport-https tar unzip git cron jq openssl \
    python3
}

install_php_panel_deps(){
  if [[ "$VERSION_ID" == "22.04" ]]; then
    add-apt-repository -y ppa:ondrej/php
  fi

  apt-get update

  apt-get install -y \
    nginx mariadb-server redis-server \
    php8.3 php8.3-cli php8.3-common php8.3-gd \
    php8.3-mysql php8.3-mbstring php8.3-bcmath \
    php8.3-xml php8.3-fpm php8.3-curl \
    php8.3-zip php8.3-intl php8.3-redis

  systemctl enable --now nginx mariadb redis-server php8.3-fpm

  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer \
      -o /tmp/composer-setup.php

    php /tmp/composer-setup.php \
      --install-dir=/usr/local/bin \
      --filename=composer

    rm -f /tmp/composer-setup.php
  fi
}

prepare_database(){
  local db_tables

  systemctl enable --now mariadb

  db_tables="$(mariadb -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='panel';")"

  [[ "$db_tables" =~ ^[0-9]+$ ]] ||
    fail "Tidak dapat memeriksa database panel."

  [[ "$db_tables" -eq 0 ]] ||
    fail "Database panel sudah memiliki tabel. Installer berhenti untuk melindungi data."

  info "Membuat atau menggunakan kembali database kosong..."

  mariadb -u root <<SQL
CREATE DATABASE IF NOT EXISTS panel
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1'
  IDENTIFIED BY '${DBPASS}';

ALTER USER 'pterodactyl'@'127.0.0.1'
  IDENTIFIED BY '${DBPASS}';

GRANT ALL PRIVILEGES ON panel.*
  TO 'pterodactyl'@'127.0.0.1';

FLUSH PRIVILEGES;
SQL

  ok "Database siap digunakan."
}

configure_env(){
  export PANEL_URL DBPASS DOMAIN TZ

  python3 - <<'PY'
import os

p = "/var/www/pterodactyl/.env"

values = {
    "APP_URL": os.environ["PANEL_URL"],
    "APP_TIMEZONE": os.environ["TZ"],
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

with open(p, "r") as f:
    lines = f.read().splitlines()

seen = set()
out = []

for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key = line.split("=", 1)[0]
        if key in values:
            out.append(key + "=" + values[key])
            seen.add(key)
            continue
    out.append(line)

for key, value in values.items():
    if key not in seen:
        out.append(key + "=" + value)

with open(p, "w") as f:
    f.write("\n".join(out) + "\n")
PY
}

configure_nginx(){
  cat > /etc/nginx/sites-available/pterodactyl.conf <<NGINX
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
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
    }

    location ~ /\. {
        deny all;
    }
}
NGINX

  ln -sfn /etc/nginx/sites-available/pterodactyl.conf \
    /etc/nginx/sites-enabled/pterodactyl.conf

  rm -f /etc/nginx/sites-enabled/default

  nginx -t
  systemctl reload nginx
}

configure_queue(){
  (crontab -l 2>/dev/null | grep -v '/var/www/pterodactyl/artisan schedule:run' || true
   echo '* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1') | crontab -

  cat > /etc/systemd/system/pteroq.service <<'UNIT'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

  chown -R www-data:www-data "$PANEL_DIR"
  find "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" -type d -exec chmod 755 {} +
  find "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" -type f -exec chmod 644 {} +

  systemctl daemon-reload
  systemctl enable --now pteroq
}

install_panel(){
  require_root
  check_os
  need_fresh_panel

  local DOMAIN EMAIL USERNAME FIRST LAST PASS TZ DBPASS SSL SCHEME

  ask DOMAIN "Domain Panel (contoh panel.domain.com)"
  valid_domain "$DOMAIN" || fail "Domain tidak valid."

  ask EMAIL "Email admin"
  valid_email "$EMAIL" || fail "Email tidak valid."

  ask USERNAME "Username admin" "admin"
  ask FIRST "Nama depan admin" "Admin"
  ask LAST "Nama belakang admin" "Panel"

  ask_secret PASS "Password admin"
  [[ ${#PASS} -ge 8 && "$PASS" =~ [A-Z] && "$PASS" =~ [a-z] && "$PASS" =~ [0-9] ]] ||
    fail "Password harus minimal 8 karakter, huruf besar, kecil, dan angka."

  ask TZ "Timezone PHP" "Asia/Jakarta"
  [[ "$TZ" =~ ^[A-Za-z0-9_./+-]+$ ]] || fail "Timezone tidak valid."

  ask SSL "Pasang HTTPS Lets Encrypt? (y/n)" "y"

  SCHEME="https"
  [[ "$SSL" =~ ^[Yy]$ ]] || SCHEME="http"

  DBPASS="$(openssl rand -hex 24)"
  export DBPASS

  info "Memasang dependensi..."
  apt_base
  install_php_panel_deps

  prepare_database

  info "Mengunduh Pterodactyl Panel ${PANEL_VERSION}..."

  mkdir -p "$PANEL_DIR"
  cd "$PANEL_DIR"

  curl -fL --retry 3 \
    "https://github.com/pterodactyl/panel/releases/download/v${PANEL_VERSION}/panel.tar.gz" \
    -o panel.tar.gz

  tar -xzf panel.tar.gz
  rm -f panel.tar.gz

  [[ -f .env.example ]] || fail "File .env.example tidak ditemukan."

  cp .env.example .env

  COMPOSER_ALLOW_SUPERUSER=1 composer install \
    --no-dev --optimize-autoloader --no-interaction

  PANEL_URL="${SCHEME}://${DOMAIN}"
  configure_env

  php artisan key:generate --force
  php artisan storage:link
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

  if [[ "$SSL" =~ ^[Yy]$ ]]; then
    info "Memasang HTTPS..."

    apt-get install -y certbot python3-certbot-nginx

    certbot --nginx -d "$DOMAIN" \
      --non-interactive --agree-tos \
      -m "$EMAIL" --redirect
  else
    warn "HTTPS dilewati. Panel menggunakan HTTP sementara."
  fi

  ok "Instalasi Panel selesai."
  echo "URL: ${PANEL_URL}"
  echo "Log: ${LOG_FILE}"

  warn "Pastikan DNS domain mengarah ke IP VPS dan port 80/443 terbuka."
}

install_docker_wings(){
  if ! command -v docker >/dev/null 2>&1; then
    info "Memasang Docker Engine..."

    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
  fi

  systemctl enable --now docker
}

install_wings(){
  require_root
  check_os

  local PANEL_URL NODE_ID TOKEN ARCH

  [[ ! -e /etc/pterodactyl/config.yml ]] ||
    fail "Konfigurasi Wings sudah ada. Tidak akan ditimpa."

  ask PANEL_URL "URL Panel (contoh https://panel.domain.com)"
  [[ "$PANEL_URL" =~ ^https?://[^/]+/?$ ]] ||
    fail "URL Panel tidak valid."

  ask NODE_ID "Node ID dari Panel"
  [[ "$NODE_ID" =~ ^[0-9]+$ ]] || fail "Node ID harus angka."

  ask_secret TOKEN "Token Auto-Deploy dari tab Configuration"
  [[ -n "$TOKEN" ]] || fail "Token kosong."

  apt_base
  install_docker_wings

  mkdir -p /etc/pterodactyl

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) fail "Arsitektur tidak didukung: $ARCH" ;;
  esac

  curl -fL --retry 3 \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}" \
    -o /usr/local/bin/wings

  chmod 755 /usr/local/bin/wings

  info "Mengambil konfigurasi Wings dari Panel..."

  cd /etc/pterodactyl

  if ! wings configure \
    --panel-url "$PANEL_URL" \
    --token "$TOKEN" \
    --node "$NODE_ID"; then
    unset TOKEN
    fail "Auto-Deploy ditolak Panel. Ambil ulang perintah melalui Admin > Nodes > Node kamu > Configuration > Generate Token, lalu masukkan HANYA nilai setelah --token. Jangan gunakan token/token_id dari YAML atau Application API Key buatan sendiri."
  fi

  unset TOKEN

  [[ -s /etc/pterodactyl/config.yml ]] ||
    fail "Auto-Deploy tidak menghasilkan config.yml."

  cat > /etc/systemd/system/wings.service <<'UNIT'
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
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now wings

  ok "Wings selesai dipasang."
  warn "Pastikan port daemon dan SFTP node dibuka sesuai konfigurasi."
}

expand_ports(){
  local input="$1"
  local item start end port count=0
  local -a result=()

  IFS=',' read -ra items <<< "$input"

  for item in "${items[@]}"; do
    if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"

      [[ "$start" -le "$end" ]] || fail "Rentang port tidak valid."
      [[ "$((end-start))" -le 999 ]] || fail "Maksimal 1000 port."

      for ((port=start; port<=end; port++)); do
        [[ "$port" -ge 1 && "$port" -le 65535 ]] ||
          fail "Port di luar batas."
        result+=("$port")
        ((count+=1))
      done

    elif [[ "$item" =~ ^[0-9]+$ ]]; then
      port="$item"
      [[ "$port" -ge 1 && "$port" -le 65535 ]] ||
        fail "Port di luar batas."
      result+=("$port")
      ((count+=1))
    else
      fail "Format port salah: $item"
    fi
  done

  [[ "$count" -gt 0 ]] || fail "Daftar port kosong."

  printf '%s\n' "${result[@]}" | sort -nu | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)'
}

create_node(){
  require_root
  check_os

  local URL API NAME LOC LOC_SHORT LOC_LONG FQDN SCHEME MEM MO DISK DO DPORT SFTP IP PORTS ALIAS
  local BODY RESP CODE NODE_ID PORTS_JSON

  command -v jq >/dev/null 2>&1 || apt-get install -y jq

  ask URL "URL Panel"
  URL="${URL%/}"
  [[ "$URL" =~ ^https?://[^/]+$ ]] || fail "URL Panel tidak valid."

  ask_secret API "Application API key"
  [[ -n "$API" ]] || fail "API key kosong."

  ask NAME "Nama Node" "Autoinstall By Kaiiz"
  ask LOC_SHORT "Kode Location" "SGP"
  ask LOC_LONG "Nama Location" "Singapore"
  [[ "$LOC_SHORT" =~ ^[a-zA-Z0-9_-]{3,60}$ ]] || fail "Kode Location harus 3-60 karakter."

  RESP="$(mktemp)"
  CODE="$(curl -sS -o "$RESP" -w '%{http_code}' "$URL/api/application/locations?per_page=100" \
    -H "Authorization: Bearer $API" -H 'Accept: application/vnd.pterodactyl.v1+json')"
  [[ "$CODE" == "200" ]] || { cat "$RESP"; rm -f "$RESP"; fail "Gagal membaca Location (HTTP $CODE)."; }
  LOC="$(jq -r --arg short "$LOC_SHORT" '.data[]? | select(.attributes.short == $short) | .attributes.id' "$RESP" | head -n1)"
  rm -f "$RESP"
  if [[ -z "$LOC" ]]; then
    BODY="$(jq -n --arg short "$LOC_SHORT" --arg long "$LOC_LONG" '{short:$short,long:$long}')"
    RESP="$(mktemp)"
    CODE="$(curl -sS -o "$RESP" -w '%{http_code}' -X POST "$URL/api/application/locations" \
      -H "Authorization: Bearer $API" -H 'Accept: application/vnd.pterodactyl.v1+json' \
      -H 'Content-Type: application/json' --data "$BODY")"
    if [[ "$CODE" != "201" ]]; then cat "$RESP"; rm -f "$RESP"; fail "Gagal membuat Location (HTTP $CODE)."; fi
    LOC="$(jq -r '.attributes.id // empty' "$RESP")"
    rm -f "$RESP"
  fi
  [[ "$LOC" =~ ^[0-9]+$ ]] || fail "ID Location tidak terbaca."

  ask FQDN "FQDN atau IP Node"
  [[ -n "$FQDN" && "$FQDN" != *" "* ]] || fail "FQDN tidak valid."

  ask SCHEME "Skema koneksi Wings (http/https)" "https"
  [[ "$SCHEME" == "http" || "$SCHEME" == "https" ]] ||
    fail "Skema tidak valid."

  ask MEM "Total RAM node dalam MiB" "8192"
  ask MO "RAM overallocation (%)" "0"
  ask DISK "Total disk node dalam MiB" "51200"
  ask DO "Disk overallocation (%)" "0"
  ask DPORT "Daemon port" "8080"
  ask SFTP "SFTP port" "2022"

  ask IP "Allocation IP publik node"
  ask PORTS "Rentang port allocation" "25565-25600"
  ask ALIAS "Alias allocation" "$IP"

  for n in "$MEM" "$MO" "$DISK" "$DO" "$DPORT" "$SFTP"; do
    [[ "$n" =~ ^[0-9]+$ ]] || fail "Nilai harus berupa angka."
  done

  [[ "$MEM" -gt 0 && "$DISK" -gt 0 ]] || fail "RAM/disk harus lebih dari nol."
  [[ "$DPORT" -ge 1 && "$DPORT" -le 65535 ]] || fail "Daemon port tidak valid."
  [[ "$SFTP" -ge 1 && "$SFTP" -le 65535 ]] || fail "SFTP port tidak valid."
  [[ "$IP" != "127.0.0.1" && "$FQDN" != "127.0.0.1" ]] ||
    fail "Jangan gunakan localhost untuk Node publik."

  PORTS_JSON="$(expand_ports "$PORTS")"

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
      daemon_base:"/var/lib/pterodactyl/volumes",
      upload_size:100,
      maintenance_mode:false
    }')"

  RESP="$(mktemp)"

  info "Membuat Node melalui Application API..."

  CODE="$(curl -sS -o "$RESP" -w '%{http_code}' \
    -X POST "$URL/api/application/nodes" \
    -H "Authorization: Bearer $API" \
    -H 'Accept: application/vnd.pterodactyl.v1+json' \
    -H 'Content-Type: application/json' \
    --data "$BODY")"

  if [[ "$CODE" != "201" ]]; then
    cat "$RESP"
    rm -f "$RESP"
    unset API
    fail "Gagal membuat Node (HTTP $CODE)."
  fi

  NODE_ID="$(jq -r '.attributes.id // empty' "$RESP")"
  rm -f "$RESP"

  [[ "$NODE_ID" =~ ^[0-9]+$ ]] ||
    fail "Node dibuat tetapi ID tidak terbaca."

  BODY="$(jq -n \
    --arg ip "$IP" \
    --arg alias "$ALIAS" \
    --argjson ports "$PORTS_JSON" \
    '{ip:$ip,alias:$alias,ports:$ports}')"

  RESP="$(mktemp)"

  info "Menambahkan allocation..."

  CODE="$(curl -sS -o "$RESP" -w '%{http_code}' \
    -X POST "$URL/api/application/nodes/$NODE_ID/allocations" \
    -H "Authorization: Bearer $API" \
    -H 'Accept: application/vnd.pterodactyl.v1+json' \
    -H 'Content-Type: application/json' \
    --data "$BODY")"

  unset API

  if [[ "$CODE" != "204" ]]; then
    cat "$RESP"
    rm -f "$RESP"
    fail "Node #$NODE_ID dibuat, tetapi allocation gagal."
  fi

  rm -f "$RESP"

  ok "Node #$NODE_ID dan allocation berhasil dibuat."
  warn "Selanjutnya pasang Wings pada VPS Node."
}

check_status(){
  echo
  echo "===== PTERODACTYL SERVICE STATUS ====="

  for svc in nginx mariadb redis-server php8.3-fpm pteroq docker wings; do
    if systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null |
      grep -q "${svc}.service"; then
      printf '%-18s' "$svc"
      systemctl is-active "$svc" || true
    fi
  done

  echo
  [[ -d "$PANEL_DIR" ]] &&
    echo "Panel directory : $PANEL_DIR" ||
    echo "Panel directory : belum ada"

  [[ -s /etc/pterodactyl/config.yml ]] &&
    echo "Wings config    : tersedia" ||
    echo "Wings config    : belum ada"

  echo "Log installer   : $LOG_FILE"
}

create_location_and_node_auto(){
  local URL API EMAIL NODE_NAME LOC_SHORT LOC_LONG NODE_FQDN PUBLIC_IP ALIAS
  local MEM MO DISK DO DPORT SFTP PORTS PORTS_JSON RESP CODE LOC_ID NODE_ID BODY CONFIG_TMP DNS_IPS

  ask URL "URL Panel (contoh https://panel.domain.com)"
  URL="${URL%/}"
  [[ "$URL" =~ ^https?://[^/]+$ ]] || fail "URL Panel tidak valid."

  ask_secret API "Application API key dari Panel yang baru dipasang"
  [[ "$API" == ptla_* ]] || fail "Gunakan Application API Key yang diawali ptla_."
  ask EMAIL "Email untuk SSL Node"
  valid_email "$EMAIL" || fail "Email tidak valid."
  ask NODE_NAME "Nama Node" "Autoinstall By Kaiiz"
  [[ "$NODE_NAME" =~ ^[a-zA-Z0-9_.\ -]{1,100}$ ]] || fail "Nama Node tidak valid."
  ask LOC_SHORT "Kode Location" "SGP"
  ask LOC_LONG "Nama Location" "Singapore"
  [[ "$LOC_SHORT" =~ ^[a-zA-Z0-9_-]{3,60}$ ]] || fail "Kode Location harus 3-60 karakter."
  ask NODE_FQDN "Domain Node (FQDN)"
  valid_domain "$NODE_FQDN" || fail "Domain Node tidak valid."

  PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
  [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "Tidak bisa mendeteksi IP publik VPS."
  ask PUBLIC_IP "IP publik VPS untuk allocation" "$PUBLIC_IP"
  ask ALIAS "Alias allocation" "$NODE_FQDN"
  DNS_IPS="$(getent ahostsv4 "$NODE_FQDN" | awk '{print $1}' | sort -u | tr '\n' ' ')"
  [[ -n "$DNS_IPS" ]] || fail "Domain Node belum bisa di-resolve. Atur DNS A record terlebih dahulu."
  [[ " $DNS_IPS " == *" $PUBLIC_IP "* ]] || fail "DNS $NODE_FQDN ($DNS_IPS) belum mengarah ke IP VPS ($PUBLIC_IP)."

  MEM="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  (( MEM > 1024 )) && MEM=$((MEM - 1024))
  DISK="$(df -Pm / | awk 'NR==2 {print $2}')"
  (( DISK > 10240 )) && DISK=$((DISK - 2048))
  ask MEM "Total RAM Node dalam MiB" "${MEM:-2048}"
  ask MO "RAM overallocation (%)" "0"
  ask DISK "Total disk Node dalam MiB" "${DISK:-20480}"
  ask DO "Disk overallocation (%)" "0"
  ask DPORT "Daemon port" "8080"
  ask SFTP "SFTP port" "2022"
  ask PORTS "Rentang port allocation" "25565-25600"

  for n in "$MEM" "$MO" "$DISK" "$DO" "$DPORT" "$SFTP"; do
    [[ "$n" =~ ^[0-9]+$ ]] || fail "Nilai RAM/disk/port harus berupa angka."
  done
  (( MEM > 0 && DISK > 0 && DPORT >= 1 && DPORT <= 65535 && SFTP >= 1 && SFTP <= 65535 )) || fail "Nilai RAM, disk, atau port tidak valid."
  PORTS_JSON="$(expand_ports "$PORTS")"

  info "Menyiapkan virtual host sementara untuk validasi SSL Node..."
  cat > /etc/nginx/sites-available/pterodactyl-node-acme.conf <<NGINX
server {
    listen 80;
    server_name ${NODE_FQDN};
    root ${PANEL_DIR}/public;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 404; }
}
NGINX
  ln -sfn /etc/nginx/sites-available/pterodactyl-node-acme.conf /etc/nginx/sites-enabled/pterodactyl-node-acme.conf
  nginx -t
  systemctl reload nginx
  info "Memasang sertifikat SSL untuk domain Node..."
  apt-get install -y certbot python3-certbot-nginx
  certbot --nginx -d "$NODE_FQDN" --non-interactive --agree-tos -m "$EMAIL" --redirect

  info "Mencari atau membuat Location '$LOC_SHORT'..."
  RESP="$(mktemp)"
  CODE="$(curl -sS -o "$RESP" -w '%{http_code}' "$URL/api/application/locations?per_page=100" \
    -H "Authorization: Bearer $API" -H 'Accept: application/vnd.pterodactyl.v1+json')"
  [[ "$CODE" == "200" ]] || { cat "$RESP"; rm -f "$RESP"; fail "Gagal membaca daftar Location (HTTP $CODE)."; }
  LOC_ID="$(jq -r --arg short "$LOC_SHORT" '.data[]? | select(.attributes.short == $short) | .attributes.id' "$RESP" | head -n1)"
  rm -f "$RESP"
  if [[ -z "$LOC_ID" ]]; then
    BODY="$(jq -n --arg short "$LOC_SHORT" --arg long "$LOC_LONG" '{short:$short,long:$long}')"
    RESP="$(mktemp)"
    CODE="$(curl -sS -o "$RESP" -w '%{http_code}' -X POST "$URL/api/application/locations" \
      -H "Authorization: Bearer $API" -H 'Accept: application/vnd.pterodactyl.v1+json' \
      -H 'Content-Type: application/json' --data "$BODY")"
    if [[ "$CODE" != "201" ]]; then cat "$RESP"; rm -f "$RESP"; fail "Gagal membuat Location (HTTP $CODE)."; fi
    LOC_ID="$(jq -r '.attributes.id // empty' "$RESP")"
    rm -f "$RESP"
  fi
  [[ "$LOC_ID" =~ ^[0-9]+$ ]] || fail "ID Location tidak terbaca."

  info "Membuat Node '$NODE_NAME'..."
  BODY="$(jq -n --arg name "$NODE_NAME" --argjson loc "$LOC_ID" --arg fqdn "$NODE_FQDN" \
    --argjson mem "$MEM" --argjson mo "$MO" --argjson disk "$DISK" --argjson do "$DO" \
    --argjson dp "$DPORT" --argjson sftp "$SFTP" \
    '{name:$name,location_id:$loc,fqdn:$fqdn,scheme:"https",behind_proxy:false,memory:$mem,memory_overallocate:$mo,disk:$disk,disk_overallocate:$do,daemon_listen:$dp,daemon_sftp:$sftp,daemon_base:"/var/lib/pterodactyl/volumes",upload_size:100,maintenance_mode:false}')"
  RESP="$(mktemp)"
  CODE="$(curl -sS -o "$RESP" -w '%{http_code}' -X POST "$URL/api/application/nodes" \
    -H "Authorization: Bearer $API" -H 'Accept: application/vnd.pterodactyl.v1+json' \
    -H 'Content-Type: application/json' --data "$BODY")"
  if [[ "$CODE" != "201" ]]; then cat "$RESP"; rm -f "$RESP"; fail "Gagal membuat Node (HTTP $CODE)."; fi
  NODE_ID="$(jq -r '.attributes.id // empty' "$RESP")"
  rm -f "$RESP"
  [[ "$NODE_ID" =~ ^[0-9]+$ ]] || fail "ID Node tidak terbaca."

  info "Membuat allocation..."
  BODY="$(jq -n --arg ip "$PUBLIC_IP" --arg alias "$ALIAS" --argjson ports "$PORTS_JSON" '{ip:$ip,alias:$alias,ports:$ports}')"
  RESP="$(mktemp)"
  CODE="$(curl -sS -o "$RESP" -w '%{http_code}' -X POST "$URL/api/application/nodes/$NODE_ID/allocations" \
    -H "Authorization: Bearer $API" -H 'Accept: application/vnd.pterodactyl.v1+json' \
    -H 'Content-Type: application/json' --data "$BODY")"
  if [[ "$CODE" != "204" ]]; then cat "$RESP"; rm -f "$RESP"; fail "Node dibuat (#$NODE_ID), tetapi allocation gagal (HTTP $CODE)."; fi
  rm -f "$RESP"

  info "Mengambil konfigurasi Wings dari Application API..."
  CONFIG_TMP="$(mktemp)"
  CODE="$(curl -sS -o "$CONFIG_TMP" -w '%{http_code}' "$URL/api/application/nodes/$NODE_ID/configuration" \
    -H "Authorization: Bearer $API" -H 'Accept: application/vnd.pterodactyl.v1+json')"
  unset API
  if [[ "$CODE" != "200" ]] || ! jq -e '.uuid and .token_id and .token and .api' "$CONFIG_TMP" >/dev/null 2>&1; then
    cat "$CONFIG_TMP"; rm -f "$CONFIG_TMP"
    fail "Node dibuat, tetapi konfigurasi Wings dari API tidak valid (HTTP $CODE). Periksa izin API/endpoint."
  fi
  # Wings expects the Panel URL in the config. The API response supplies the
  # node secrets and daemon settings; add the remote URL explicitly.
  jq --arg remote "$URL" '. + {remote:$remote}' "$CONFIG_TMP" > "${CONFIG_TMP}.json"
  install -m 600 "${CONFIG_TMP}.json" /etc/pterodactyl/config.yml
  rm -f "$CONFIG_TMP" "${CONFIG_TMP}.json"
  ok "Location $LOC_SHORT (#$LOC_ID), Node '$NODE_NAME' (#$NODE_ID), dan allocation berhasil dibuat."
}

install_wings_from_api_config(){
  [[ -s /etc/pterodactyl/config.yml ]] || fail "Config Wings dari API tidak ditemukan."
  install_docker_wings
  local ARCH
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) fail "Arsitektur tidak didukung: $ARCH" ;;
  esac
  curl -fL --retry 3 "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}" -o /usr/local/bin/wings
  chmod 755 /usr/local/bin/wings
  cat > /etc/systemd/system/wings.service <<'UNIT'
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
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now wings
  ok "Wings terpasang dan service sudah diaktifkan."
}

install_both(){
  warn "Mode satu VPS: Panel + Location + Node + Wings."
  warn "Pastikan domain Panel dan domain Node sudah mengarah ke IP publik VPS ini."
  install_panel
  echo
  warn "Panel selesai dipasang. Buat Application API Key di Admin > Application API."
  warn "Gunakan key dari Panel yang baru dipasang; jangan gunakan Client API Key."
  create_location_and_node_auto
  install_wings_from_api_config
  echo
  ok "Instalasi Panel + Node + Wings selesai."
  warn "Periksa status Node di Admin > Nodes. Pastikan firewall membuka TCP 80, 443, 8080, 2022, dan rentang allocation."
}
panel_version_check(){
  [[ -d "$PANEL_DIR" && -f "$PANEL_DIR/artisan" ]] ||
    fail "Folder Panel tidak ditemukan: $PANEL_DIR"
  [[ -f "$PANEL_DIR/config/app.php" ]] ||
    fail "config/app.php tidak ditemukan. Pastikan ini instalasi Pterodactyl resmi."
  grep -Eq "['\"]version['\"][[:space:]]*=>[[:space:]]*['\"]${PANEL_VERSION}['\"]" \
    "$PANEL_DIR/config/app.php" ||
    fail "Versi Panel tidak cocok. Installer Protect ini ditargetkan untuk ${PANEL_VERSION}."
}

protect_install(){
  require_root
  check_os
  panel_version_check
  command -v php >/dev/null 2>&1 || fail "PHP tidak ditemukan."
  command -v tar >/dev/null 2>&1 || fail "tar tidak ditemukan."
  [[ -s "$PROTECT_PAYLOAD" ]] ||
    fail "Payload Protect tidak ditemukan: $PROTECT_PAYLOAD. Letakkan protect-payload.tar.gz di folder yang sama dengan installer."

  if [[ -s "$PROTECT_STATE_FILE" ]]; then
    local active
    active="$(cat "$PROTECT_STATE_FILE")"
    if [[ -d "$active" ]]; then
      fail "Protect terdeteksi sudah terpasang dengan backup: $active. Uninstall/restore Protect terlebih dahulu."
    fi
  fi

  local stamp backup stage manifest rel src dst tmp status
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${PROTECT_BACKUP_ROOT}/${stamp}"
  stage="$(mktemp -d /tmp/ptero-protect-stage.XXXXXX)"
  manifest="${backup}/manifest.tsv"
  mkdir -p "$backup" "$(dirname "$PROTECT_STATE_FILE")"

  if ! tar -tzf "$PROTECT_PAYLOAD" >/dev/null; then
    rm -rf "$stage"
    fail "Arsip Protect rusak atau tidak valid."
  fi
  tar -xzf "$PROTECT_PAYLOAD" -C "$stage"

  [[ -d "$stage/app" && -d "$stage/resources" ]] || {
    rm -rf "$stage"; fail "Struktur payload Protect tidak valid."
  }

  local -a files=()
  mapfile -d '' files < <(find "$stage" -type f -print0 | sort -z)
  ((${#files[@]} > 0)) || { rm -rf "$stage"; fail "Payload Protect kosong."; }

  info "Memvalidasi seluruh file PHP sebelum mengubah Panel..."
  for src in "${files[@]}"; do
    if [[ "$src" == *.php ]]; then
      php -l "$src" >/dev/null || { rm -rf "$stage"; fail "Syntax PHP gagal: ${src#$stage/}"; }
    fi
  done

  printf 'relative_path\tbackup_status\n' > "$manifest"
  info "Membuat backup dan memasang Protect secara bertahap..."
  local applied=()
  for src in "${files[@]}"; do
    rel="${src#$stage/}"
    dst="${PANEL_DIR}/${rel}"
    mkdir -p "$(dirname "$dst")"
    if [[ -e "$dst" ]]; then
      cp -a "$dst" "${backup}/${rel}"
      status="BACKED_UP"
    else
      status="ABSENT"
    fi
    printf '%s\t%s\n' "$rel" "$status" >> "$manifest"

    tmp="$(mktemp "$(dirname "$dst")/.protect.XXXXXX")"
    cp "$src" "$tmp"
    if [[ -e "$dst" ]]; then
      chown --reference="$dst" "$tmp" 2>/dev/null || true
      chmod --reference="$dst" "$tmp" 2>/dev/null || true
    else
      chown www-data:www-data "$tmp" 2>/dev/null || true
      chmod 0644 "$tmp"
    fi
    if ! mv -f "$tmp" "$dst"; then
      rm -f "$tmp"
      warn "Pemasangan gagal. Memulihkan file yang sudah diproses..."
      while IFS=$'\t' read -r rel status; do
        [[ "$rel" == "relative_path" ]] && continue
        if [[ "$status" == "BACKED_UP" ]]; then
          mkdir -p "$(dirname "${PANEL_DIR}/${rel}")"
          cp -a "${backup}/${rel}" "${PANEL_DIR}/${rel}"
        else
          rm -f "${PANEL_DIR}/${rel}"
        fi
      done < "$manifest"
      rm -rf "$stage"
      fail "Protect gagal dipasang. File yang sudah diproses telah di-rollback. Backup: $backup"
    fi
    applied+=("$rel")
  done

  info "Memvalidasi ulang PHP setelah pemasangan..."
  for rel in "${applied[@]}"; do
    if [[ "$rel" == *.php ]]; then
      if ! php -l "${PANEL_DIR}/${rel}" >/dev/null; then
        warn "Validasi akhir gagal. Melakukan rollback otomatis..."
        while IFS=$'\t' read -r rel status; do
          [[ "$rel" == "relative_path" ]] && continue
          if [[ "$status" == "BACKED_UP" ]]; then
            cp -a "${backup}/${rel}" "${PANEL_DIR}/${rel}"
          else
            rm -f "${PANEL_DIR}/${rel}"
          fi
        done < "$manifest"
        rm -rf "$stage"
        fail "Validasi PHP gagal; rollback selesai. Backup: $backup"
      fi
    fi
  done

  chown -R www-data:www-data "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
  printf '%s\n' "$backup" > "$PROTECT_STATE_FILE"
  chmod 0600 "$PROTECT_STATE_FILE"
  if ! (cd "$PANEL_DIR" && php artisan view:clear && php artisan config:clear && php artisan route:clear && php artisan cache:clear); then
    warn "File Protect sudah terpasang, tetapi pembersihan cache Laravel gagal. Backup tetap tercatat: $backup"
  fi
  rm -rf "$stage"
  ok "Protect berhasil dipasang. Backup asli tersimpan di: $backup"
  warn "Ini validasi sintaks dan deployment file, bukan pengujian runtime. Uji login, admin, client, server, API, dan 2FA sebelum produksi."
}

protect_uninstall(){
  require_root
  panel_version_check
  [[ -s "$PROTECT_STATE_FILE" ]] ||
    fail "Tidak ada catatan backup Protect aktif. Uninstall otomatis tidak dapat dilanjutkan dengan aman."

  local backup manifest rel status
  backup="$(cat "$PROTECT_STATE_FILE")"
  [[ -d "$backup" && -s "$backup/manifest.tsv" ]] ||
    fail "Backup Protect tidak lengkap: $backup"
  manifest="$backup/manifest.tsv"
  echo
  warn "Fitur ini mengembalikan file Panel persis dari backup sebelum Protect dipasang."
  echo "Backup: $backup"
  read -r -p 'Ketik RESTORE PROTECT untuk melanjutkan: ' confirm
  [[ "$confirm" == "RESTORE PROTECT" ]] || { warn "Dibatalkan."; return 0; }

  while IFS=$'\t' read -r rel status; do
    [[ "$rel" == "relative_path" ]] && continue
    [[ -n "$rel" ]] || continue
    if [[ "$status" == "BACKED_UP" ]]; then
      [[ -f "$backup/$rel" ]] || fail "File backup hilang: $backup/$rel"
      mkdir -p "$(dirname "${PANEL_DIR}/${rel}")"
      cp -a "$backup/$rel" "${PANEL_DIR}/${rel}"
    elif [[ "$status" == "ABSENT" ]]; then
      rm -f "${PANEL_DIR}/${rel}"
    else
      fail "Status manifest tidak dikenal untuk $rel: $status"
    fi
  done < "$manifest"

  (cd "$PANEL_DIR" && php artisan view:clear && php artisan config:clear && php artisan route:clear && php artisan cache:clear)
  rm -f "$PROTECT_STATE_FILE"
  ok "File Panel telah dikembalikan dari backup. Backup tetap disimpan: $backup"
}

uninstall_panel(){
  require_root
  check_os
  [[ -d "$PANEL_DIR" && -f "$PANEL_DIR/artisan" ]] ||
    fail "Instalasi Panel tidak ditemukan di $PANEL_DIR."
  echo
  warn "Uninstall Panel akan menghapus source Panel, konfigurasi Nginx Pterodactyl, dan service queue pteroq."
  warn "Database, file server, Wings, Docker, MariaDB, Redis, PHP, dan Nginx tidak dihapus otomatis."
  read -r -p 'Ketik UNINSTALL PANEL untuk melanjutkan: ' confirm
  [[ "$confirm" == "UNINSTALL PANEL" ]] || { warn "Dibatalkan."; return 0; }

  local remove_db remove_data backup_dir
  backup_dir="/var/backups/pterodactyl-panel-uninstall/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$backup_dir"
  if [[ -f /etc/nginx/sites-available/pterodactyl.conf ]]; then
    cp -a /etc/nginx/sites-available/pterodactyl.conf "$backup_dir/"
  fi
  if [[ -f /etc/systemd/system/pteroq.service ]]; then
    cp -a /etc/systemd/system/pteroq.service "$backup_dir/"
  fi

  systemctl disable --now pteroq 2>/dev/null || true
  rm -f /etc/systemd/system/pteroq.service
  (crontab -l 2>/dev/null | grep -vF '/var/www/pterodactyl/artisan schedule:run' || true) | crontab -
  systemctl daemon-reload
  rm -f /etc/nginx/sites-enabled/pterodactyl.conf /etc/nginx/sites-available/pterodactyl.conf
  nginx -t && systemctl reload nginx || warn "Nginx tidak berhasil reload; periksa konfigurasi secara manual."

  read -r -p 'Hapus database panel dan user database? (ketik HAPUS DATABASE / selain itu pertahankan): ' remove_db
  if [[ "$remove_db" == "HAPUS DATABASE" ]]; then
    mariadb -u root <<'SQL'
DROP DATABASE IF EXISTS panel;
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
    ok "Database panel dan user database dihapus."
  else
    warn "Database panel dipertahankan."
  fi

  read -r -p 'Hapus data server /var/lib/pterodactyl? (ketik HAPUS DATA SERVER / selain itu pertahankan): ' remove_data
  if [[ "$remove_data" == "HAPUS DATA SERVER" ]]; then
    rm -rf /var/lib/pterodactyl
    ok "Data server dihapus sesuai konfirmasi."
  else
    warn "Data server dipertahankan."
  fi

  rm -rf "$PANEL_DIR"
  rm -f "$PROTECT_STATE_FILE"
  ok "Source Panel dan integrasi Nginx/queue dihapus. Backup konfigurasi: $backup_dir"
  warn "Service Wings, Docker, MariaDB, Redis, PHP, Nginx, firewall, sertifikat SSL, dan cron tidak dihapus. Periksa manual bila ingin membersihkannya."
}

menu(){
  while true; do
    clear || true

    echo -e "${BLUE}==============================================${NC}"
    echo "       PTERODACTYL AUTO INSTALLER"
    echo "                  v${PANEL_VERSION}"
    echo -e "${BLUE}==============================================${NC}"
    echo " [1] Install Panel"
    echo " [2] Install Wings"
    echo " [3] Install Panel + Wings (1 VPS)"
    echo " [4] Create Node"
    echo " [5] Check Status"
    echo " [6] Exit"
    echo " [7] Install Protect (Panel v${PANEL_VERSION})"
    echo " [8] Uninstall Protect / Restore Backup"
    echo " [9] Uninstall Panel"
    echo -e "${BLUE}==============================================${NC}"

    read -r -p "Pilih menu [1-9]: " choice

    case "$choice" in
      1) install_panel; read -r -p "Tekan Enter untuk kembali..." ;;
      2) install_wings; read -r -p "Tekan Enter untuk kembali..." ;;
      3) install_both; read -r -p "Tekan Enter untuk kembali..." ;;
      4) create_node; read -r -p "Tekan Enter untuk kembali..." ;;
      5) check_status; read -r -p "Tekan Enter untuk kembali..." ;;
      6) echo "Keluar."; exit 0 ;;
      7) protect_install; read -r -p "Tekan Enter untuk kembali..." ;;
      8) protect_uninstall; read -r -p "Tekan Enter untuk kembali..." ;;
      9) uninstall_panel; read -r -p "Tekan Enter untuk kembali..." ;;
      *) warn "Pilihan tidak valid."; sleep 1 ;;
    esac
  done
}

require_root
check_os
menu
