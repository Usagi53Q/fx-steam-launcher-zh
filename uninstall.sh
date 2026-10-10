#!/usr/bin/env bash
# ==============================================================================
# FX Steam Launcher 汉化补丁 一键卸载与还原脚本
# ==============================================================================

set -e

# 终端彩色输出定义
BOLD="\033[1m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

APP_PATH="/Applications/FX Steam Launcher.app"
RESOURCES_DIR="${APP_PATH}/Contents/Resources"
TARGET_DIR="${APP_PATH}/Contents/MacOS"
TARGET_BIN="${TARGET_DIR}/steamac-vm"
BACKUP_BIN="${TARGET_DIR}/steamac-vm.orig"
BUNDLE_ID="es.fxgam.steamac"

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║             FX Steam Launcher 汉化补丁卸载与还原程序              ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# 1. 检查运行环境
if [[ ! -d "$APP_PATH" ]]; then
    echo -e "${RED}✘ 未在“/Applications”目录中找到“FX Steam Launcher.app”。${RESET}"
    exit 1
fi

# 2. 检查是否有运行中的实例
if pgrep -x "steamac-vm" >/dev/null 2>&1 || [[ "$(osascript -e 'application "FX Steam Launcher" is running' 2>/dev/null)" == "true" ]]; then
    echo -e "${YELLOW}⚠ 检测到 FX Steam Launcher 正在运行，正在退出...${RESET}"
    osascript -e 'quit app "FX Steam Launcher"' >/dev/null 2>&1 || true
    sleep 2
fi

# 3. 还原系统语言绑定
echo -e "${BLUE}▶ 正在重置应用语言设置为跟随系统默认...${RESET}"
defaults delete "${BUNDLE_ID}" AppleLanguages 2>/dev/null || true

# 4. 若存在备份二进制，恢复原版
if [[ -f "$BACKUP_BIN" ]]; then
    echo -e "${BLUE}▶ 正在恢复官方原版核心二进制...${RESET}"
    cp -f "$BACKUP_BIN" "$TARGET_BIN"
    rm -f "$BACKUP_BIN"
    chmod +x "$TARGET_BIN"
    xattr -cr "$APP_PATH" 2>/dev/null || true
    codesign --force --sign - "$TARGET_BIN" >/dev/null 2>&1 || true
fi

# 5. 若添加过第三方繁体资源包，安全清理
if [[ -d "${RESOURCES_DIR}/zh-Hant.lproj" ]]; then
    rm -rf "${RESOURCES_DIR}/zh-Hant.lproj"
fi

echo -e "\n${GREEN}${BOLD}✔ 官方原版状态已成功恢复！${RESET}"
echo -e "FX Steam Launcher 现已还原为跟随系统默认语言的官方原版状态。"
echo -e "随时可通过运行 ${CYAN}install.sh${RESET} 重新应用中文汉化。\n"
