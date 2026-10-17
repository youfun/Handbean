#!/usr/bin/env bash
# ╔══════════════════════════════════════╗
# ║  Handbean — 一键启动脚本              ║
# ║  解压后运行此脚本即可使用          ║
# ╚══════════════════════════════════════╝
set -euo pipefail
cd "$(dirname "$0")"

export PHX_SERVER=true
export PORT="${PORT:-5008}"
export PHX_HOST="${PHX_HOST:-localhost}"
export DATABASE_PATH="${DATABASE_PATH:-$HOME/.handbean/handbean.db}"
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -base64 48 2>/dev/null || echo 'dev-fallback')}"

if [[ -f .handbean-host ]]; then
  IFS= read -r packaged_host < .handbean-host || true
  case "$packaged_host" in
    macos) export HANDBEAN_FILE_MANAGER="${HANDBEAN_FILE_MANAGER:-macos}" ;;
    "") ;;
    *) echo "Unsupported packaged host declaration: $packaged_host" >&2; exit 2 ;;
  esac
fi

mkdir -p "$HOME/.handbean"

# 获取本机 LAN IP（Linux 用 ip，macOS 回退 ifconfig）
lan_ip=""

if command -v ip >/dev/null 2>&1; then
  lan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)
fi

if [[ -z "$lan_ip" ]] && command -v ifconfig >/dev/null 2>&1; then
  lan_ip=$(ifconfig 2>/dev/null |
    grep -Eo 'inet (addr:)?192\.168\.[0-9.]+' |
    head -1 |
    awk '{print $2}' || true)
fi

if [[ -z "$lan_ip" ]] && command -v ifconfig >/dev/null 2>&1; then
  lan_ip=$(ifconfig 2>/dev/null |
    grep -Eo 'inet (addr:)?10\.[0-9.]+' |
    head -1 |
    awk '{print $2}' || true)
fi

echo "🚀 Handbean 启动中..."
echo "   本机:     http://localhost:$PORT"
if [[ -n "$lan_ip" ]]; then
  echo "   局域网:   http://$lan_ip:$PORT"
fi
echo ""
echo "   VPS 部署时建议: export HANDBEAN_CHECK_ORIGIN=true"
echo "   按 Ctrl+C 停止"
echo ""

exec ./bin/handbean start
