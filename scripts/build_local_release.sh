#!/usr/bin/env bash
set -euo pipefail

# Build a local/LAN-friendly OTP release without changing the normal release script.
#
# Difference from scripts/build.sh:
#   - Temporarily compiles prod config without Plug.SSL force_ssl.
#   - Keeps check_origin disabled for local network browser access.
#   - Uses a separate MIX_BUILD_ROOT so the normal _build/prod release is untouched.
#
# Result:
#   _build/local_release/prod/rel/handbean

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MIX_ENV="${MIX_ENV:-prod}"
MIX_BUILD_ROOT="${MIX_BUILD_ROOT:-_build/local_release}"
RELEASE_DIR="$MIX_BUILD_ROOT/$MIX_ENV/rel/handbean"
PROD_CONFIG="config/prod.exs"
BACKUP_CONFIG="$(mktemp "${TMPDIR:-/tmp}/handbean-prod.exs.XXXXXX")"

restore_prod_config() {
  if [[ -f "$BACKUP_CONFIG" ]]; then
    cp "$BACKUP_CONFIG" "$PROD_CONFIG"
    rm -f "$BACKUP_CONFIG"
  fi
}
trap restore_prod_config EXIT INT TERM

cp "$PROD_CONFIG" "$BACKUP_CONFIG"

cat > "$PROD_CONFIG" <<'EOF'
import Config

# Local/LAN release profile.
# This file is written temporarily by scripts/build_local_release.sh and restored
# after the build. It intentionally does not configure force_ssl, because
# force_ssl is compile-time config and would redirect LAN HTTP requests to HTTPS.
config :handbean, HandbeanWeb.Endpoint,
  check_origin: false

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
EOF

echo "========================================"
echo " Handbean Local/LAN Release 构建脚本"
echo "========================================"
echo "当前环境:      $MIX_ENV"
echo "构建目录:      $MIX_BUILD_ROOT"
echo "Release 目录:  $RELEASE_DIR"
echo "LAN 行为:      允许 http://<局域网IP>:PORT 访问（不强制跳 HTTPS）"

echo ""
echo "➡ 获取 Elixir 依赖..."
MIX_ENV="$MIX_ENV" MIX_BUILD_ROOT="$MIX_BUILD_ROOT" mix deps.get

echo ""
echo "➡ 确保 ~/.handbean/ 目录存在..."
mkdir -p "$HOME/.handbean"

echo ""
echo "➡ 编译项目（local/LAN release config）..."
MIX_ENV="$MIX_ENV" MIX_BUILD_ROOT="$MIX_BUILD_ROOT" mix compile

echo ""
echo "➡ 构建前端资源..."
MIX_ENV="$MIX_ENV" MIX_BUILD_ROOT="$MIX_BUILD_ROOT" mix assets.setup
MIX_ENV="$MIX_ENV" MIX_BUILD_ROOT="$MIX_BUILD_ROOT" mix assets.deploy

echo ""
echo "➡ 构建 OTP Release..."
MIX_ENV="$MIX_ENV" MIX_BUILD_ROOT="$MIX_BUILD_ROOT" mix release handbean --overwrite

echo ""
if [[ -d "$RELEASE_DIR" ]]; then
  BIN="$RELEASE_DIR/bin/handbean"
  echo "🎉 Local/LAN release 构建完成！"
  echo "Release 目录: $RELEASE_DIR"
  echo "二进制:       $BIN"
  echo "大小:         $(du -sh "$RELEASE_DIR" | awk '{print $1}')"
else
  echo "⚠ 未找到 release 输出: $RELEASE_DIR"
  exit 1
fi

echo ""
echo "启动方式:"
echo "  PHX_SERVER=true PORT=5008 DATABASE_PATH=\"$HOME/.handbean/handbean.db\" SECRET_KEY_BASE=\"\$(openssl rand -base64 48)\" $BIN start"
echo ""
echo "访问地址:"
echo "  本机:   http://localhost:5008"
echo "  局域网: http://<本机局域网IP>:5008"
echo ""
echo "说明: 原 scripts/build.sh、config/prod.exs 和默认 _build/prod release 均不改。"
