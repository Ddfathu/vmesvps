#!/bin/bash

# ==============================================================================
# ALL-IN-ONE SETUP, CLOUDFLARE, SSL & CLI ACCOUNT MANAGER
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Harap jalankan script ini menggunakan sudo: sudo ./setup.sh"
  exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1

# ==============================================================================
# HELPER: DETEKSI OTOMATIS DOMAIN ARGO TUNNEL
# ==============================================================================
get_argo_domain() {
    local target_port="$1"
    local dom=""

    # 1. Coba deteksi dari /tmp/named_tunnel.log
    if [ -f "/tmp/named_tunnel.log" ]; then
        dom=$(grep -oE "\"hostname\":\"[^\"]+\"[^}]*localhost:$target_port" /tmp/named_tunnel.log 2>/dev/null | head -n 1 | sed -E 's/.*"hostname":"([^"]+)".*/\1/')
        if [ -z "$dom" ]; then
            dom=$(grep -oE "localhost:$target_port[^}]*\"hostname\":\"[^\"]+\"" /tmp/named_tunnel.log 2>/dev/null | head -n 1 | sed -E 's/.*"hostname":"([^"]+)".*/\1/')
        fi
    fi

    # 2. Coba deteksi dari systemd journalctl (jika dijalankan sebagai service)
    if [ -z "$dom" ]; then
        dom=$(journalctl -u cloudflared -n 100 --no-pager 2>/dev/null | grep -oE "\"hostname\":\"[^\"]+\"[^}]*localhost:$target_port" | head -n 1 | sed -E 's/.*"hostname":"([^"]+)".*/\1/')
    fi

    # 3. Fallback ke quick tunnel (trycloudflare) jika port 8001
    if [ -z "$dom" ] && [ "$target_port" == "8001" ]; then
        if [ -f ".tmp/boot.log" ]; then
            dom=$(grep -oE 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' .tmp/boot.log 2>/dev/null | tail -n 1 | sed 's#https://##')
        fi
    fi

    echo "$dom"
}

# ==============================================================================
# FUNGSI INSTALASI SISTEM & CLOUDFLARE ARGO TUNNEL
# ==============================================================================

install_core_dependencies() {
    echo ""
    echo "[1/5] Memperbarui sistem dan menginstall paket dasar..."
    export DEBIAN_FRONTEND=noninteractive
    apt update -y && apt upgrade -y
    apt install -y nodejs npm dropbear stunnel4 jq openssl net-tools cmake git build-essential curl wget certbot nginx

    echo "[2/5] Memasang Cloudflared..."
    if ! command -v cloudflared >/dev/null 2>&1; then
        ARCH=$(dpkg --print-architecture)
        wget -q -O /tmp/cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
        dpkg -i /tmp/cloudflared.deb 2>/dev/null || apt install -f -y
        rm -f /tmp/cloudflared.deb
    fi

    echo "[3/5] Mengompilasi BadVPN (UDPGW)..."
    if [ ! -f /usr/local/bin/badvpn-udpgw ]; then
        cd /tmp
        rm -rf badvpn
        git clone https://github.com/ambrop72/badvpn.git
        cd badvpn && mkdir build && cd build
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1
        make -j$(nproc)
        cp udpgw/badvpn-udpgw /usr/local/bin/
        chmod +x /usr/local/bin/badvpn-udpgw
        cd "$DIR" || exit 1
        rm -rf /tmp/badvpn
    fi

    echo "[4/5] Menginstall modul Node.js & PM2..."
    if [ ! -f package.json ]; then
        npm init -y >/dev/null 2>&1
    fi
    npm install axios >/dev/null 2>&1
    npm install -g pm2 >/dev/null 2>&1

    echo "[5/5] Menyiapkan permission & memulai panel..."
    chmod +x "$DIR/start.sh" "$DIR/setup.sh" 2>/dev/null
    pm2 delete vpn-panel 2>/dev/null
    pm2 start "$DIR/start.sh" --name "vpn-panel"
    pm2 save
    pm2 startup systemd -u root --hp /root 2>/dev/null

    echo ""
    echo "=========================================================="
    echo "    CORE INSTALL BERHASIL & PANEL SUDAH BERJALAN!         "
    echo "=========================================================="
    echo "🔹 Web Panel : http://$(curl -s ifconfig.me):8081"
    echo "=========================================================="
}

setup_cloudflare_tunnel() {
    echo ""
    echo "=========================================================="
    echo "       PASANG & ATUR CLOUDFLARE ARGO TUNNEL (VPS)        "
    echo "=========================================================="
    
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo "[*] Mengunduh dan memasang paket cloudflared..."
        ARCH=$(dpkg --print-architecture)
        wget -q -O /tmp/cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
        dpkg -i /tmp/cloudflared.deb 2>/dev/null || apt install -f -y
        rm -f /tmp/cloudflared.deb
    fi

    echo ""
    echo "Tempel Token Cloudflare Tunnel dari Zero Trust Dashboard:"
    read -p "Token: " CF_TOKEN
    CF_TOKEN=$(echo "$CF_TOKEN" | tr -d '[:space:]' | sed 's/^cloudflared service install //g' | sed 's/^cloudflared tunnel run --token //g')

    if [ -z "$CF_TOKEN" ]; then
        echo "[-] Token tidak boleh kosong!"
        return
    fi

    echo "[*] Menghentikan service tunnel lama..."
    systemctl stop cloudflared 2>/dev/null
    cloudflared service uninstall 2>/dev/null
    pkill -9 -f "cloudflared" 2>/dev/null

    echo "[*] Memasang service Cloudflare Tunnel..."
    cloudflared service install "$CF_TOKEN"

    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl restart cloudflared

    echo "$CF_TOKEN" > /tmp/zt_single_token.txt
    if [ -f "$DIR/.env" ]; then
        sed -i '/^TOKEN=/d' "$DIR/.env"
        echo "TOKEN=\"$CF_TOKEN\"" >> "$DIR/.env"
    else
        echo "TOKEN=\"$CF_TOKEN\"" > "$DIR/.env"
    fi

    TOKEN="$CF_TOKEN" pm2 restart vpn-panel --update-env 2>/dev/null

    sleep 3
    echo ""
    echo "=========================================================="
    if systemctl is-active --quiet cloudflared; then
        echo "[+] STATUS: Cloudflare Tunnel BERHASIL AKTIF & RUNNING!"
    else
        echo "[!] Peringatan: Cek status service:"
    fi
    systemctl status cloudflared --no-pager -n 5
    echo "=========================================================="
}

# ==============================================================================
# FUNGSI-FUNGSI PENGELOLA AKUN (CLI TERMUX)
# ==============================================================================

cli_add_ssh() {
    echo ""
    echo "--- BUAT AKUN SSH BARU (CLI) ---"
    read -p "Masukkan Username : " SSH_USER
    read -p "Masukkan Password : " SSH_PASS

    if [[ -z "$SSH_USER" || -z "$SSH_PASS" ]]; then
        echo "[-] Username dan password tidak boleh kosong!"
        return
    fi

    if id "$SSH_USER" >/dev/null 2>&1; then
        echo "[-] User $SSH_USER sudah ada di server!"
        return
    fi

    useradd -m -s /bin/bash "$SSH_USER"
    echo "$SSH_USER:$SSH_PASS" | chpasswd

    DB_PATH="/tmp/ssh_details.json"
    if [ ! -f "$DB_PATH" ]; then echo "{}" > "$DB_PATH"; fi
    jq --arg u "$SSH_USER" --arg p "$SSH_PASS" '.[$u] = {"password": $p, "ip": "CLI-Termux", "user_agent": "Termux-Terminal"}' "$DB_PATH" > /tmp/db_tmp.json && mv /tmp/db_tmp.json "$DB_PATH"

    PUB_IP=$(curl -s ifconfig.me)
    ARGO_SSH=$(get_argo_domain "8880")
    if [ -z "$ARGO_SSH" ]; then ARGO_SSH=$(get_argo_domain "8881"); fi

    echo ""
    echo "========================================"
    echo "        AKUN SSH BERHASIL DIBUAT        "
    echo "========================================"
    echo "🔹 Host / IP    : ${ARGO_SSH:-$PUB_IP}"
    echo "🔹 Port Direct  : 109"
    echo "🔹 Port Stunnel : 2443"
    echo "🔹 Port WS Argo : 443 (TLS) / 80 (NTLS)"
    echo "🔹 WS Path      : /ssh-ws"
    echo "🔹 Username     : $SSH_USER"
    echo "🔹 Password     : $SSH_PASS"
    echo "========================================"
}

cli_del_ssh() {
    echo ""
    echo "--- HAPUS AKUN SSH (CLI) ---"
    read -p "Masukkan Username yang mau dihapus: " SSH_USER
    if [[ -z "$SSH_USER" ]]; then
        echo "[-] Username kosong!"
        return
    fi

    if ! id "$SSH_USER" >/dev/null 2>&1; then
        echo "[-] User $SSH_USER tidak ditemukan!"
        return
    fi

    userdel -r "$SSH_USER" 2>/dev/null
    DB_PATH="/tmp/ssh_details.json"
    if [ -f "$DB_PATH" ]; then
        jq --arg u "$SSH_USER" 'del(.[$u])' "$DB_PATH" > /tmp/db_tmp.json && mv /tmp/db_tmp.json "$DB_PATH"
    fi
    echo "[+] User $SSH_USER berhasil dihapus dari sistem."
}

cli_list_ssh() {
    echo ""
    echo "========================================"
    echo "       DAFTAR USER SSH TERDAFTAR        "
    echo "========================================"
    awk -F: '$3 >= 1000 && !/nobody|ubuntu|sshd|dropbear|stunnel/ {print "• " $1}' /etc/passwd
    echo "========================================"
}

cli_generate_xray() {
    echo ""
    echo "--- CONFIG GENERATOR VLESS / VMESS / TROJAN ---"
    
    UUID="1f37ac4f-fdd0-49df-9406-1eda70a1d512"
    if [ -f ".tmp/config.json" ]; then
        EXTRACTED_UUID=$(jq -r '.inbounds[0].settings.clients[0].id // empty' .tmp/config.json 2>/dev/null)
        if [ -n "$EXTRACTED_UUID" ]; then UUID="$EXTRACTED_UUID"; fi
    fi

    PUB_IP=$(curl -s ifconfig.me)
    
    # Deteksi otomatis domain port 8001 (VMess/VLESS)
    DETECTED_ARGO=$(get_argo_domain "8001")
    DEFAULT_HOST="${DETECTED_ARGO:-$PUB_IP}"
    
    read -p "Target Domain/Host [Default: $DEFAULT_HOST]: " INPUT_DOMAIN
    HOST_DOMAIN="${INPUT_DOMAIN:-$DEFAULT_HOST}"

    read -p "Bug Host / SNI [Default: suport.garena.com]: " INPUT_BUG
    BUG_HOST="${INPUT_BUG:-suport.garena.com}"

    read -p "Remark / Nama Config [Default: DDFATHU]: " INPUT_NAME
    REMARK="${INPUT_NAME:-DDFATHU}"

    echo ""
    echo "Pilih Jalur Protokol:"
    echo " 1) VLESS WebSocket TLS"
    echo " 2) VMESS WebSocket TLS"
    echo " 3) TROJAN WebSocket TLS"
    read -p "Pilihan [1-3]: " PROTO_OPT

    echo ""
    echo "================ HASIL CONFIG ================"
    case $PROTO_OPT in
        1)
            VLESS_LINK="vless://${UUID}@${BUG_HOST}:443?encryption=none&security=tls&sni=${HOST_DOMAIN}&type=ws&host=${HOST_DOMAIN}&path=%2Fvless-argo%3Fed%3D2560#${REMARK}-VLESS"
            echo "$VLESS_LINK"
            ;;
        2)
            VMESS_JSON=$(cat <<EOF
{"v":"2","ps":"${REMARK}-VMESS","add":"${BUG_HOST}","port":"443","id":"${UUID}","aid":"0","scy":"auto","net":"ws","type":"none","host":"${HOST_DOMAIN}","path":"/vmess-argo?ed=2560","tls":"tls","sni":"${HOST_DOMAIN}"}
EOF
)
            VMESS_B64=$(echo -n "$VMESS_JSON" | base64 | tr -d '\n')
            echo "vmess://${VMESS_B64}"
            ;;
        3)
            TROJAN_LINK="trojan://${UUID}@${BUG_HOST}:443?security=tls&sni=${HOST_DOMAIN}&type=ws&host=${HOST_DOMAIN}&path=%2Ftrojan-argo%3Fed%3D2560#${REMARK}-TROJAN"
            echo "$TROJAN_LINK"
            ;;
        *)
            echo "[-] Pilihan tidak valid."
            ;;
    esac
    echo "=============================================="
}

# ==============================================================================
# FUNGSI DOMAIN & SERTIFIKAT SSL STANDALONE
# ==============================================================================

setup_domain_ssl() {
    echo ""
    echo "--- PENGATURAN DOMAIN & SERTIFIKAT ENCRYPT OTOMATIS ---"
    read -p "Masukkan nama domain/subdomain Anda: " TARGET_DOMAIN
    TARGET_DOMAIN=$(echo "$TARGET_DOMAIN" | tr -d '[:space:]')

    if [ -z "$TARGET_DOMAIN" ]; then
        echo "[-] Domain tidak boleh kosong!"
        return
    fi

    read -p "Masukkan email Anda: " USER_EMAIL
    USER_EMAIL=$(echo "$USER_EMAIL" | tr -d '[:space:]')
    EMAIL_ARG="--register-unsafely-without-email"
    if [ -n "$USER_EMAIL" ]; then
        EMAIL_ARG="-m $USER_EMAIL --no-eff-email"
    fi

    systemctl stop nginx 2>/dev/null
    certbot certonly --standalone -d "$TARGET_DOMAIN" --agree-tos $EMAIL_ARG --non-interactive

    CERT_PATH="/etc/letsencrypt/live/$TARGET_DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$TARGET_DOMAIN/privkey.pem"

    if [ ! -f "$CERT_PATH" ]; then
        echo "[-] Gagal membuat SSL Let's Encrypt. Periksa kembali A record DNS Anda."
        systemctl start nginx 2>/dev/null
        return
    fi

    cat "$CERT_PATH" "$KEY_PATH" > /etc/stunnel/stunnel.pem
    chmod 600 /etc/stunnel/stunnel.pem
    systemctl restart stunnel4 2>/dev/null

    cat <<EOF > /etc/nginx/sites-available/vpn-panel.conf
server {
    listen 80;
    server_name $TARGET_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $TARGET_DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/vpn-panel.conf /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl restart nginx

    echo "[+] Domain & SSL Aktif: https://$TARGET_DOMAIN"
}

renew_ssl_certificates() {
    echo ""
    echo "[*] Memperbarui sertifikat SSL..."
    systemctl stop nginx 2>/dev/null
    certbot renew --force-renewal
    FIRST_DOMAIN=$(ls -1 /etc/letsencrypt/live/ 2>/dev/null | grep -v 'README' | head -n 1)
    if [ -n "$FIRST_DOMAIN" ]; then
        cat "/etc/letsencrypt/live/$FIRST_DOMAIN/fullchain.pem" "/etc/letsencrypt/live/$FIRST_DOMAIN/privkey.pem" > /etc/stunnel/stunnel.pem
        chmod 600 /etc/stunnel/stunnel.pem
        systemctl restart stunnel4 2>/dev/null
    fi
    systemctl start nginx 2>/dev/null
    echo "[*] Pembaruan SSL selesai."
}

# ==============================================================================
# TAMPILAN MENU UTAMA
# ==============================================================================
while true; do
    clear
    echo "=================================================="
    echo "        SERVER TUNNEL & ACCOUNT MANAGER           "
    echo "             Ubuntu AWS EC2 Platform              "
    echo "=================================================="
    echo " 🔹 SETUP & CLOUDFLARE:"
    echo " [1] Install / Update Core Dependencies & PM2"
    echo " [2] Pasang / Input Token Cloudflare Argo Tunnel"
    echo ""
    echo " 🔹 PENGELOLA AKUN (CLI TERMUX):"
    echo " [3] Buat Akun SSH Baru"
    echo " [4] Hapus Akun SSH"
    echo " [5] Daftar Akun SSH"
    echo " [6] Buat Link Config (VLESS / VMess / Trojan)"
    echo ""
    echo " 🔹 DOMAIN & SISTEM:"
    echo " [7] Pasang Domain Sendiri (Auto SSL)"
    echo " [8] Perbarui (Renew) Sertifikat SSL"
    echo " [9] Cek Status PM2"
    echo " [10] Restart Semua Service"
    echo " [0] Keluar"
    echo "=================================================="
    read -p "Pilih menu [0-10]: " OPTION

    case $OPTION in
        1) install_core_dependencies; read -p "Tekan [Enter] untuk kembali..." ;;
        2) setup_cloudflare_tunnel; read -p "Tekan [Enter] untuk kembali..." ;;
        3) cli_add_ssh; read -p "Tekan [Enter] untuk kembali..." ;;
        4) cli_del_ssh; read -p "Tekan [Enter] untuk kembali..." ;;
        5) cli_list_ssh; read -p "Tekan [Enter] untuk kembali..." ;;
        6) cli_generate_xray; read -p "Tekan [Enter] untuk kembali..." ;;
        7) setup_domain_ssl; read -p "Tekan [Enter] untuk kembali..." ;;
        8) renew_ssl_certificates; read -p "Tekan [Enter] untuk kembali..." ;;
        9) pm2 status; read -p "Tekan [Enter] untuk kembali..." ;;
        10) pm2 restart vpn-panel; systemctl restart nginx stunnel4 cloudflared 2>/dev/null; echo "[*] Restart sukses!"; read -p "Tekan [Enter]..." ;;
        0) echo "Keluar."; exit 0 ;;
        *) echo "Pilihan tidak valid!"; sleep 1 ;;
    esac
done
