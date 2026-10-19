#!/usr/bin/env bash
# ╔══════════════════════════════════════╗
# ║  Handbean — 一键启动脚本              ║
# ║  解压后运行此脚本即可使用          ║
# ╚══════════════════════════════════════╝
set -euo pipefail
umask 077

usage() {
  echo "Usage: bash start.sh [--lan HOST]"
  echo "Default: local access only. --lan enables password-protected HTTP on all IPv4 interfaces."
  echo "HOST must be the hostname or IPv4 address used by other devices, without scheme or port."
}

case "${1:-}" in
  --lan)
    if [[ $# -ne 2 || -z "$2" || "$2" == -* || "$2" == *[/:[:space:]]* ]]; then
      usage >&2
      exit 2
    fi
    export PHX_HOST="$2"
    export HANDBEAN_PUBLIC_BIND=1
    export HANDBEAN_ALLOW_HTTP=1
    export HANDBEAN_ACCESS_MODE=password
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release_dir="$script_dir"
if [[ ! -x "$release_dir/bin/handbean" ]]; then
  release_dir="$script_dir/../_build/prod/rel/handbean"
fi
if [[ ! -x "$release_dir/bin/handbean" ]]; then
  echo "Web UI release not found. Extract a Web UI package or build one with scripts/pack_webui.sh first." >&2
  exit 1
fi
cd "$release_dir"

export PHX_SERVER=true
export PORT="${PORT:-5008}"
export PHX_HOST="${PHX_HOST:-localhost}"
export DATABASE_PATH="${DATABASE_PATH:-$HOME/.handbean/handbean.db}"

if [[ "${HANDBEAN_PUBLIC_BIND:-0}" == 1 ]]; then
  echo "安全提醒：请设置足够长、随机且不重复使用的强密码，建议用密码管理器生成。"
  echo "Security reminder: use a long, random, unique strong password; a password manager is recommended."
fi

if [[ "${HANDBEAN_PUBLIC_BIND:-0}" == 1 && -z "${HANDBEAN_ACCESS_PASSWORD:-}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Set HANDBEAN_ACCESS_PASSWORD before starting public access without an interactive terminal." >&2
    exit 1
  fi
  read -r -s -p "Web UI password / Web UI 密码: " HANDBEAN_ACCESS_PASSWORD
  printf '\n'
  export HANDBEAN_ACCESS_PASSWORD
  if [[ -z "$HANDBEAN_ACCESS_PASSWORD" ]]; then
    echo "HANDBEAN_ACCESS_PASSWORD must not be empty." >&2
    exit 1
  fi
fi

if [[ -z "${SECRET_KEY_BASE:-}" ]]; then
  SECRET_KEY_BASE="$(openssl rand -base64 48)"
fi
export SECRET_KEY_BASE

if [[ -f .handbean-host ]]; then
  IFS= read -r packaged_host < .handbean-host || true
  case "$packaged_host" in
    macos) export HANDBEAN_FILE_MANAGER="${HANDBEAN_FILE_MANAGER:-macos}" ;;
    "") ;;
    *) echo "Unsupported packaged host declaration: $packaged_host" >&2; exit 2 ;;
  esac
fi

mkdir -p "$HOME/.handbean"

echo "🚀 Handbean 启动中..."
if [[ "${HANDBEAN_PUBLIC_BIND:-0}" == 1 ]]; then
  echo "   Listening: 0.0.0.0:$PORT (password authentication required)"
  if [[ "${HANDBEAN_ALLOW_HTTP:-0}" == 1 ]]; then
    echo "   Address: http://$PHX_HOST:$PORT"
  else
    echo "   Public address: https://$PHX_HOST (configure a TLS reverse proxy)"
  fi
else
  echo "   Local only: http://$PHX_HOST:$PORT"
fi
if [[ "${HANDBEAN_ALLOW_HTTP:-0}" == 1 ]]; then
  echo "   警告：HTTP 不加密密码或通信内容，仅用于受信任网络。"
  echo "   WARNING: HTTP does not encrypt passwords or traffic. Use trusted networks only."
fi
echo ""
echo "   按 Ctrl+C 停止"
echo ""

exec ./bin/handbean start
