#!/bin/bash

set -e

VERSION="1.5.0"
INSTALL_PATH="/usr/local/bin/gpu-manager"
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

# 下载 gpu-manager.sh（自动尝试多个源）
echo "Downloading gpu-manager.sh..."
DOWNLOAD_OK=0

for URL in "${REPO_URLS[@]}"; do
    echo "  Trying: $URL ..."
    if curl -fsSL --connect-timeout 10 --max-time 30 "$URL/gpu-manager.sh" -o /tmp/gpu-manager.sh 2>/dev/null; then
        if [ -s /tmp/gpu-manager.sh ]; then
            echo "  Download OK from: $URL"
            DOWNLOAD_OK=1
            break
        fi
    fi
    echo "  Failed, trying next source..."
done

if [ $DOWNLOAD_OK -ne 1 ] || [ ! -s /tmp/gpu-manager.sh ]; then
    echo ""
    echo "Error: Failed to download gpu-manager.sh from all sources"
    echo "Please check your network connection."
    exit 1
fi

# 安装
echo "Installing gpu-manager to $INSTALL_PATH..."
mv /tmp/gpu-manager.sh "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

echo ""
echo "Install completed!"
echo ""
echo "Usage:"
echo "  gpu-manager              进入交互式菜单"
echo "  gpu-manager --help       查看帮助"
echo "  gpu-manager --version    查看版本"
echo "  gpu-manager --tpm-status 查看 TPM 状态"
echo "  gpu-manager --update     自更新"
echo ""
