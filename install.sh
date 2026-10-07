#!/usr/bin/env bash
# ==============================================================================
# FX Steam Launcher 简体中文汉化补丁 一键安装脚本
# 支持本地运行与 curl 远程一键安装
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

# GitHub 仓库配置（远程一键安装时使用）
GITHUB_REPO="${FX_ZH_REPO:-https://github.com/Usagi53Q/fx-steam-launcher-zh}"
REMOTE_RAW_URL="${FX_ZH_RAW_URL:-https://raw.githubusercontent.com/Usagi53Q/fx-steam-launcher-zh/main}"

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║             FX Steam Launcher 简体中文汉化补丁安装程序           ║"
echo "║       Apple Silicon (M1/M2/M3/M4) 原生 SteamOS 虚拟机启动器      ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# 1. 检查操作系统与芯片架构
echo -e "${BLUE}▶ 步骤 1/5：正在检测运行环境...${RESET}"
OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"

if [[ "$OS_NAME" != "Darwin" ]]; then
    echo -e "${RED}✘ 错误：本汉化补丁仅支持 macOS 操作系统。${RESET}"
    exit 1
fi

if [[ "$ARCH_NAME" != "arm64" ]]; then
    echo -e "${RED}✘ 错误：FX Steam Launcher 仅适用于 Apple Silicon (ARM64) 架构 Mac。${RESET}"
    exit 1
fi
echo -e "${GREEN}✔ 环境检测通过：macOS (${ARCH_NAME})${RESET}"

# 2. 检查 FX Steam Launcher 应用程序是否存在
echo -e "${BLUE}▶ 步骤 2/5：正在检测 FX Steam Launcher 安装状态...${RESET}"
if [[ ! -d "$APP_PATH" ]]; then
    echo -e "${RED}✘ 未在“/Applications”目录中找到“FX Steam Launcher.app”。${RESET}"
    echo -e "${YELLOW}提示：请先前往官方仓库下载安装官方版 FX Steam Launcher 后再运行此汉化脚本：${RESET}"
    echo -e "      👉 官方发布页: https://github.com/fxgl/steamac/releases"
    exit 1
fi
echo -e "${GREEN}✔ 已找到应用程序：${APP_PATH}${RESET}"

# 3. 检查是否有运行中的实例
echo -e "${BLUE}▶ 步骤 3/5：检查应用运行状态...${RESET}"
if pgrep -f "steamac-vm" >/dev/null 2>&1 || pgrep -f "FX Steam Launcher" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ 检测到 FX Steam Launcher 正在运行，正在尝试安全退出...${RESET}"
    osascript -e 'quit app "FX Steam Launcher"' >/dev/null 2>&1 || true
    sleep 2
    if pgrep -f "steamac-vm" >/dev/null 2>&1; then
        echo -e "${YELLOW}请先手动退出 FX Steam Launcher 应用程序后再继续安装。${RESET}"
        exit 1
    fi
fi
echo -e "${GREEN}✔ 进程状态正常${RESET}"

# 4. 自动备份原版英文二进制
echo -e "${BLUE}▶ 步骤 4/5：备份官方原版核心文件...${RESET}"
if [[ ! -f "$TARGET_BIN" ]]; then
    echo -e "${RED}✘ 未在目标目录中找到可执行文件: ${TARGET_BIN}${RESET}"
    exit 1
fi

if [[ ! -f "$BACKUP_BIN" ]]; then
    echo -e "正在备份原版二进制为: ${CYAN}steamac-vm.orig${RESET}"
    cp -p "$TARGET_BIN" "$BACKUP_BIN"
    echo -e "${GREEN}✔ 官方原版备份成功！随时可通过卸载脚本无损恢复。${RESET}"
else
    echo -e "${GREEN}✔ 已存在原版备份文件 (steamac-vm.orig)，跳过备份步骤以防止二次覆盖。${RESET}"
fi

# 5. 获取并安装汉化补丁二进制
echo -e "${BLUE}▶ 步骤 5/5：正在安装简体中文汉化文件...${RESET}"

# 获取脚本自身所在绝对路径
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

TEMP_DIR=""
SOURCE_BIN=""
ENTITLEMENTS_FILE=""

# 优先检查本地是否存在 bin/steamac-vm
if [[ -n "$SCRIPT_DIR" ]] && [[ -f "${SCRIPT_DIR}/bin/steamac-vm" ]]; then
    echo -e "检测到本地文件，正在应用本地汉化资源..."
    SOURCE_BIN="${SCRIPT_DIR}/bin/steamac-vm"
    ENTITLEMENTS_FILE="${SCRIPT_DIR}/entitlements.plist"
else
    echo -e "正在从云端下载预编译的已签名中文二进制..."
    TEMP_DIR="$(mktemp -d /tmp/steamac-zh-install.XXXXXX)"
    SOURCE_BIN="${TEMP_DIR}/steamac-vm"
    ENTITLEMENTS_FILE="${TEMP_DIR}/entitlements.plist"

    curl -fL --progress-bar "${REMOTE_RAW_URL}/bin/steamac-vm" -o "$SOURCE_BIN" || {
        echo -e "${RED}✘ 下载汉化二进制失败，请检查网络连接或仓库地址设置。${RESET}"
        rm -rf "$TEMP_DIR"
        exit 1
    }

    curl -fsSL "${REMOTE_RAW_URL}/entitlements.plist" -o "$ENTITLEMENTS_FILE" || true
fi

# 替换二进制文件
cp -f "$SOURCE_BIN" "$TARGET_BIN"
chmod +x "$TARGET_BIN"

# 清理隔离属性
echo -e "正在清除 macOS 隔离属性 (quarantine)..."
xattr -cr "$APP_PATH" 2>/dev/null || true

# 重新注入 hypervisor 等安全权限签名
echo -e "正在进行本地 Ad-hoc 代码签名..."
if [[ -f "$ENTITLEMENTS_FILE" ]]; then
    codesign --force --sign - --entitlements "$ENTITLEMENTS_FILE" "$TARGET_BIN" >/dev/null 2>&1 || true
else
    # 提取内置 entitlements
    codesign -d --entitlements :- "$BACKUP_BIN" > "/tmp/temp_entitlements.plist" 2>/dev/null || true
    if [[ -s "/tmp/temp_entitlements.plist" ]]; then
        codesign --force --sign - --entitlements "/tmp/temp_entitlements.plist" "$TARGET_BIN" >/dev/null 2>&1 || true
        rm -f "/tmp/temp_entitlements.plist"
    else
        codesign --force --sign - "$TARGET_BIN" >/dev/null 2>&1 || true
    fi
fi

# 清理临时文件
if [[ -n "$TEMP_DIR" ]] && [[ -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
fi

echo -e "\n${GREEN}${BOLD}🎉 恭喜！FX Steam Launcher 简体中文汉化补丁安装成功！${RESET}\n"
echo -e "使用说明："
echo -e "  1. 打开 ${BOLD}访达 › 应用程序 › FX Steam Launcher${RESET}"
echo -e "  2. 在启动器运行时按下快捷键 ${CYAN}${BOLD}⌘ , (Command + 逗号)${RESET} 即可进入全中文设置面板"
echo -e "  3. 顶部菜单栏、各项提示向导及手柄/显示控制已全部汉化"
echo -e "  4. 若需还原原版英文，只需在终端运行本项目提供的 ${YELLOW}uninstall.sh${RESET} 即可一键恢复\n"
