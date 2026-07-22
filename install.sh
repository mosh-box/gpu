#!/bin/bash

set -e

VERSION="1.9.0"
INSTALL_PATH="/usr/local/bin/gpu-manager"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_URLS=(
    "https://raw.githubusercontent.com/mosh-box/gpu/main"
    "https://ghfast.top/https://raw.githubusercontent.com/mosh-box/gpu/main"
    "https://gh-proxy.com/https://raw.githubusercontent.com/mosh-box/gpu/main"
)

echo ""
echo "=================================================="
echo "  GPU Manager Installer v$VERSION"
echo "=================================================="
echo ""

# 检查是否 root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (sudo bash install.sh)"
    exit 1
fi

# 卸载支持
if [ "$1" = "--uninstall" ]; then
    echo "Uninstalling gpu-manager..."
    rm -f "$INSTALL_PATH"
    echo "Uninstall completed."
    exit 0
fi

# 优先安装同目录代码，便于从仓库直接安装尚未发布的版本；
# 单独下载 install.sh 使用时，再回退到远端源。
SOURCE_FILE="$SCRIPT_DIR/gpu-manager.sh"
if [ -s "$SOURCE_FILE" ]; then
    LOCAL_VERSION=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$SOURCE_FILE" | head -1)
    if [ "$LOCAL_VERSION" != "$VERSION" ]; then
        echo "Error: Local gpu-manager.sh version ($LOCAL_VERSION) does not match installer ($VERSION)"
        exit 1
    fi
    echo "Using local gpu-manager.sh v$LOCAL_VERSION"
else
    echo "Downloading gpu-manager.sh..."
    DOWNLOAD_OK=0
    SOURCE_FILE="/tmp/gpu-manager.sh"

    for URL in "${REPO_URLS[@]}"; do
        echo "  Trying: $URL ..."
        if curl -fsSL --connect-timeout 10 --max-time 30 "$URL/gpu-manager.sh" -o "$SOURCE_FILE" 2>/dev/null; then
            if [ -s "$SOURCE_FILE" ]; then
                echo "  Download OK from: $URL"
                DOWNLOAD_OK=1
                break
            fi
        fi
        echo "  Failed, trying next source..."
    done

    if [ $DOWNLOAD_OK -ne 1 ] || [ ! -s "$SOURCE_FILE" ]; then
        echo ""
        echo "Error: Failed to download gpu-manager.sh from all sources"
        echo "Please check your network connection."
        exit 1
    fi
fi

# 安装
echo "Installing gpu-manager to $INSTALL_PATH..."
install -m 0755 "$SOURCE_FILE" "$INSTALL_PATH"
[ "$SOURCE_FILE" = "/tmp/gpu-manager.sh" ] && rm -f "$SOURCE_FILE"

echo ""
echo "Install completed!"
echo ""
echo "Usage:"
echo "  gpu-manager              进入交互式菜单"
echo "  gpu-manager --help       查看帮助"
echo "  gpu-manager --version    查看版本"
echo ""
