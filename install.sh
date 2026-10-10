#!/usr/bin/env bash
# ==============================================================================
# FX Steam Launcher 中文汉化补丁 一键安装脚本
# 支持：简体中文 (Simplified Chinese) & 繁體中文 (Traditional Chinese)
# 完美适配：FX Steam Launcher 1.9+ 官方原生多语言架构及历史版本
# 支持：本地运行与 curl 远程一键安装
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

# GitHub 仓库配置（远程一键安装时使用）
GITHUB_REPO="${FX_ZH_REPO:-https://github.com/Usagi53Q/fx-steam-launcher-zh}"
REMOTE_RAW_URL="${FX_ZH_RAW_URL:-https://raw.githubusercontent.com/Usagi53Q/fx-steam-launcher-zh/main}"

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║             FX Steam Launcher 中文汉化补丁安装程序               ║"
echo "║      支持：简体中文 (zh-Hans)  /  繁體中文 (zh-Hant)             ║"
echo "║       Apple Silicon (M1/M2/M3/M4) 原生 SteamOS 虚拟机启动器      ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# 解析命令行参数或环境变量
SELECTED_LANG=""
for arg in "$@"; do
    case "$arg" in
        --zh-hant|--tc|--hant|-t)
            SELECTED_LANG="zh-Hant"
            ;;
        --zh-hans|--sc|--hans|-s)
            SELECTED_LANG="zh-Hans"
            ;;
    esac
done

if [[ -z "$SELECTED_LANG" && -n "$FX_LANG" ]]; then
    case "$FX_LANG" in
        *hant*|*tc*|*traditional*|*繁*)
            SELECTED_LANG="zh-Hant"
            ;;
        *hans*|*sc*|*simplified*|*简*)
            SELECTED_LANG="zh-Hans"
            ;;
    esac
fi

# 交互式语言选择（如未指定参数）
if [[ -z "$SELECTED_LANG" ]]; then
    if [[ -r /dev/tty ]]; then
        echo -e "${YELLOW}请选择要安装的中文语言版本 / 請選擇語言版本：${RESET}"
        echo -e "  ${BOLD}1)${RESET} 简体中文 (Simplified Chinese) [默认/預設]"
        echo -e "  ${BOLD}2)${RESET} 繁體中文 (Traditional Chinese)"
        echo ""
        read -r -p "请输入选项 [1/2，回车默认 1]: " USER_CHOICE < /dev/tty || USER_CHOICE="1"
        case "$USER_CHOICE" in
            2|hant|tc)
                SELECTED_LANG="zh-Hant"
                ;;
            *)
                SELECTED_LANG="zh-Hans"
                ;;
        esac
    else
        SELECTED_LANG="zh-Hans"
    fi
fi

if [[ "$SELECTED_LANG" == "zh-Hant" ]]; then
    LANG_NAME="繁體中文 (Traditional Chinese)"
else
    LANG_NAME="简体中文 (Simplified Chinese)"
fi
echo -e "${GREEN}✔ 已选择安装版本：${BOLD}${LANG_NAME}${RESET}\n"

# 1. 检查操作系统与芯片架构
echo -e "${BLUE}▶ 步骤 1/4：正在检测运行环境...${RESET}"
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
echo -e "${BLUE}▶ 步骤 2/4：正在检测 FX Steam Launcher 安装状态...${RESET}"
if [[ ! -d "$APP_PATH" ]]; then
    echo -e "${RED}✘ 未在“/Applications”目录中找到“FX Steam Launcher.app”。${RESET}"
    echo -e "${YELLOW}提示：请先前往官方发布页下载安装官方应用后再运行此脚本：${RESET}"
    echo -e "      👉 官方发布页: https://github.com/fxgl/steamac/releases"
    exit 1
fi
echo -e "${GREEN}✔ 已找到应用程序：${APP_PATH}${RESET}"

# 3. 检查是否有运行中的实例
echo -e "${BLUE}▶ 步骤 3/4：检查应用运行状态...${RESET}"
if pgrep -x "steamac-vm" >/dev/null 2>&1 || [[ "$(osascript -e 'application "FX Steam Launcher" is running' 2>/dev/null)" == "true" ]]; then
    echo -e "${YELLOW}⚠ 检测到 FX Steam Launcher 正在运行，正在尝试安全退出...${RESET}"
    osascript -e 'quit app "FX Steam Launcher"' >/dev/null 2>&1 || true
    sleep 2
    if pgrep -x "steamac-vm" >/dev/null 2>&1; then
        echo -e "${YELLOW}请先退出 FX Steam Launcher 应用程序后再继续安装。${RESET}"
        exit 1
    fi
fi
echo -e "${GREEN}✔ 进程状态正常${RESET}"

# 4. 正在应用汉化配置
echo -e "${BLUE}▶ 步骤 4/4：正在配置 ${LANG_NAME} 语言支持...${RESET}"

# 获取脚本自身所在绝对路径
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# 检测是否为官方 1.9+ 原生多语言版本（拥有 Contents/Resources/zh-Hans.lproj）
IS_NATIVE_1_9="false"
if [[ -d "${RESOURCES_DIR}/zh-Hans.lproj" ]]; then
    IS_NATIVE_1_9="true"
fi

if [[ "$IS_NATIVE_1_9" == "true" ]]; then
    echo -e "检测到应用为 ${CYAN}1.9+ 原生多语言版本${RESET}，正在应用原生本地化..."

    if [[ "$SELECTED_LANG" == "zh-Hans" ]]; then
        # 简体中文：直接绑定应用首选语言，100% 原生认证
        defaults write "${BUNDLE_ID}" AppleLanguages "(\"zh-Hans\")"
        echo -e "${GREEN}✔ 已将应用默认语言设置为：简体中文${RESET}"
    else
        # 繁體中文：部署 zh-Hant.lproj 资源包并绑定应用语言
        TARGET_HANT_DIR="${RESOURCES_DIR}/zh-Hant.lproj"
        mkdir -p "$TARGET_HANT_DIR"

        if [[ -n "$SCRIPT_DIR" ]] && [[ -d "${SCRIPT_DIR}/resources/zh-Hant.lproj" ]]; then
            echo -e "正在部署本地繁體中文本地化資源包..."
            cp -rf "${SCRIPT_DIR}/resources/zh-Hant.lproj/"* "$TARGET_HANT_DIR/"
        else
            echo -e "正在從雲端下載最新繁體中文本地化資源包..."
            curl -fsSL "${REMOTE_RAW_URL}/resources/zh-Hant.lproj/Localizable.strings" -o "${TARGET_HANT_DIR}/Localizable.strings"
            curl -fsSL "${REMOTE_RAW_URL}/resources/zh-Hant.lproj/InfoPlist.strings" -o "${TARGET_HANT_DIR}/InfoPlist.strings"
        fi

        defaults write "${BUNDLE_ID}" AppleLanguages "(\"zh-Hant\")"
        echo -e "${GREEN}✔ 繁體中文本地化資源包部署成功，已設置為應用預設語言${RESET}"
    fi

    # 清除 Gatekeeper 隔离标记
    xattr -cr "$APP_PATH" 2>/dev/null || true

else
    # 针对 1.8 及更旧版本：使用二进制补丁替换
    echo -e "检测到应用为 ${YELLOW}1.8 或更早版本${RESET}，正在应用独立二进制补丁..."

    if [[ ! -f "$BACKUP_BIN" ]]; then
        echo -e "正在备份原版二进制为: ${CYAN}steamac-vm.orig${RESET}"
        cp -p "$TARGET_BIN" "$BACKUP_BIN"
    fi

    TEMP_DIR=""
    SOURCE_BIN=""
    ENTITLEMENTS_FILE=""

    if [[ -n "$SCRIPT_DIR" ]] && [[ -f "${SCRIPT_DIR}/bin/${SELECTED_LANG}/steamac-vm" ]]; then
        SOURCE_BIN="${SCRIPT_DIR}/bin/${SELECTED_LANG}/steamac-vm"
        ENTITLEMENTS_FILE="${SCRIPT_DIR}/entitlements.plist"
    else
        TEMP_DIR="$(mktemp -d /tmp/steamac-zh-install.XXXXXX)"
        SOURCE_BIN="${TEMP_DIR}/steamac-vm"
        ENTITLEMENTS_FILE="${TEMP_DIR}/entitlements.plist"
        DOWNLOAD_URL="${REMOTE_RAW_URL}/bin/${SELECTED_LANG}/steamac-vm"
        curl -fL --progress-bar "$DOWNLOAD_URL" -o "$SOURCE_BIN" || curl -fL --progress-bar "${REMOTE_RAW_URL}/bin/steamac-vm" -o "$SOURCE_BIN"
        curl -fsSL "${REMOTE_RAW_URL}/entitlements.plist" -o "$ENTITLEMENTS_FILE" || true
    fi

    cp -f "$SOURCE_BIN" "$TARGET_BIN"
    chmod +x "$TARGET_BIN"
    xattr -cr "$APP_PATH" 2>/dev/null || true

    if [[ -f "$ENTITLEMENTS_FILE" ]]; then
        codesign --force --sign - --entitlements "$ENTITLEMENTS_FILE" "$TARGET_BIN" >/dev/null 2>&1 || true
    else
        codesign --force --sign - "$TARGET_BIN" >/dev/null 2>&1 || true
    fi

    if [[ -n "$TEMP_DIR" ]] && [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
fi

echo -e "\n${GREEN}${BOLD}🎉 恭喜！FX Steam Launcher ${LANG_NAME} 汉化已成功启用！${RESET}\n"
echo -e "使用说明："
echo -e "  1. 打开 ${BOLD}访达 › 应用程序 › FX Steam Launcher${RESET}"
echo -e "  2. 启动器运行后按下快捷键 ${CYAN}${BOLD}⌘ , (Command + 逗号)${RESET} 即可进入全中文偏好设置面板"
echo -e "  3. 顶部菜单栏、各项提示向导及手柄/显示控制现已完整呈现为中文"
echo -e "  4. 若需恢复为系统默认语言，只需在终端运行本项目提供的 ${YELLOW}uninstall.sh${RESET} 即可一键恢复\n"
