#!/usr/bin/env bash
# Pterodactyl Panel 1.x + Wings installer for Ubuntu 22.04/24.04
# Review before running. Requires root and a fresh server for Panel installation.
set -Eeuo pipefail

VERSION="1.15.1"
PANEL_DIR="/var/www/pterodactyl"
LOG_FILE="/var/log/pterodactyl-installer.log"
mkdir -p /var/log
exec > >(tee -a "$LOG_FILE") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
fail(){ echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
trap 'rc=$?; echo -e "${RED}[ERROR]${NC} Gagal pada baris $LINENO (exit $rc). Log: $LOG_FILE" >&2; exit "$rc"' ERR

require_root(){ [[ $EUID -eq 0 ]] || fail "Jalankan sebagai root: sudo -i"; }
check_os(){
  [[ -r /etc/os-release ]] || fail "Tidak dapat membaca /etc/os-release"
  . /etc/os-release
  [[ "$ID" == ubuntu && ( "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ) ]] || fail "Hanya Ubuntu 22.04/24.04 yang didukung. Terdeteksi: ${PRETTY_NAME:-unknown}"
  command -v systemctl >/dev/null || fail "systemd tidak tersedia"
}
ask(){ local __var="$1" __prompt="$2" __default="${3:-}" __value; if [[ -n "$__default" ]]; then read -r -p "$__prompt [$__default]: " __value; __value="${__value:-$__default}"; else read -r -p "$__prompt: " __value; fi; printf -v "$__var" '%s' "$__value"; }
ask_secret(){ local __var="$1" __prompt="$2" __value; read -r -s -p "$__prompt: " __value; echo; printf -v "$__var" '%s' "$__value"; }
valid_domain(){ [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }
valid_email(){ [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
need_fresh_panel(){
  [[ ! -e "$PANEL_DIR" ]] || fail "$PANEL_DIR sudah ada. Demi keamanan, installer tidak menimpa instalasi/data lama. Gunakan VPS baru atau backup dan pindahkan data secara manual."
  [[ ! -f /etc/nginx/sites-enabled/pterodactyl.conf ]] || fail "Konfigurasi Nginx Pterodactyl sudah ada; berhenti agar tidak menimpa."
}
apt_base(){ export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y curl ca-certificates gnupg software-properties-common apt-transport-https tar unzip git cron jq openssl; }
install_php_panel_deps(){
  if [[ "$VERSION_ID" == "22.04" ]]; then
    add-apt-repository -y ppa:ondrej/php
  fi
  apt-get update
  apt-get install -y nginx mariadb-server redis-server php8.3 php8.3-cli php8.3-common php8.3-gd php8.3-mysql php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-fpm php8.3-curl php8.3-zip php8.3-intl
  systemctl enable --now nginx mariadb redis-server php8.3-fpm
  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
}
install_panel(){
  require_root; check_os; need_fresh_panel
  local DOMAIN EMAIL USERNAME FIRST LAST PASS TZ DBPASS
  ask DOMAIN "Domain Panel (contoh panel.domain.com)"; valid_domain "$DOMAIN" || fail "Format domain tidak valid"
  ask EMAIL "Email admin"; valid_email "$EMAIL" || fail "Format email tidak valid"
  ask USERNAME "Username admin" "admin"
  ask FIRST "Nama depan admin" "Admin"
  ask LAST "Nama belakang admin" "Panel"
  ask_secret PASS "Password admin (minimal 8 karakter, huruf besar-kecil dan angka)"
  [[ ${#PASS} -ge 8 && "$PASS" =~ [A-Z] && "$PASS" =~ [a-z] && "$PASS" =~ [0-9] ]] || fail "Password harus minimal 8 karakter, memiliki huruf besar, huruf kecil, dan angka"
  ask TZ "Timezone PHP" "Asia/Jakarta"
  DBPASS="$(openssl rand -hex 24)"

  info "Memasang dependensi Panel..."; apt_base; install_php_panel_deps
  info "Membuat database dan user database secara otomatis..."
  systemctl enable --now mariadb
  mariadb -u root <<SQL
CREATE DATABASE panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DBPASS}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

  info "Mengunduh Pterodactyl Panel ${VERSION}..."
  mkdir -p "$PANEL_DIR"; cd "$PANEL_DIR"
  curl -fL --retry 3 "https://github.com/pterodactyl/panel/releases/download/v${VERSION}/panel.tar.gz" -o panel.tar.gz
  tar -xzf panel.tar.gz; rm -f panel.tar.gz
  cp .env.example .env
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction

  # Set the core environment values without printing the generated database password.
  export PANEL_URL="https://${DOMAIN}" DBPASS DOMAIN TZ
  python3 - <<'PY'
import os
p='/var/www/pterodactyl/.env'
values={
 'APP_URL':os.environ['PANEL_URL'], 'APP_TIMEZONE':os.environ['TZ'],
 'DB_CONNECTION':'mysql','DB_HOST':'127.0.0.1','DB_PORT':'3306',
 'DB_DATABASE':'panel','DB_USERNAME':'pterodactyl','DB_PASSWORD':os.environ['DBPASS'],
 'CACHE_DRIVER':'redis','SESSION_DRIVER':'redis','QUEUE_CONNECTION':'redis',
 'MAIL_MAILER':'log'
}
lines=open(p).read().splitlines()
seen=set(); out=[]
for line in lines:
    if '=' in line and not line.lstrip().startswith('#'):
        k=line.split('=',1)[0]
        if k in values:
            out.append(k+'='+values[k]); seen.add(k); continue
    out.append(line)
for k,v in values.items():
    if k not in seen: out.append(k+'='+v)
open(p,'w').write('\n'.join(out)+'\n')
PY
  php artisan key:generate --force
  php artisan migrate --seed --force
  php artisan p:user:make --email="$EMAIL" --username="$USERNAME" --name-first="$FIRST" --name-last="$LAST" --password="$PASS" --admin=1
  unset PASS DBPASS

  info "Mengatur Nginx..."
  cat > /etc/nginx/sites-available/pterodactyl.conf <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    root ${PANEL_DIR}/public;
    index index.php;
    client_max_body_size 100m;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \\n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
    }
    location ~ /\. { deny all; }
}
NGINX
  ln -sfn /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t; systemctl reload nginx

  info "Mengatur cron dan queue worker..."
  (crontab -l 2>/dev/null | grep -v '/var/www/pterodactyl/artisan schedule:run' || true; echo '* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1') | crontab -
  cat > /etc/systemd/system/pteroq.service <<'UNIT'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service
[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s
[Install]
WantedBy=multi-user.target
UNIT
  chown -R www-data:www-data "$PANEL_DIR"
  chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache"
  systemctl daemon-reload; systemctl enable --now pteroq

  echo
  warn "Pastikan DNS A record ${DOMAIN} sudah mengarah ke IP VPS dan port 80/443 terbuka."
  local SSL
  ask SSL "Pasang HTTPS Let's Encrypt sekarang? (y/n)" "y"
  if [[ "$SSL" =~ ^[Yy]$ ]]; then
    apt-get install -y certbot python3-certbot-nginx
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect
  else
    warn "Panel sementara menggunakan HTTP. Setelah DNS siap, jalankan: certbot --nginx -d ${DOMAIN}"
  fi
  ok "Panel selesai dipasang. URL: https://${DOMAIN}"
  warn "Simpan APP_KEY dari ${PANEL_DIR}/.env dan backup database secara aman. Log installer: ${LOG_FILE}"
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
  require_root; check_os
  local PANEL_URL NODE_ID TOKEN ARCH
  if [[ -f /etc/pterodactyl/config.yml ]]; then fail "/etc/pterodactyl/config.yml sudah ada; tidak akan ditimpa."; fi
  ask PANEL_URL "URL Panel (contoh https://panel.domain.com)"
  [[ "$PANEL_URL" =~ ^https?://[^/]+/?$ ]] || fail "URL Panel tidak valid"
  ask NODE_ID "Node ID dari Panel"
  [[ "$NODE_ID" =~ ^[0-9]+$ ]] || fail "Node ID harus angka"
  ask_secret TOKEN "Token Auto-Deploy dari tab Configuration Panel"
  [[ -n "$TOKEN" ]] || fail "Token tidak boleh kosong"
  apt_base; install_docker_wings
  mkdir -p /etc/pterodactyl
  ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) fail "Arsitektur tidak didukung: $ARCH";; esac
  curl -fL --retry 3 "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}" -o /usr/local/bin/wings
  chmod 755 /usr/local/bin/wings
  info "Mengambil konfigurasi Wings dari Panel melalui Auto-Deploy..."
  cd /etc/pterodactyl
  wings configure --panel-url "$PANEL_URL" --token "$TOKEN" --node "$NODE_ID"
  unset TOKEN
  [[ -s /etc/pterodactyl/config.yml ]] || fail "Auto-Deploy tidak menghasilkan config.yml"
  cat > /etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service
[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now wings
  ok "Wings dipasang dan service diaktifkan. Periksa: systemctl status wings"
  warn "Pastikan firewall/provider membuka port daemon (umumnya 8080) dan SFTP (umumnya 2022), sesuai konfigurasi node."
}

create_node(){
  require_root; check_os
  local URL API NAME LOC FQDN SCHEME MEM MO DISK DO DPORT SFTP IP PORTS ALIAS BODY RESP CODE NODE_ID
  command -v jq >/dev/null 2>&1 || apt-get install -y jq
  ask URL "URL Panel (contoh https://panel.domain.com)"; URL="${URL%/}"
  [[ "$URL" =~ ^https?://[^/]+$ ]] || fail "URL Panel tidak valid"
  ask_secret API "Application API key (ptla_...; jangan bagikan ke siapa pun)"
  [[ -n "$API" ]] || fail "API key kosong"
  ask NAME "Nama Node" "Node-1"
  ask LOC "Location ID (buat/lihat di Admin > Locations)"
  [[ "$LOC" =~ ^[0-9]+$ ]] || fail "Location ID harus angka"
  ask FQDN "FQDN atau IP Node"
  ask SCHEME "Skema koneksi Wings (http/https)" "https"
  [[ "$SCHEME" == http || "$SCHEME" == https ]] || fail "Skema harus http atau https"
  ask MEM "Total RAM node dalam MiB" "8192"
  ask MO "RAM overallocation (%)" "0"
  ask DISK "Total disk node dalam MiB" "51200"
  ask DO "Disk overallocation (%)" "0"
  ask DPORT "Daemon port" "8080"
  ask SFTP "SFTP port" "2022"
  ask IP "Allocation IP publik node (bukan 127.0.0.1)"
  ask PORTS "Rentang port allocation (contoh 25565-25600)" "25565-25600"
  ask ALIAS "Alias allocation (boleh sama dengan IP)" "$IP"
  for n in "$MEM" "$MO" "$DISK" "$DO" "$DPORT" "$SFTP"; do [[ "$n" =~ ^-?[0-9]+$ ]] || fail "Nilai RAM/disk/port/overallocation harus angka"; done
  [[ "$MEM" -gt 0 && "$DISK" -gt 0 && "$DPORT" -ge 1 && "$DPORT" -le 65535 && "$SFTP" -ge 1 && "$SFTP" -le 65535 ]] || fail "Nilai RAM/disk/port di luar batas"
  [[ "$FQDN" != "127.0.0.1" && "$IP" != "127.0.0.1" ]] || fail "Jangan gunakan 127.0.0.1 untuk FQDN/allocation publik"
  BODY="$(jq -n --arg name "$NAME" --argjson loc "$LOC" --arg fqdn "$FQDN" --arg scheme "$SCHEME" --argjson mem "$MEM" --argjson mo "$MO" --argjson disk "$DISK" --argjson do "$DO" --argjson dp "$DPORT" --argjson sftp "$SFTP" '{name:$name,location_id:$loc,fqdn:$fqdn,scheme:$scheme,behind_proxy:false,memory:$mem,memory_overallocate:$mo,disk:$disk,disk_overallocate:$do,daemon_listen:$dp,daemon_sftp:$sftp,daemon_base:"/var/lib/pterodactyl/volumes",upload_size:100,maintenance_mode:false}')"
  RESP="$(mktemp)"
  info "Membuat node melalui Application API..."
  CODE="$(curl -sS -o "$RESP" -w '%{http_code}' -X POST "$URL/api/application/nodes" -H "Authorization: Bearer $API" -H 'Accept: application/vnd.pterodactyl.v1+json' -H 'Content-Type: application/json' --data "$BODY")"
  if [[ "$CODE" != 201 ]]; then cat "$RESP"; rm -f "$RESP"; unset API; fail "API gagal membuat node (HTTP $CODE). Periksa API key, permission, Location ID, dan validasi FQDN."; fi
  NODE_ID="$(jq -r '.attributes.id // empty' "$RESP")"
  rm -f "$RESP"
  [[ "$NODE_ID" =~ ^[0-9]+$ ]] || fail "Node dibuat tetapi ID tidak terbaca. Periksa Admin > Nodes."
  info "Node berhasil dibuat dengan ID $NODE_ID. Menambahkan allocation..."
  BODY="$(jq -n --arg ip "$IP" --arg alias "$ALIAS" --arg ports "$PORTS" '{ip:$ip,alias:$alias,ports:[$ports]}')"
  RESP="$(mktemp)"
  CODE="$(curl -sS -o "$RESP" -w '%{http_code}' -X POST "$URL/api/application/nodes/$NODE_ID/allocations" -H "Authorization: Bearer $API" -H 'Accept: application/vnd.pterodactyl.v1+json' -H 'Content-Type: application/json' --data "$BODY")"
  unset API
  if [[ "$CODE" != 204 ]]; then cat "$RESP"; rm -f "$RESP"; fail "Node sudah dibuat (ID $NODE_ID), tetapi allocation gagal (HTTP $CODE). Tambahkan allocation dari Admin > Nodes > Allocation."; fi
  rm -f "$RESP"
  ok "Node #$NODE_ID dan allocation berhasil dibuat."
  warn "Berikutnya pasang Wings di VPS node, lalu jalankan Auto-Deploy dari tab Configuration."
}

check_status(){
  echo; echo "===== PTERODACTYL SERVICE STATUS ====="
  for svc in nginx mariadb redis-server php8.3-fpm pteroq docker wings; do
    if systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q "${svc}.service"; then
      printf '%-18s' "$svc"; systemctl is-active "$svc" || true
    fi
  done
  echo; [[ -d "$PANEL_DIR" ]] && echo "Panel directory : $PANEL_DIR" || echo "Panel directory : belum ada"
  [[ -s /etc/pterodactyl/config.yml ]] && echo "Wings config    : tersedia" || echo "Wings config    : belum ada"
  echo "Log installer   : $LOG_FILE"
}
install_both(){
  warn "Panel + Wings pada satu VPS hanya cocok untuk instalasi baru. Pastikan DNS panel dan node sudah diarahkan ke IP VPS ini."
  install_panel
  echo
  warn "Panel selesai. Buat Node di Admin > Nodes, lalu ambil Auto-Deploy command/token."
  read -r -p "Tekan Enter setelah Node dibuat dan token Auto-Deploy siap..."
  install_wings
}
menu(){
  while true; do
    clear || true
    echo -e "${BLUE}==============================================${NC}"
    echo -e "       PTERODACTYL AUTO INSTALLER ${VERSION}"
    echo -e "${BLUE}==============================================${NC}"
    echo " [1] Install Panel"
    echo " [2] Install Wings"
    echo " [3] Install Panel + Wings (1 VPS)"
    echo " [4] Create Node (Application API)"
    echo " [5] Check Status"
    echo " [6] Exit"
    echo -e "${BLUE}==============================================${NC}"
    read -r -p "Pilih menu [1-6]: " choice
    case "$choice" in
      1) install_panel; read -r -p "Tekan Enter untuk kembali ke menu..." ;;
      2) install_wings; read -r -p "Tekan Enter untuk kembali ke menu..." ;;
      3) install_both; read -r -p "Tekan Enter untuk kembali ke menu..." ;;
      4) create_node; read -r -p "Tekan Enter untuk kembali ke menu..." ;;
      5) check_status; read -r -p "Tekan Enter untuk kembali ke menu..." ;;
      6) echo "Keluar."; exit 0 ;;
      *) warn "Pilihan tidak valid."; sleep 1 ;;
    esac
  done
}

require_root
check_os
menu
