#!/usr/bin/env bash
set -Eeuo pipefail

# One-click MTG installer for Ubuntu/Debian.
# After install it prints a ready-to-use Telegram proxy link.
#
# Optional env vars:
#   MTG_VERSION=2.2.8
#   MTG_PORT=3128
#   MTG_DOMAIN=storage.googleapis.com
#   MTG_PUBLIC_HOST=proxy.example.com
#
# Example:
#   MTG_PORT=443 MTG_DOMAIN=cdn.example.com bash install-mtg-oneliner.sh

MTG_VERSION="${MTG_VERSION:-2.2.8}"
MTG_PORT="${MTG_PORT:-3128}"
MTG_DOMAIN="${MTG_DOMAIN:-storage.googleapis.com}"
MTG_PUBLIC_HOST="${MTG_PUBLIC_HOST:-}"
MTG_BIND_IP="${MTG_BIND_IP:-0.0.0.0}"

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root." >&2
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl tar ca-certificates
}

arch_to_mtg() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l|armv6) echo "armv6" ;;
    i386|i686) echo "386" ;;
    *)
      echo "Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

get_public_host() {
  if [[ -n "$MTG_PUBLIC_HOST" ]]; then
    echo "$MTG_PUBLIC_HOST"
    return
  fi

  local ip
  ip="$(curl -4fsS https://api.ipify.org || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return
  fi

  ip="$(curl -4fsS https://ifconfig.me || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip"
    return
  fi

  hostname -I 2>/dev/null | awk '{print $1}'
}

open_firewall() {
  if need_cmd ufw; then
    ufw allow "${MTG_PORT}/tcp" >/dev/null 2>&1 || true
  fi
}

write_config() {
  mkdir -p /etc/mtg
  cat > /etc/mtg/config.toml <<CFG
secret = "${SECRET_HEX}"
bind-to = "${MTG_BIND_IP}:${MTG_PORT}"
concurrency = 8192
prefer-ip = "prefer-ipv6"
auto-update = false
tolerate-time-skewness = "5s"
allow-fallback-on-unknown-dc = false

[network]
dns = "https://1.1.1.1"

[network.timeout]
tcp = "5s"
http = "10s"
idle = "5m"
handshake = "10s"

[network.keep-alive]
disabled = false
idle = "15s"
interval = "15s"
count = 9

[defense.anti-replay]
enabled = true
max-size = "1mib"
error-rate = 0.001

[defense.blocklist]
enabled = true
download-concurrency = 2
urls = [
    "https://iplists.firehol.org/files/firehol_level1.netset",
]
update-each = "24h"

[stats.prometheus]
enabled = false
bind-to = "127.0.0.1:3129"
http-path = "/"
metric-prefix = "mtg"
CFG
}

install_service() {
  id mtg >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin mtg

  cat > /etc/systemd/system/mtg.service <<'UNIT'
[Unit]
Description=MTG Telegram Proxy
Documentation=https://github.com/9seconds/mtg
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mtg
Group=mtg
ExecStart=/usr/local/bin/mtg run /etc/mtg/config.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now mtg
}

print_result() {
  local public_host link_json tg_url tme_url
  public_host="$(get_public_host)"

  if [[ -n "$public_host" ]]; then
    # Temporarily replace bind host only for access generation if it is 0.0.0.0.
    link_json="$(MTG_PUBLIC_HOST="$public_host" python3 - <<'PY'
import json, os, re, subprocess
cfg='/etc/mtg/config.toml'
out=subprocess.check_output(['/usr/local/bin/mtg','access',cfg], text=True)
print(out)
PY
)"
    tg_url="$(printf '%s' "$link_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("ipv4",{}).get("tg_url", ""))')"
    tme_url="$(printf '%s' "$link_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("ipv4",{}).get("tme_url", ""))')"
  fi

  if [[ -z "${tg_url:-}" || -z "${tme_url:-}" ]]; then
    tme_url="https://t.me/proxy?server=${public_host}&port=${MTG_PORT}&secret=${SECRET_HEX}"
    tg_url="tg://proxy?server=${public_host}&port=${MTG_PORT}&secret=${SECRET_HEX}"
  fi

  echo
  echo "MTG installed successfully."
  echo "Version: $(/usr/local/bin/mtg --version)"
  echo "Service: systemctl status mtg --no-pager"
  echo "Config : /etc/mtg/config.toml"
  echo ""
  echo "Telegram link:"
  echo "$tme_url"
  echo ""
  echo "tg:// link:"
  echo "$tg_url"
  echo ""
  echo "Secret: $SECRET_HEX"
  echo "Host  : $public_host"
  echo "Port  : $MTG_PORT"
}

main() {
  require_root
  install_packages

  local arch pkg url tmpdir
  arch="$(arch_to_mtg)"
  pkg="mtg-${MTG_VERSION}-linux-${arch}.tar.gz"
  url="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/${pkg}"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  curl -fL "$url" -o "$tmpdir/mtg.tar.gz"
  tar -xzf "$tmpdir/mtg.tar.gz" -C "$tmpdir"
  install -m 755 "$tmpdir"/mtg-*/mtg /usr/local/bin/mtg

  SECRET_HEX="$(/usr/local/bin/mtg generate-secret --hex "$MTG_DOMAIN")"
  write_config
  open_firewall
  install_service
  print_result
}

main "$@"
