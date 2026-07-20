#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
PANEL_DIR="/opt/chaiya-panel"
API_DIR="/opt/chaiya-ssh-api"
CONF_DIR="/etc/chaiya"
BACKUP_DIR="/root/bead-vpn-backups/$(date +%Y%m%d-%H%M%S)"
NGINX_SITE="/etc/nginx/sites-available/bead-vpn-panel"

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
PKG_DIR="$SCRIPT_DIR"

usage() {
  cat <<'EOF'
BEAD VPN one-file installer

Install from GitHub:
  curl -fsSL https://raw.githubusercontent.com/benzvpn/bead-vpn/main/bead-vpn-onefile-installer.sh -o /tmp/bead-vpn.sh
  sudo GITHUB_REPO=benzvpn/bead-vpn bash /tmp/bead-vpn.sh install domain.com admin panel-password

Install from local files:
  sudo ./bead-vpn-onefile-installer.sh install domain.com admin panel-password

Install without SSL:
  sudo ./bead-vpn-onefile-installer.sh install 1.2.3.4 admin panel-password n

Update domain on same VPS:
  sudo ./bead-vpn-onefile-installer.sh update-domain new-domain.com
EOF
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run as root or sudo." >&2
    exit 1
  fi
}

backup_path() {
  local path="$1"
  if [[ -e "$path" ]]; then
    mkdir -p "$BACKUP_DIR$(dirname "$path")"
    cp -a "$path" "$BACKUP_DIR$path"
  fi
}

find_local_pkg() {
  if [[ -f "$PKG_DIR/app.py" && -f "$PKG_DIR/index.html" && -f "$PKG_DIR/sshws.html" ]]; then
    return 0
  fi
  if [[ -d "$SCRIPT_DIR/bead-vpn-install" ]]; then
    PKG_DIR="$SCRIPT_DIR/bead-vpn-install"
    if [[ -f "$PKG_DIR/app.py" && -f "$PKG_DIR/index.html" && -f "$PKG_DIR/sshws.html" ]]; then
      return 0
    fi
  fi
  return 1
}

download_github_pkg() {
  if [[ -z "$GITHUB_REPO" ]]; then
    return 1
  fi

  apt-get update
  apt-get install -y ca-certificates curl unzip

  local workdir zip_url
  workdir="$(mktemp -d)"
  zip_url="https://github.com/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.zip"
  curl -fL "$zip_url" -o "$workdir/source.zip"
  unzip -q "$workdir/source.zip" -d "$workdir"

  PKG_DIR="$(find "$workdir" -maxdepth 2 -type d -name bead-vpn-install | head -1)"
  if [[ -z "$PKG_DIR" || ! -f "$PKG_DIR/app.py" ]]; then
    PKG_DIR="$(find "$workdir" -maxdepth 2 -type f -name app.py -exec dirname {} \; | head -1)"
  fi

  if [[ -z "$PKG_DIR" || ! -f "$PKG_DIR/app.py" || ! -f "$PKG_DIR/index.html" || ! -f "$PKG_DIR/sshws.html" ]]; then
    echo "Required files not found in ${GITHUB_REPO}:${GITHUB_BRANCH}" >&2
    echo "Required: app.py, index.html, sshws.html" >&2
    exit 1
  fi
}

resolve_pkg() {
  if find_local_pkg; then
    return
  fi
  if download_github_pkg; then
    return
  fi
  echo "Cannot find app.py, index.html, sshws.html." >&2
  echo "Put this script with those files, or set GITHUB_REPO=owner/repo." >&2
  exit 1
}

install_packages() {
  apt-get update
  apt-get install -y \
    ca-certificates curl nginx certbot python3-certbot-nginx \
    python3 openssh-server dropbear websockify iproute2
}

install_files() {
  backup_path "$PANEL_DIR/index.html"
  backup_path "$PANEL_DIR/sshws.html"
  backup_path "$API_DIR/app.py"

  mkdir -p "$PANEL_DIR" "$API_DIR" "$CONF_DIR/exp"
  install -m 0755 "$PKG_DIR/app.py" "$API_DIR/app.py"
  install -m 0644 "$PKG_DIR/index.html" "$PANEL_DIR/index.html"
  install -m 0644 "$PKG_DIR/sshws.html" "$PANEL_DIR/sshws.html"
}

write_chaiya_config() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ { for (i=1;i<=NF;i++) if ($i=="src") { print $(i+1); exit } }')"
  mkdir -p "$CONF_DIR"
  printf '%s\n' "$DOMAIN" > "$CONF_DIR/domain.conf"
  printf '%s\n' "${ip:-}" > "$CONF_DIR/my_ip.conf"
  printf '%s\n' "$ADMIN_USER" > "$CONF_DIR/xui-user.conf"
  printf '%s\n' "$ADMIN_PASS" > "$CONF_DIR/xui-pass.conf"
  touch "$CONF_DIR/ssh_links.json"
  chmod 600 "$CONF_DIR/xui-user.conf" "$CONF_DIR/xui-pass.conf" "$CONF_DIR/ssh_links.json"
}

configure_ssh_services() {
  systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true

  backup_path /etc/default/dropbear
  cat >/etc/default/dropbear <<'EOF'
NO_START=0
DROPBEAR_PORT=109
DROPBEAR_EXTRA_ARGS="-p 143"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF
  systemctl enable dropbear
  systemctl restart dropbear
}

write_systemd() {
  cat >/etc/systemd/system/chaiya-ssh-api.service <<EOF
[Unit]
Description=BEAD VPN SSH API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $API_DIR/app.py
Restart=always
RestartSec=2
User=root
WorkingDirectory=$API_DIR

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/bead-ws-ssh.service <<'EOF'
[Unit]
Description=BEAD VPN WebSocket to SSH bridge
After=network-online.target dropbear.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/websockify --heartbeat=30 127.0.0.1:10080 127.0.0.1:109
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now chaiya-ssh-api
  systemctl enable --now bead-ws-ssh
}

write_nginx() {
  backup_path "$NGINX_SITE"
  cat >"$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $PANEL_DIR;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:6789/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /ssh {
        proxy_pass http://127.0.0.1:10080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
EOF
  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/bead-vpn-panel
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx
  systemctl reload nginx || systemctl restart nginx
}

issue_ssl() {
  if [[ "$USE_SSL" != "y" && "$USE_SSL" != "Y" ]]; then
    return
  fi
  if [[ -n "${EMAIL:-}" ]]; then
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect
  else
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect
  fi
}

install_panel() {
  DOMAIN="${1:-${DOMAIN:-}}"
  ADMIN_USER="${2:-${ADMIN_USER:-admin}}"
  ADMIN_PASS="${3:-${ADMIN_PASS:-}}"
  USE_SSL="${4:-${USE_SSL:-y}}"
  EMAIL="${5:-${EMAIL:-}}"

  if [[ -z "$DOMAIN" || -z "$ADMIN_USER" || -z "$ADMIN_PASS" ]]; then
    usage
    exit 1
  fi

  need_root
  resolve_pkg
  install_packages
  install_files
  write_chaiya_config
  configure_ssh_services
  write_systemd
  write_nginx
  issue_ssl

  cat <<EOF

Install complete
URL: https://$DOMAIN/
Login: $ADMIN_USER

Service:
  chaiya-ssh-api: $(systemctl is-active chaiya-ssh-api || true)
  bead-ws-ssh:    $(systemctl is-active bead-ws-ssh || true)
  nginx:          $(systemctl is-active nginx || true)
  dropbear:       $(systemctl is-active dropbear || true)

Backup: $BACKUP_DIR
EOF
}

update_domain() {
  DOMAIN="${1:-${DOMAIN:-}}"
  USE_SSL="${2:-${USE_SSL:-y}}"
  EMAIL="${3:-${EMAIL:-}}"
  if [[ -z "$DOMAIN" ]]; then
    usage
    exit 1
  fi
  need_root
  mkdir -p "$CONF_DIR"
  printf '%s\n' "$DOMAIN" > "$CONF_DIR/domain.conf"
  if [[ ! -f "$NGINX_SITE" ]]; then
    NGINX_SITE="$(grep -RIl -e '127[.]0[.]0[.]1:6789' -e '/opt/chaiya-panel' /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$NGINX_SITE" || ! -f "$NGINX_SITE" ]]; then
    echo "BEAD VPN nginx config was not found. Run install first." >&2
    exit 1
  fi
  cp -a "$NGINX_SITE" "$NGINX_SITE.bak.$(date +%Y%m%d-%H%M%S)"
  sed -i -E "s/server_name[[:space:]].*;/server_name $DOMAIN;/" "$NGINX_SITE"
  nginx -t
  systemctl reload nginx || systemctl restart nginx
  issue_ssl
  echo "Domain updated: https://$DOMAIN/"
}

cmd="${1:-install}"
case "$cmd" in
  install)
    shift || true
    install_panel "$@"
    ;;
  update-domain)
    shift || true
    update_domain "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    install_panel "$@"
    ;;
esac
