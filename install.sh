
#!/usr/bin/env bash
# Pterodactyl Panel + Wings Auto Installer
# Ubuntu 22.04 / 24.04
# Review and test before production use.

set -Eeuo pipefail

PANEL_VERSION="1.15.2"
PANEL_DIR="/var/www/pterodactyl"
LOG_FILE="/var/log/pterodactyl-installer.log"

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

  wings configure \
    --panel-url "$PANEL_URL" \
    --token "$TOKEN" \
    --node "$NODE_ID"

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

  local URL API NAME LOC FQDN SCHEME MEM MO DISK DO DPORT SFTP IP PORTS ALIAS
  local BODY RESP CODE NODE_ID PORTS_JSON

  command -v jq >/dev/null 2>&1 || apt-get install -y jq

  ask URL "URL Panel"
  URL="${URL%/}"
  [[ "$URL" =~ ^https?://[^/]+$ ]] || fail "URL Panel tidak valid."

  ask_secret API "Application API key"
  [[ -n "$API" ]] || fail "API key kosong."

  ask NAME "Nama Node" "Node-1"
  ask LOC "Location ID"
  [[ "$LOC" =~ ^[0-9]+$ ]] || fail "Location ID harus angka."

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

install_both(){
  warn "Panel + Wings dalam satu VPS."
  warn "Pastikan DNS domain Panel dan Node sudah diarahkan ke IP VPS ini."

  install_panel

  echo
  warn "Buat Node di Admin > Nodes, lalu ambil token Auto-Deploy."
  read -r -p "Tekan Enter setelah Node dan token siap..."

  install_wings
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
    echo -e "${BLUE}==============================================${NC}"

    read -r -p "Pilih menu [1-6]: " choice

    case "$choice" in
      1) install_panel; read -r -p "Tekan Enter untuk kembali..." ;;
      2) install_wings; read -r -p "Tekan Enter untuk kembali..." ;;
      3) install_both; read -r -p "Tekan Enter untuk kembali..." ;;
      4) create_node; read -r -p "Tekan Enter untuk kembali..." ;;
      5) check_status; read -r -p "Tekan Enter untuk kembali..." ;;
      6) echo "Keluar."; exit 0 ;;
      *) warn "Pilihan tidak valid."; sleep 1 ;;
    esac
  done
}

require_root
check_os
menu
