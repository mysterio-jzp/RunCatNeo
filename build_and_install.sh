#!/bin/bash
#
# build_and_install.sh
# RunCatNeo 一键打包并安装脚本
#
# 用法:
#   ./build_and_install.sh            # 打包 + 替换 /Applications/RunCatNeo.app + 重启
#   ./build_and_install.sh --no-relaunch   # 打包 + 替换, 不自动启动 app
#
# 说明:
#   - 使用项目根目录下的 DerivedData, 避免污染全局派生数据
#   - 跳过 SwiftPM 插件校验 (LicenseList 需要)
#   - 目标为 macOS arm64 (Apple Silicon)
#

set -euo pipefail

# ---------- 可调配置 ----------
APP_NAME="RunCatNeo"
SCHEME="RunCatNeo"
CONFIGURATION="Release"
DERIVED_DATA="$(cd "$(dirname "$0")" && pwd)/DerivedData"
APP_BUNDLE_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

# Keep Xcode build products out of Spotlight application search results.
touch "$DERIVED_DATA/.metadata_never_index"

# Xcode 选择: 优先使用已安装的 Xcode, 否则回退到命令行工具
if [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif [ -d "/Users/jiaozipan/Downloads/Xcode-beta.app" ]; then
    export DEVELOPER_DIR="/Users/jiaozipan/Downloads/Xcode-beta.app/Contents/Developer"
fi

RELAUNCH=1
for arg in "$@"; do
    case "$arg" in
        --no-relaunch) RELAUNCH=0 ;;
        *) echo "未知参数: $arg" >&2; exit 1 ;;
    esac
done

cd "$(dirname "$0")"

echo "==> [1/4] 编译 ($CONFIGURATION, arm64) ..."
xcodebuild build \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -skipPackagePluginValidation \
    -derivedDataPath "$DERIVED_DATA"

if [ ! -d "$APP_BUNDLE_PATH" ]; then
    echo "错误: 未找到构建产物 $APP_BUNDLE_PATH" >&2
    exit 1
fi

echo "==> [2/4] 停止正在运行的 $APP_NAME ..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

echo "==> [3/4] 替换 $INSTALL_PATH ..."
rm -rf "$INSTALL_PATH"
ditto "$APP_BUNDLE_PATH" "$INSTALL_PATH"

# Do not leave the build product registered as a second application by Spotlight.
rm -rf "$APP_BUNDLE_PATH" "$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app.dSYM"

if [ "$RELAUNCH" -eq 1 ]; then
    echo "==> [4/4] 启动 $APP_NAME ..."
    open -a "$APP_NAME"
else
    echo "==> [4/4] 跳过启动 (--no-relaunch)"
fi

echo "完成 ✅ 已安装: $INSTALL_PATH"
