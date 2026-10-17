#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

usage() {
  cat <<'EOF'
Usage: bash scripts/build.sh [--replace [app]] [release-directory]

Build Handbean for the current platform. On macOS this creates a native
Handbean.app containing the production release, plus a distributable zip.
On other platforms it builds the production release into release-directory.

--replace copies the built app over an existing install. The default target
is /Applications/Handbean.app. Without --replace, an existing install is left
alone.
EOF
}

REPLACE=0
REPLACE_APP=""
RELEASE_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --replace)
      REPLACE=1
      if [[ $# -ge 2 && "$2" != --* && "$2" == *.app ]]; then
        REPLACE_APP="$2"
        shift 2
      else
        shift
      fi
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "未知参数: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$RELEASE_ARG" ]]; then
        echo "只能指定一个 release 目录" >&2
        usage >&2
        exit 2
      fi
      RELEASE_ARG="$1"
      shift
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  echo "多余参数: $*" >&2
  usage >&2
  exit 2
fi

echo "========================================"
echo " Handbean 常规部署构建脚本"
echo "========================================"

MIX_ENV="${MIX_ENV:-prod}"
PLATFORM="$(uname -s)"
echo "当前环境: $MIX_ENV"

if [[ -n "$RELEASE_ARG" ]]; then
  RELEASE_DIR="$RELEASE_ARG"
elif [[ "$PLATFORM" == "Darwin" ]]; then
  RELEASE_DIR="$PROJECT_ROOT/desktop/macos/build/handbean-web"
else
  RELEASE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/handbean/release"
fi

mkdir -p "$(dirname "$RELEASE_DIR")"
RELEASE_DIR="$(cd "$(dirname "$RELEASE_DIR")" && pwd -P)/$(basename "$RELEASE_DIR")"
echo "Release 目录: $RELEASE_DIR"

# 1. 获取依赖
echo ""
echo "➡ 获取 Elixir 依赖..."
mix deps.get

# 1.5 创建默认目录
echo ""
echo "➡ 确保 ~/.handbean/ 目录存在..."
mkdir -p "$HOME/.handbean"

# 2. 编译
echo ""
echo "➡ 编译项目..."
mix compile

# 3. 前端资源
echo ""
echo "➡ 构建前端资源..."
mix assets.setup
mix assets.deploy

# 5. 构建 OTP Release
echo ""
echo "➡ 构建 OTP Release..."
if [[ "$RELEASE_DIR" == "/" ]]; then
  echo "拒绝将系统根目录用作 Release 目录" >&2
  exit 2
fi
rm -rf "$RELEASE_DIR"
MIX_ENV=$MIX_ENV mix release handbean --path "$RELEASE_DIR" --overwrite

# 6. 检查输出
echo ""

if [[ -d "$RELEASE_DIR" ]]; then
  BIN="${RELEASE_DIR}/bin/handbean"
  echo "🎉 构建完成！"
  echo "Release 目录: $RELEASE_DIR"
  echo "二进制:       $BIN"
  echo "大小:         $(du -sh "$RELEASE_DIR" | awk '{print $1}')"
else
  echo "⚠ 未找到 release 输出"
  exit 1
fi

if [[ "$PLATFORM" == "Darwin" ]]; then
  echo ""
  echo "➡ 构建 macOS 原生客户端..."
  HANDBEAN_WEB_ROOT="$RELEASE_DIR" bash desktop/macos/scripts/build_app.sh

  APP="$PROJECT_ROOT/desktop/macos/build/Handbean.app"
  ARCHIVE="$PROJECT_ROOT/desktop/macos/build/Handbean-macos-arm64.zip"
  CHECKSUM="$ARCHIVE.sha256"
  rm -f "$ARCHIVE" "$CHECKSUM"
  ditto -c -k --keepParent "$APP" "$ARCHIVE"
  shasum -a 256 "$ARCHIVE" > "$CHECKSUM"
  codesign --verify --deep --strict "$APP"
  unzip -tq "$ARCHIVE"

  echo ""
  echo "🎉 macOS 客户端打包完成！"
  echo "App:      $APP"
  echo "Zip:      $ARCHIVE"
  echo "SHA-256:  $(awk '{print $1}' "$CHECKSUM")"
  echo "大小:     $(du -sh "$ARCHIVE" | awk '{print $1}')"

  if [[ "$REPLACE" -eq 1 ]]; then
    TARGET="${REPLACE_APP:-/Applications/Handbean.app}"
    case "$TARGET" in
      *.app) ;;
      *)
        echo "替换目标必须是 .app: $TARGET" >&2
        exit 2
        ;;
    esac
    if [[ -d "$TARGET" ]]; then
      built="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
      installed="$(cd "$(dirname "$TARGET")" && pwd -P)/$(basename "$TARGET")"
      if [[ "$built" == "$installed" ]]; then
        echo "替换目标就是刚构建的 App" >&2
        exit 2
      fi
    fi
    echo ""
    echo "➡ 替换已安装的应用: $TARGET"
    mkdir -p "$(dirname "$TARGET")"
    osascript -e "tell application \"Handbean\" to quit" >/dev/null 2>&1 || true
    rm -rf "$TARGET"
    ditto "$APP" "$TARGET"
    codesign --verify --deep --strict "$TARGET"
    # The build copy is a packaging artifact. Launchpad should only show the install.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true
    echo "已替换: $TARGET"
  fi
  exit 0
fi

echo ""
echo "默认配置已烘焙进 release (rel/env.sh.eex)，无需设置环境变量："
echo "  地址:      http://localhost:5008"
echo "  数据库:    ~/.handbean/handbean.db"
echo "  模型配置:  ~/.handbean/models.json"
echo "  运行日志:  ~/.handbean/runtime/log/"
echo "  崩溃转储:  ~/.handbean/runtime/erl_crash.dump"
echo ""
printf '  前台:  %q start\n' "$BIN"
printf '  后台:  %q daemon\n' "$BIN"
printf '  停止:  %q stop\n' "$BIN"
printf '  附加:  %q remote\n' "$BIN"
echo "  日志:  tail -F ~/.handbean/runtime/log/erlang.log.1"
echo ""
echo "如需自定义，可在启动前 export 覆盖任意变量："
echo "  PORT DATABASE_PATH HANDBEAN_RUNTIME_DIR OPENAI_BASE_URL OPENAI_MODEL"
