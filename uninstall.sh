#!/usr/bin/env bash
# ==============================================================================
# FX Steam Launcher 简体中文汉化补丁 一键卸载与还原脚本
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
TARGET_DIR="${APP_PATH}/Contents/MacOS"
TARGET_BIN="${TARGET_DIR}/steamac-vm"
BACKUP_BIN="${TARGET_DIR}/steamac-vm.orig"

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
if pgrep -f "steamac-vm" >/dev/null 2>&1 || pgrep -f "FX Steam Launcher" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ 检测到 FX Steam Launcher 正在运行，正在退出...${RESET}"
    osascript -e 'quit app "FX Steam Launcher"' >/dev/null 2>&1 || true
    sleep 2
fi

# 3. 检查原版备份文件
echo -e "${BLUE}▶ 正在检查官方原版备份文件...${RESET}"
if [[ ! -f "$BACKUP_BIN" ]]; then
    echo -e "${RED}✘ 未找到官方原版备份文件: ${BACKUP_BIN}${RESET}"
    echo -e "${YELLOW}提示：如果备份文件已遗失，可直接从官方 Releases 页面重新下载覆盖安装应用程序：${RESET}"
    echo -e "      👉 官方发布页: https://github.com/fxgl/steamac/releases"
    exit 1
fi

# 4. 执行还原
echo -e "${BLUE}▶ 正在恢复官方原版英文核心...${RESET}"
cp -f "$BACKUP_BIN" "$TARGET_BIN"
chmod +x "$TARGET_BIN"
xattr -cr "$APP_PATH" 2>/dev/null || true

# 重新签名原版程序
echo -e "正在更新应用签名..."
codesign --force --sign - "$TARGET_BIN" >/dev/null 2>&1 || true

echo -e "\n${GREEN}${BOLD}✔ 官方原版已成功恢复！${RESET}"
echo -e "FX Steam Launcher 现已还原为纯官方英文界面。"
echo -e "随时可通过运行 ${CYAN}install.sh${RESET} 重新应用中文汉化。\n"
