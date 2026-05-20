#!/bin/bash

# ============================================================
# GPU Manager v1.5.0
# ============================================================

VERSION="1.5.1"
LOG_FILE="/var/log/gpu-manager.log"
APT_TIMEOUT=120
DRIVER_TIMEOUT=600
NETWORK_TIMEOUT=10

# ============================================================
# 工具函数
# ============================================================

info() {
    echo -e "\e[33m$1\e[0m"
    log "INFO" "$1"
}

success() {
    echo -e "\e[32m$1\e[0m"
    log "SUCCESS" "$1"
}

error() {
    echo -e "\e[31m$1\e[0m"
    log "ERROR" "$1"
}

warn() {
    echo -e "\e[35m$1\e[0m"
    log "WARN" "$1"
}

log() {
    local LEVEL="$1"
    local MSG="$2"
    if [ -w "$LOG_FILE" ] || touch "$LOG_FILE" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LEVEL] $MSG" >> "$LOG_FILE" 2>/dev/null
    fi
}

pause() {
    echo ""
    read -p "按 Enter 键继续..."
}

confirm_action() {
    echo ""
    read -p "$1 (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        warn "用户已取消操作"
        return 1
    fi
    return 0
}

# 询问是否重启
ask_reboot() {
    echo ""
    warn "驱动安装完成后需要重启才能生效！"
    read -p "是否立即重启？(yes/no): " reboot_confirm
    if [ "$reboot_confirm" = "yes" ]; then
        info "正在重启..."
        sudo reboot
    else
        warn "请稍后手动执行: sudo reboot"
    fi
}

# ============================================================
# 带智能状态监控的后台执行
# ============================================================

# 带超时 + 倒计时的命令执行（输出隐藏，适合 apt 等短任务）
run_with_timeout() {
    local TIMEOUT=$1
    local MSG="$2"
    shift 2

    "$@" > /tmp/gpu-manager-cmd-output.log 2>&1 &
    local CMD_PID=$!

    local ELAPSED=0
    while kill -0 "$CMD_PID" 2>/dev/null; do
        if [ $ELAPSED -ge $TIMEOUT ]; then
            kill $CMD_PID 2>/dev/null
            wait $CMD_PID 2>/dev/null
            printf "\r\e[K"
            error "操作超时（超过 ${TIMEOUT}s），已终止"
            error "详细日志: /tmp/gpu-manager-cmd-output.log"
            return 124
        fi
        local MINS=$((ELAPSED / 60))
        local SECS=$((ELAPSED % 60))
        printf "\r\e[33m  ⏳ %s [已用 %dm%02ds]\e[0m" "$MSG" "$MINS" "$SECS"
        sleep 1
        ELAPSED=$((ELAPSED + 1))
    done

    wait $CMD_PID
    local EXIT_CODE=$?
    printf "\r\e[K"

    return $EXIT_CODE
}

# 带进度条的 apt 操作
apt_with_progress() {
    local MSG="$1"
    shift
    run_with_timeout $APT_TIMEOUT "$MSG" sudo apt-get "$@"
    return $?
}

# MOK 密钥管理（Secure Boot 签名用）
MOK_KEY_DIR="/var/lib/gpu-manager/mok"
MOK_PRIV="$MOK_KEY_DIR/mok.priv"
MOK_DER="$MOK_KEY_DIR/mok.der"

# 检查 Secure Boot 状态
check_secure_boot() {
    local SB_STATUS=""
    if command -v mokutil &>/dev/null; then
        SB_STATUS=$(mokutil --sb-state 2>/dev/null | head -1)
    elif [ -d /sys/firmware/efi ]; then
        local SB_VAL=$(cat /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | tail -c1 | xxd -p 2>/dev/null)
        if [ "$SB_VAL" = "01" ]; then
            SB_STATUS="SecureBoot enabled"
        fi
    fi

    if echo "$SB_STATUS" | grep -qi "enabled"; then
        return 0  # Secure Boot 开启
    else
        return 1  # Secure Boot 关闭
    fi
}

# 生成 MOK 密钥并注册
setup_mok_key() {
    info "Secure Boot 已开启，需要配置 MOK 密钥签名驱动模块..."
    echo ""

    # 安装 mokutil 如果没有
    if ! command -v mokutil &>/dev/null; then
        apt_with_progress "安装 mokutil" install -y mokutil
    fi

    # 检查是否已有 MOK 密钥
    if [ -f "$MOK_PRIV" ] && [ -f "$MOK_DER" ]; then
        # 检查密钥是否已注册到 UEFI
        if mokutil --test-key "$MOK_DER" 2>/dev/null | grep -qi "already enrolled"; then
            success "MOK 密钥已存在且已注册，无需重复操作"
            return 0
        else
            info "MOK 密钥文件存在但未注册到 UEFI，将重新注册"
        fi
    else
        # 生成新密钥
        info "生成 MOK 签名密钥..."
        mkdir -p "$MOK_KEY_DIR"
        openssl req -new -x509 -newkey rsa:2048 -keyout "$MOK_PRIV" -outform DER \
            -out "$MOK_DER" -nodes -days 36500 \
            -subj "/CN=GPU Manager MOK Signing Key/" 2>/dev/null

        if [ $? -ne 0 ]; then
            error "MOK 密钥生成失败"
            return 1
        fi
        success "MOK 密钥已生成: $MOK_DER"
    fi

    echo ""
    warn "╔══════════════════════════════════════════════════════════╗"
    warn "║  接下来需要设置一个 MOK 注册密码（重启时要用到）         ║"
    warn "║  密码仅用于重启时确认注册，之后不再需要                  ║"
    warn "╚══════════════════════════════════════════════════════════╝"
    echo ""

    mokutil --import "$MOK_DER"

    if [ $? -ne 0 ]; then
        error "MOK 密钥注册失败"
        return 1
    fi

    echo ""
    success "MOK 密钥已提交注册请求"
    warn "重要提示："
    warn "  驱动安装完成后重启时，系统会进入蓝色 MOK Manager 界面："
    warn "  1) 选择 'Enroll MOK'"
    warn "  2) 选择 'Continue'"
    warn "  3) 选择 'Yes'"
    warn "  4) 输入刚才设置的密码"
    warn "  5) 选择 'Reboot'"
    warn ""
    warn "  完成后 Secure Boot + NVIDIA 驱动即可共存！"
    echo ""

    return 0
}

# 签名所有 NVIDIA DKMS 模块
sign_nvidia_modules() {
    if [ ! -f "$MOK_PRIV" ] || [ ! -f "$MOK_DER" ]; then
        return 0  # 无 MOK 密钥则跳过
    fi

    info "使用 MOK 密钥签名 NVIDIA 内核模块..."

    local KVER=$(uname -r)
    local SIGN_FILE="/usr/src/linux-headers-${KVER}/scripts/sign-file"

    # 备用路径
    if [ ! -f "$SIGN_FILE" ]; then
        SIGN_FILE=$(find /usr/src/ -name "sign-file" -type f 2>/dev/null | head -1)
    fi

    if [ -z "$SIGN_FILE" ] || [ ! -f "$SIGN_FILE" ]; then
        warn "未找到 sign-file 工具，尝试使用 kmodsign..."
        SIGN_FILE="kmodsign"
        if ! command -v kmodsign &>/dev/null; then
            error "无法签名模块：sign-file 和 kmodsign 均不可用"
            warn "请确保已安装 linux-headers-$(uname -r)"
            return 1
        fi
    fi

    local SIGNED_COUNT=0
    local NVIDIA_MODULES=$(find /lib/modules/$KVER -name "nvidia*.ko" -o -name "nvidia*.ko.zst" -o -name "nvidia*.ko.xz" 2>/dev/null)

    if [ -z "$NVIDIA_MODULES" ]; then
        warn "未找到 NVIDIA 内核模块文件"
        return 1
    fi

    while read -r MOD; do
        if [ -n "$MOD" ]; then
            local ACTUAL_MOD="$MOD"
            local COMPRESSED=0

            # 处理压缩模块：解压 → 签名 → 重新压缩
            if [[ "$MOD" == *.ko.zst ]]; then
                zstd -d -f "$MOD" -o "${MOD%.zst}" 2>/dev/null
                ACTUAL_MOD="${MOD%.zst}"
                COMPRESSED=1
            elif [[ "$MOD" == *.ko.xz ]]; then
                xz -d -f -k "$MOD" 2>/dev/null
                ACTUAL_MOD="${MOD%.xz}"
                COMPRESSED=2
            fi

            "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$ACTUAL_MOD" 2>/dev/null
            if [ $? -eq 0 ]; then
                SIGNED_COUNT=$((SIGNED_COUNT + 1))
                # 重新压缩
                if [ $COMPRESSED -eq 1 ]; then
                    zstd -f "$ACTUAL_MOD" -o "$MOD" 2>/dev/null
                    rm -f "$ACTUAL_MOD"
                elif [ $COMPRESSED -eq 2 ]; then
                    xz -f "$ACTUAL_MOD" 2>/dev/null
                fi
            fi
        fi
    done <<< "$NVIDIA_MODULES"

    if [ $SIGNED_COUNT -gt 0 ]; then
        success "已签名 $SIGNED_COUNT 个 NVIDIA 模块"
    else
        error "模块签名失败"
        return 1
    fi

    return 0
}

# 配置 DKMS 自动签名（后续内核更新时自动签）
setup_dkms_auto_sign() {
    if [ ! -f "$MOK_PRIV" ] || [ ! -f "$MOK_DER" ]; then
        return 0
    fi

    local SIGN_HOOK="/etc/dkms/sign_helper.sh"
    local DKMS_CONF="/etc/dkms/framework.conf"

    # 创建签名辅助脚本
    mkdir -p /etc/dkms
    cat > "$SIGN_HOOK" << 'SIGNEOF'
#!/bin/bash
# Auto-sign DKMS modules for Secure Boot
/usr/src/linux-headers-$(uname -r)/scripts/sign-file sha256 \
    /var/lib/gpu-manager/mok/mok.priv \
    /var/lib/gpu-manager/mok/mok.der "$1"
SIGNEOF
    chmod +x "$SIGN_HOOK"

    # 配置 DKMS framework.conf
    # sign_tool: DKMS 原生自动签名
    # mok_signing_key / mok_certificate: ubuntu-drivers 使用的签名路径
    #   配置后 ubuntu-drivers autoinstall 不会再触发额外的 mokutil --import
    if [ -f "$DKMS_CONF" ]; then
        if ! grep -q "sign_tool" "$DKMS_CONF"; then
            echo "" >> "$DKMS_CONF"
            echo "# GPU Manager: auto-sign for Secure Boot" >> "$DKMS_CONF"
            echo "sign_tool=\"$SIGN_HOOK\"" >> "$DKMS_CONF"
        fi
        if ! grep -q "mok_signing_key" "$DKMS_CONF"; then
            echo "mok_signing_key=$MOK_PRIV" >> "$DKMS_CONF"
            echo "mok_certificate=$MOK_DER" >> "$DKMS_CONF"
        fi
    else
        cat > "$DKMS_CONF" << CONFEOF
# GPU Manager: auto-sign for Secure Boot
sign_tool="$SIGN_HOOK"
mok_signing_key=$MOK_PRIV
mok_certificate=$MOK_DER
CONFEOF
    fi

    success "已配置 DKMS 自动签名（内核更新时自动生效）"
}

# NVIDIA 驱动安装专用：后台运行 + 实时分析日志输出当前阶段和速率
install_nvidia_driver() {
    local LOG_TMP="/tmp/gpu-manager-driver-install.log"
    local NEED_MOK=0

    # ===== UEFI + MOK 预检 =====
    # Ubuntu 24.04+ 的 ubuntu-drivers 已内置 DKMS 自动签名，无需手动处理
    # 仅 22.04 及更早版本需要手动 MOK 签名
    local UBUNTU_VER=""
    if [ -f /etc/os-release ]; then
        UBUNTU_VER=$(. /etc/os-release && echo "${VERSION_ID}")
    fi

    if [ -d /sys/firmware/efi ] && [ "$(echo "$UBUNTU_VER < 24.04" | bc 2>/dev/null)" = "1" ]; then
        # Ubuntu 22.04 及更早版本：手动 MOK 签名
        if check_secure_boot; then
            echo ""
            info "╔══════════════════════════════════════════════════════╗"
            info "║  检测到 Secure Boot 已开启                           ║"
            info "╚══════════════════════════════════════════════════════╝"
            echo ""
            info "将使用 MOK 签名方案，确保驱动与 Secure Boot 兼容"
        else
            echo ""
            info "UEFI 系统，Secure Boot 当前未开启"
            info "将自动签名驱动模块，以便后续开启 Secure Boot 时也能正常启动"
        fi
        echo ""

        setup_mok_key
        if [ $? -ne 0 ]; then
            warn "MOK 配置未完成，驱动仍会安装但不会签名"
            warn "如后续开启 Secure Boot 可能导致无法启动"
            echo ""
            confirm_action "是否继续安装（不签名）"
            if [ $? -ne 0 ]; then
                return 1
            fi
        else
            NEED_MOK=1
            # 提前配置 DKMS 自动签名，这样 ubuntu-drivers autoinstall
            # 在 DKMS 编译模块时就会直接用 MOK 密钥签名，
            # 避免 ubuntu-drivers 自己触发 mokutil --import 再次要求输入密码
            setup_dkms_auto_sign
        fi
    elif [ -d /sys/firmware/efi ]; then
        # Ubuntu 24.04+：ubuntu-drivers 内置 DKMS 签名流程
        # 但仍需确保有 MOK 密钥，ubuntu-drivers 会自动使用它
        if check_secure_boot; then
            info "Ubuntu $UBUNTU_VER + Secure Boot: 使用系统内置 DKMS 签名"
            info "ubuntu-drivers 会自动处理 MOK 注册流程"
        else
            info "Ubuntu $UBUNTU_VER UEFI 系统，Secure Boot 未开启"
        fi
        echo ""
    fi

    # 检查 dpkg 锁（避免安装过程卡住）
    if fuser /var/lib/dpkg/lock-frontend &>/dev/null || fuser /var/lib/apt/lists/lock &>/dev/null; then
        warn "检测到 apt/dpkg 被其他进程占用"
        warn "正在等待锁释放（最多 60s）..."
        local LOCK_WAIT=0
        while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && [ $LOCK_WAIT -lt 60 ]; do
            sleep 2
            LOCK_WAIT=$((LOCK_WAIT + 2))
        done
        if [ $LOCK_WAIT -ge 60 ]; then
            error "dpkg 锁超时，请手动关闭其他 apt 进程后重试"
            error "  sudo killall apt apt-get 2>/dev/null; sudo dpkg --configure -a"
            return 1
        fi
        success "dpkg 锁已释放"
    fi

    # 修复可能的 dpkg 中断状态
    if dpkg --audit 2>&1 | grep -q "."; then
        info "检测到 dpkg 未完成配置，正在修复..."
        dpkg --configure -a 2>/dev/null
    fi

    # 确保 ubuntu-drivers 可用
    if ! command -v ubuntu-drivers &>/dev/null; then
        info "安装 ubuntu-drivers-common..."
        apt-get install -y ubuntu-drivers-common > /dev/null 2>&1
        if ! command -v ubuntu-drivers &>/dev/null; then
            error "ubuntu-drivers-common 安装失败，无法继续"
            return 1
        fi
    fi

    # 检查推荐驱动版本
    local RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | grep "recommended" | awk '{print $3}')
    if [ -n "$RECOMMENDED" ]; then
        info "系统推荐驱动: $RECOMMENDED"
    else
        warn "未检测到推荐驱动版本，将使用 autoinstall 自动选择"
    fi

    # 确保内核头文件存在（DKMS 编译必需）
    local KVER=$(uname -r)
    if [ ! -d "/usr/src/linux-headers-$KVER" ]; then
        info "安装内核头文件 linux-headers-$KVER（DKMS 编译必需）..."
        apt-get install -y "linux-headers-$KVER" > /dev/null 2>&1
        if [ ! -d "/usr/src/linux-headers-$KVER" ]; then
            warn "内核头文件安装失败，DKMS 编译可能失败"
        else
            success "内核头文件已就位"
        fi
    fi
    echo ""

    info "正在安装 NVIDIA 驱动 (ubuntu-drivers autoinstall)..."
    echo ""
    warn "  此过程通常需要 5-15 分钟，包含以下阶段："
    warn "  1) 下载驱动包及依赖（取决于网速）"
    warn "  2) DKMS 编译驱动模块（CPU 密集，最耗时）"
    warn "  3) 更新 initramfs"
    if [ $NEED_MOK -eq 1 ]; then
        warn "  4) MOK 签名驱动模块"
    fi
    echo ""

    # 后台执行
    sudo ubuntu-drivers autoinstall > "$LOG_TMP" 2>&1 &
    local CMD_PID=$!

    local ELAPSED=0
    local LAST_PHASE=""
    local LAST_LINE_COUNT=0

    while kill -0 "$CMD_PID" 2>/dev/null; do
        if [ $ELAPSED -ge $DRIVER_TIMEOUT ]; then
            kill $CMD_PID 2>/dev/null
            wait $CMD_PID 2>/dev/null
            printf "\r\e[K"
            echo ""
            error "驱动安装超时（超过 ${DRIVER_TIMEOUT}s），已终止"
            error "详细日志: $LOG_TMP"
            echo ""
            error "可能原因："
            error "  - 网络下载过慢（检查网络或换源）"
            error "  - DKMS 编译卡死（CPU 资源不足）"
            error "  - dpkg 锁被其他进程占用"
            return 124
        fi

        # 分析日志判断当前阶段
        local CURRENT_PHASE=""
        local EXTRA_INFO=""

        if [ -f "$LOG_TMP" ]; then
            local LAST_LINES=$(tail -5 "$LOG_TMP" 2>/dev/null)

            if echo "$LAST_LINES" | grep -qi "get:\|fetch\|download\|Fetched"; then
                CURRENT_PHASE="下载中"
                # 尝试提取下载速率
                local SPEED=$(echo "$LAST_LINES" | grep -oP '\d+[\.\d]* [kMG]B/s' | tail -1)
                local FETCHED=$(grep -oP 'Fetched \K[^)]+' "$LOG_TMP" 2>/dev/null | tail -1)
                if [ -n "$SPEED" ]; then
                    EXTRA_INFO="速率: $SPEED"
                elif [ -n "$FETCHED" ]; then
                    EXTRA_INFO="已下载: $FETCHED"
                fi
            elif echo "$LAST_LINES" | grep -qi "dkms\|building\|compile\|module"; then
                CURRENT_PHASE="DKMS 编译内核模块"
                EXTRA_INFO="CPU 密集操作，请耐心等待"
            elif echo "$LAST_LINES" | grep -qi "initramfs\|update-initramfs"; then
                CURRENT_PHASE="更新 initramfs"
                EXTRA_INFO="即将完成"
            elif echo "$LAST_LINES" | grep -qi "unpacking\|Preparing\|Selecting"; then
                CURRENT_PHASE="解包安装"
            elif echo "$LAST_LINES" | grep -qi "Setting up\|Processing"; then
                CURRENT_PHASE="配置中"
            elif echo "$LAST_LINES" | grep -qi "Waiting\|lock"; then
                CURRENT_PHASE="等待 dpkg 锁释放"
                EXTRA_INFO="其他 apt 进程可能在运行"
            else
                CURRENT_PHASE="处理中"
            fi
        else
            CURRENT_PHASE="启动中"
        fi

        # 显示状态
        local MINS=$((ELAPSED / 60))
        local SECS=$((ELAPSED % 60))
        if [ -n "$EXTRA_INFO" ]; then
            printf "\r\e[K\e[33m  ⏳ [%dm%02ds] %s | %s\e[0m" "$MINS" "$SECS" "$CURRENT_PHASE" "$EXTRA_INFO"
        else
            printf "\r\e[K\e[33m  ⏳ [%dm%02ds] %s\e[0m" "$MINS" "$SECS" "$CURRENT_PHASE"
        fi

        # 每30秒检查是否卡住（日志无新内容）
        if [ $((ELAPSED % 30)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
            local CURRENT_LINE_COUNT=$(wc -l < "$LOG_TMP" 2>/dev/null || echo 0)
            if [ "$CURRENT_LINE_COUNT" -eq "$LAST_LINE_COUNT" ] && [ "$CURRENT_LINE_COUNT" -gt 0 ]; then
                printf "\r\e[K"
                echo ""
                warn "  ⚠ 安装进程已 30s 无新输出，可能原因："
                warn "    - DKMS 正在编译（正常，可能持续数分钟）"
                warn "    - 网络下载卡顿"
                warn "    - dpkg 被其他进程锁住 (尝试: sudo killall apt apt-get)"
                echo ""
            fi
            LAST_LINE_COUNT=$CURRENT_LINE_COUNT
        fi

        sleep 1
        ELAPSED=$((ELAPSED + 1))
    done

    wait $CMD_PID
    local EXIT_CODE=$?
    printf "\r\e[K"

    local MINS=$((ELAPSED / 60))
    local SECS=$((ELAPSED % 60))

    echo ""
    if [ $EXIT_CODE -eq 0 ]; then
        success "NVIDIA 驱动安装完成（耗时 ${MINS}m${SECS}s）"

        # 验证驱动模块文件已安装到位（真正生效需重启）
        local INSTALLED_MOD=$(find /lib/modules/$(uname -r) -name "nvidia*.ko*" 2>/dev/null | head -1)
        if [ -n "$INSTALLED_MOD" ]; then
            success "NVIDIA 内核模块已安装: $(basename $INSTALLED_MOD)"
            local DKMS_ST=$(dkms status 2>/dev/null | grep -i nvidia | head -1)
            if [ -n "$DKMS_ST" ]; then
                success "DKMS 状态: $DKMS_ST"
            fi
        else
            warn "未找到 NVIDIA 内核模块文件，DKMS 编译可能失败"
            warn "请检查日志: /tmp/gpu-manager-driver-install.log"
        fi

        # Secure Boot: 签名模块
        if [ $NEED_MOK -eq 1 ]; then
            echo ""
            sign_nvidia_modules
            setup_dkms_auto_sign
            echo ""
            warn "╔══════════════════════════════════════════════════════════╗"
            warn "║  重启后会出现蓝色 MOK Manager 界面，请按以下步骤操作：   ║"
            warn "║  1) Enroll MOK → Continue → Yes                         ║"
            warn "║  2) 输入刚才设置的密码                                   ║"
            warn "║  3) Reboot                                               ║"
            warn "║  完成后 Secure Boot + NVIDIA 驱动即可正常工作！           ║"
            warn "╚══════════════════════════════════════════════════════════╝"
        fi

        return 0
    else
        error "NVIDIA 驱动安装失败（耗时 ${MINS}m${SECS}s）"
        echo ""
        error "最后几行日志："
        tail -10 "$LOG_TMP" 2>/dev/null | while read -r line; do
            echo -e "  \e[90m$line\e[0m"
        done
        return 1
    fi
}

# 网络连通性检查
check_network() {
    info "检查网络连通性..."
    if timeout $NETWORK_TIMEOUT bash -c "apt-get update --print-uris > /dev/null 2>&1" || \
       timeout $NETWORK_TIMEOUT ping -c 1 archive.ubuntu.com > /dev/null 2>&1 || \
       timeout $NETWORK_TIMEOUT ping -c 1 mirrors.tuna.tsinghua.edu.cn > /dev/null 2>&1; then
        success "网络连通"
        return 0
    else
        error "网络不可达，无法访问软件源"
        error "请检查网络连接或代理设置"
        return 1
    fi
}

# Root 权限检查（强制）
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 sudo 运行本工具！"
        echo ""
        echo "  用法: sudo gpu-manager"
        echo ""
        exit 1
    fi
}

# OS 版本校验
check_os() {
    if [ ! -f /etc/os-release ]; then
        error "无法识别操作系统"
        return 1
    fi

    source /etc/os-release

    if [[ "$ID" != "ubuntu" ]]; then
        error "本工具仅支持 Ubuntu 系统，当前系统: $ID $VERSION_ID"
        return 1
    fi

    return 0
}

# 获取状态摘要
get_status_bar() {
    local GPU_STATUS="N/A"
    local TPM_STATUS="N/A"
    local DRIVER_STATUS="N/A"

    if lspci 2>/dev/null | grep -qi nvidia; then
        GPU_STATUS="\e[32m✓ 已检测\e[0m"
    else
        GPU_STATUS="\e[31m✗ 未检测到\e[0m"
    fi

    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        DRIVER_STATUS="\e[32m✓ 正常\e[0m"
    elif dpkg -l 2>/dev/null | grep -q "^ii.*nvidia-driver"; then
        DRIVER_STATUS="\e[33m⚠ 已装未加载\e[0m"
    else
        DRIVER_STATUS="\e[31m✗ 未安装\e[0m"
    fi

    if command -v clevis &>/dev/null; then
        local LUKS_DEV=$(blkid 2>/dev/null | grep -i luks | awk -F: '{print $1}' | head -1)
        if [ -n "$LUKS_DEV" ] && clevis luks list -d "$LUKS_DEV" 2>/dev/null | grep -qi tpm2; then
            TPM_STATUS="\e[32m✓ 已绑定\e[0m"
        else
            TPM_STATUS="\e[33m⚠ 未绑定\e[0m"
        fi
    else
        TPM_STATUS="\e[90m- 未配置\e[0m"
    fi

    local MOK_STATUS=""
    if [ -f "$MOK_DER" ]; then
        if command -v mokutil &>/dev/null && mokutil --test-key "$MOK_DER" 2>/dev/null | grep -qi "already enrolled"; then
            MOK_STATUS="\e[32m✓ 已注册\e[0m"
        else
            MOK_STATUS="\e[33m⚠ 未注册\e[0m"
        fi
    elif check_secure_boot; then
        MOK_STATUS="\e[31m✗ 未生成\e[0m"
    else
        MOK_STATUS="\e[90m- 非必需\e[0m"
    fi

    echo -e "  GPU: $GPU_STATUS | 驱动: $DRIVER_STATUS | TPM: $TPM_STATUS | MOK: $MOK_STATUS"
}

# ============================================================
# 前置 APT 更新
# ============================================================

apt_update() {
    info "更新 APT 软件源索引..."

    check_network
    if [ $? -ne 0 ]; then
        return 1
    fi

    apt_with_progress "正在更新软件源" update -qq
    if [ $? -eq 0 ]; then
        success "软件源更新完成"
        return 0
    elif [ $? -eq 124 ]; then
        return 1
    else
        error "软件源更新失败"
        return 1
    fi
}

# ============================================================
# TPM 重新绑定
# ============================================================

tpm_rebind() {
    echo -e "\e[36m"
    echo "=================================================="
    echo "            重新绑定 TPM (Rebind TPM)"
    echo "=================================================="
    echo -e "\e[0m"

    echo ""
    warn "注意：请确认已重启机器且 BIOS 设置正确"
    warn "本流程仅限之前已经加密完成的硬盘，需要再次重新绑定"
    echo ""

    confirm_action "是否继续执行 TPM 重新绑定"
    if [ $? -ne 0 ]; then
        return
    fi

    # Step 1: 检查并安装依赖
    info "[1/6] 检查 TPM 相关依赖..."

    local NEED_INSTALL=""

    if ! command -v tpm2_pcrread &> /dev/null; then
        warn "tpm2-tools 未安装"
        NEED_INSTALL="tpm2-tools"
    else
        success "tpm2-tools 已安装"
    fi

    if ! command -v clevis &> /dev/null; then
        warn "clevis 未安装"
        NEED_INSTALL="$NEED_INSTALL clevis clevis-luks clevis-tpm2"
    elif ! dpkg -l clevis-tpm2 2>/dev/null | grep -q "^ii"; then
        warn "clevis-tpm2 未安装"
        NEED_INSTALL="$NEED_INSTALL clevis-tpm2"
    else
        success "clevis-tpm2 已安装"
    fi

    if [ -n "$NEED_INSTALL" ]; then
        info "正在安装缺失组件: $NEED_INSTALL"

        check_network
        if [ $? -ne 0 ]; then
            return
        fi

        apt_with_progress "更新软件源" update -qq
        apt_with_progress "安装 TPM 组件" install -y $NEED_INSTALL

        if [ $? -ne 0 ]; then
            error "依赖安装失败，请检查网络或软件源配置"
            return
        fi
        success "依赖安装完成"
    fi

    echo ""

    # Step 2: udevadm trigger + tpm2_pcrread
    info "[2/6] 触发 udevadm 并读取 TPM PCR..."
    udevadm trigger

    tpm2_pcrread
    if [ $? -ne 0 ]; then
        error "TPM 读取失败"
        error "请确认："
        error "  1. BIOS 中 TPM 已启用"
        error "  2. 系统已正确识别 TPM 设备 (ls /dev/tpm*)"
        return
    fi

    success "TPM PCR 读取正常"
    echo ""

    # Step 3: 查看硬盘信息
    info "[3/6] 查看硬盘信息..."
    echo ""
    blkid | grep -i luks
    echo ""
    info "以上为检测到的 LUKS 加密分区"
    echo ""

    read -p "请输入需要绑定的硬盘盘符（如 /dev/nvme0n1p3）: " DISK_DEV

    if [ -z "$DISK_DEV" ]; then
        error "未输入硬盘盘符，操作取消"
        return
    fi

    if [ ! -b "$DISK_DEV" ]; then
        error "设备 $DISK_DEV 不存在，请检查输入"
        return
    fi

    if ! cryptsetup isLuks "$DISK_DEV" 2>/dev/null; then
        error "$DISK_DEV 不是 LUKS 加密分区，请确认盘符"
        return
    fi

    # 检查 LUKS 密钥槽
    info "检查 LUKS 密钥槽..."
    local USED_SLOTS=$(cryptsetup luksDump "$DISK_DEV" 2>/dev/null | grep -c "ENABLED")
    local MAX_SLOTS=8

    if [ "$USED_SLOTS" -ge "$MAX_SLOTS" ]; then
        error "LUKS 密钥槽已满（$USED_SLOTS/$MAX_SLOTS），无法添加新绑定"
        error "请先清理不需要的密钥槽"
        return
    fi
    success "密钥槽可用（已用 $USED_SLOTS/$MAX_SLOTS）"

    echo ""

    # Step 4: 检查是否已有 TPM 绑定
    info "[4/6] 检查现有绑定状态..."

    EXISTING_BIND=$(clevis luks list -d "$DISK_DEV" 2>/dev/null)

    if [ -n "$EXISTING_BIND" ]; then
        warn "检测到已有 clevis 绑定："
        echo "$EXISTING_BIND"
        echo ""
        confirm_action "是否先解绑旧的 TPM 绑定再重新绑定"
        if [ $? -eq 0 ]; then
            SLOT=$(echo "$EXISTING_BIND" | grep -i tpm2 | awk '{print $1}' | tr -d ':')
            if [ -n "$SLOT" ]; then
                info "正在解绑 slot $SLOT..."
                clevis luks unbind -d "$DISK_DEV" -s "$SLOT" -f
                if [ $? -eq 0 ]; then
                    success "旧绑定已解除"
                else
                    error "解绑失败，继续尝试新绑定..."
                fi
            fi
        fi
    else
        success "无现有 clevis 绑定"
    fi

    echo ""

    # Step 5: 绑定 TPM
    info "[5/6] 绑定 TPM 芯片..."
    warn "需要输入硬盘恢复密钥（黄色部分，需带横杠输入）"
    warn "格式示例：12345678-XX-12345678"
    warn "请到 IT 服务台由一线 SD 同学提供恢复密钥"
    echo ""

    clevis luks bind -d "$DISK_DEV" tpm2 '{"pcr_bank":"sha256","pcr_ids":"0,1,7"}'

    if [ $? -ne 0 ]; then
        error "TPM 绑定失败"
        error "可能原因："
        error "  1. 恢复密钥输入错误"
        error "  2. TPM 设备异常"
        error "  3. LUKS 密钥槽已满"
        return
    fi

    success "TPM 绑定成功"
    echo ""

    # Step 6: 确认 crypttab 并刷新 initramfs
    info "[6/6] 确认 crypttab 并刷新 initramfs..."
    echo ""
    info "当前 crypttab 内容："
    cat /etc/crypttab
    echo ""

    info "刷新 initramfs..."
    run_with_timeout 180 "更新 initramfs" update-initramfs -u -k 'all'

    if [ $? -eq 0 ]; then
        echo ""
        success "========================================="
        success "  TPM 绑定完成！"
        success "========================================="
        echo ""
        warn "需要重启才能生效！"
        read -p "是否立即重启？(yes/no): " reboot_confirm
        if [ "$reboot_confirm" = "yes" ]; then
            reboot
        else
            warn "请稍后手动执行: sudo reboot"
        fi
    elif [ $? -eq 124 ]; then
        error "initramfs 更新超时，请手动执行: sudo update-initramfs -u -k 'all'"
    else
        error "initramfs 更新失败，请手动执行: sudo update-initramfs -u -k 'all'"
    fi
}

# TPM 状态检查（只读）
tpm_status() {
    echo -e "\e[36m"
    echo "=================================================="
    echo "             TPM 状态检查 (TPM Status)"
    echo "=================================================="
    echo -e "\e[0m"

    echo ""

    info "TPM 设备："
    if [ -e /dev/tpm0 ]; then
        success "  /dev/tpm0 存在"
    else
        error "  /dev/tpm0 不存在"
    fi

    if [ -e /dev/tpmrm0 ]; then
        success "  /dev/tpmrm0 存在"
    else
        warn "  /dev/tpmrm0 不存在"
    fi

    echo ""

    info "TPM PCR 状态："
    if command -v tpm2_pcrread &> /dev/null; then
        tpm2_pcrread sha256:0,1,7 2>/dev/null
        if [ $? -ne 0 ]; then
            error "  TPM PCR 读取失败"
        fi
    else
        warn "  tpm2-tools 未安装"
    fi

    echo ""

    info "LUKS 分区 clevis 绑定状态："
    local LUKS_DEVS=$(blkid 2>/dev/null | grep -i luks | awk -F: '{print $1}')

    if [ -z "$LUKS_DEVS" ]; then
        warn "  未检测到 LUKS 加密分区"
    else
        for DEV in $LUKS_DEVS; do
            echo "  $DEV:"
            if command -v clevis &> /dev/null; then
                local BINDS=$(clevis luks list -d "$DEV" 2>/dev/null)
                if [ -n "$BINDS" ]; then
                    echo "$BINDS" | sed 's/^/    /'
                else
                    warn "    无 clevis 绑定"
                fi
            else
                warn "    clevis 未安装，无法查看绑定状态"
            fi
        done
    fi

    echo ""

    info "crypttab 配置："
    if [ -f /etc/crypttab ]; then
        cat /etc/crypttab | sed 's/^/  /'
    else
        warn "  /etc/crypttab 不存在"
    fi
}

# ============================================================
# Secure Boot 诊断与修复（一键流程）
# ============================================================

secure_boot_manager() {
    echo -e "\e[36m"
    echo "=================================================="
    echo "     Secure Boot 诊断与修复 (Secure Boot Manager)"
    echo "=================================================="
    echo -e "\e[0m"

    # ===== Step 1: 环境检测 =====
    info "[1/5] 环境检测..."
    echo ""

    # UEFI 检查
    if [ ! -d /sys/firmware/efi ]; then
        error "当前系统不是 UEFI 模式，Secure Boot 功能不适用"
        return 1
    fi
    success "  UEFI 模式 ✓"

    # Secure Boot 状态
    local SB_ON=0
    if check_secure_boot; then
        SB_ON=1
        success "  Secure Boot: 已开启"
    else
        warn "  Secure Boot: 未开启"
        echo ""
        info "你可以在 Secure Boot 关闭的状态下提前完成签名准备，"
        info "这样开启 Secure Boot 后系统即可正常启动。"
        echo ""
        echo "  a. 继续诊断并修复（推荐：提前准备）"
        echo "  b. 退出"
        echo ""
        read -p "  请选择 (a/b): " sb_choice
        if [ "$sb_choice" != "a" ]; then
            return 0
        fi
    fi

    # EFI 分区
    if mountpoint -q /boot/efi 2>/dev/null; then
        success "  EFI 分区: $(df -h /boot/efi | tail -1 | awk '{print $1, $2}')"
    else
        warn "  EFI 分区: 未挂载在 /boot/efi"
    fi

    # Ubuntu 版本
    local UBUNTU_VER=""
    if [ -f /etc/os-release ]; then
        UBUNTU_VER=$(. /etc/os-release && echo "${VERSION_ID}")
    fi

    if [ -n "$UBUNTU_VER" ] && [ "$(echo "$UBUNTU_VER >= 24.04" | bc 2>/dev/null)" = "1" ]; then
        echo ""
        success "  Ubuntu $UBUNTU_VER 已内置 DKMS 自动签名"
        info "  系统原生支持 Secure Boot，通常无需手动干预"
        echo ""
        echo "  是否仍要继续诊断？（可能无需操作）"
        echo "  a. 继续"
        echo "  b. 退出"
        echo ""
        read -p "  请选择 (a/b): " ver_choice
        if [ "$ver_choice" != "a" ]; then
            return 0
        fi
    fi

    echo ""

    # ===== Step 2: MOK 密钥状态 =====
    info "[2/5] MOK 密钥状态..."
    echo ""

    local MOK_READY=0
    if [ -f "$MOK_PRIV" ] && [ -f "$MOK_DER" ]; then
        success "  密钥文件: 已存在"

        # 证书摘要
        local MOK_CN=$(openssl x509 -in "$MOK_DER" -inform DER -noout -subject 2>/dev/null | sed 's/.*CN = //' | sed 's/.*CN=//')
        local MOK_EXP=$(openssl x509 -in "$MOK_DER" -inform DER -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        echo "    CN: $MOK_CN"
        echo "    有效期至: $MOK_EXP"

        # 注册状态
        if command -v mokutil &>/dev/null; then
            local MOK_TEST=$(mokutil --test-key "$MOK_DER" 2>/dev/null)
            if echo "$MOK_TEST" | grep -qi "already enrolled"; then
                success "  UEFI 注册: ✓ 已注册（生效中）"
                MOK_READY=1
            else
                warn "  UEFI 注册: ✗ 未注册（需重启确认）"
            fi
        fi

        # DKMS 自动签名
        if [ -f /etc/dkms/framework.conf ] && grep -q "sign_tool" /etc/dkms/framework.conf 2>/dev/null; then
            success "  DKMS 自动签名: ✓ 已配置"
        else
            warn "  DKMS 自动签名: ✗ 未配置"
        fi
    else
        warn "  密钥文件: 未生成"
    fi

    echo ""

    # ===== Step 3: 扫描未签名模块 =====
    info "[3/5] 扫描第三方内核模块..."
    echo ""

    local KVER=$(uname -r)
    local MOD_DIR="/lib/modules/$KVER"
    local UNSIGNED_LIST=()
    local SIGNED_LIST=()
    local INDEX=0

    # 获取所有第三方模块
    local THIRD_PARTY_MODS=""

    if command -v dkms &>/dev/null; then
        local DKMS_MODS=$(dkms status 2>/dev/null | awk -F',' '{print $1}' | awk -F'/' '{print $1}' | sort -u)
        if [ -n "$DKMS_MODS" ]; then
            while read -r DKMS_NAME; do
                [ -z "$DKMS_NAME" ] && continue
                local FILES=$(find "$MOD_DIR" -name "${DKMS_NAME}*.ko" -o -name "${DKMS_NAME}*.ko.zst" -o -name "${DKMS_NAME}*.ko.xz" 2>/dev/null)
                THIRD_PARTY_MODS="$THIRD_PARTY_MODS $FILES"
            done <<< "$DKMS_MODS"
        fi
    fi

    local DKMS_DIR_MODS=$(find "$MOD_DIR/updates/dkms" "$MOD_DIR/extra" -name "*.ko" -o -name "*.ko.zst" -o -name "*.ko.xz" 2>/dev/null)
    THIRD_PARTY_MODS="$THIRD_PARTY_MODS $DKMS_DIR_MODS"

    for NAME in nvidia vboxdrv vboxnetflt vboxnetadp zfs wireguard rtl; do
        local FOUND=$(find "$MOD_DIR" -name "${NAME}*.ko" -o -name "${NAME}*.ko.zst" -o -name "${NAME}*.ko.xz" 2>/dev/null)
        THIRD_PARTY_MODS="$THIRD_PARTY_MODS $FOUND"
    done

    THIRD_PARTY_MODS=$(echo "$THIRD_PARTY_MODS" | tr ' ' '\n' | sort -u | grep -v '^$')

    if [ -z "$THIRD_PARTY_MODS" ]; then
        success "  未发现第三方内核模块"
        echo ""
    else
        printf "  %-4s %-40s %s\n" "编号" "模块" "签名状态"
        echo "  ──── ──────────────────────────────────────── ──────────"

        while read -r MOD_PATH; do
            [ -z "$MOD_PATH" ] && continue
            local MOD_NAME=$(basename "$MOD_PATH" | sed 's/\.ko\(\.zst\|\.xz\)\?$//')
            local IS_SIGNED=0

            if modinfo "$MOD_PATH" 2>/dev/null | grep -q "sig_id\|signature"; then
                IS_SIGNED=1
            fi

            if [ $IS_SIGNED -eq 0 ] && [ -f "$MOD_PATH" ]; then
                if tail -c 28 "$MOD_PATH" 2>/dev/null | grep -q "Module signature"; then
                    IS_SIGNED=1
                fi
            fi

            INDEX=$((INDEX + 1))

            if [ $IS_SIGNED -eq 1 ]; then
                SIGNED_LIST+=("$MOD_PATH")
                printf "  %-4s %-40s \e[32m✓ 已签名\e[0m\n" "$INDEX" "$MOD_NAME"
            else
                UNSIGNED_LIST+=("$MOD_PATH")
                printf "  %-4s %-40s \e[31m✗ 未签名\e[0m\n" "$INDEX" "$MOD_NAME"
            fi
        done <<< "$THIRD_PARTY_MODS"

        echo ""
        echo "  ──────────────────────────────────────────────────────"
        echo -e "  已签名: \e[32m${#SIGNED_LIST[@]}\e[0m  |  未签名: \e[31m${#UNSIGNED_LIST[@]}\e[0m  |  总计: $INDEX"
    fi

    echo ""

    # ===== Step 4: 修复未签名模块 =====
    if [ ${#UNSIGNED_LIST[@]} -eq 0 ]; then
        success "[4/5] 所有模块已签名，无需修复 ✓"
    else
        info "[4/5] 修复未签名模块..."
        echo ""

        # 确保 MOK 密钥存在
        if [ ! -f "$MOK_PRIV" ] || [ ! -f "$MOK_DER" ]; then
            info "  需要先生成 MOK 签名密钥..."
            echo ""
            setup_mok_key
            if [ $? -ne 0 ]; then
                error "  MOK 密钥配置失败，无法签名模块"
                echo ""
                echo "  是否跳过签名，继续检查引导链？"
                read -p "  (y/n): " skip_sign
                if [ "$skip_sign" != "y" ]; then
                    return 1
                fi
            fi
        fi

        if [ -f "$MOK_PRIV" ] && [ -f "$MOK_DER" ]; then
            # 查找 sign-file
            local SIGN_FILE="/usr/src/linux-headers-${KVER}/scripts/sign-file"
            if [ ! -f "$SIGN_FILE" ]; then
                SIGN_FILE=$(find /usr/src/ -name "sign-file" -type f 2>/dev/null | head -1)
            fi

            if [ -z "$SIGN_FILE" ] || [ ! -f "$SIGN_FILE" ]; then
                error "  未找到 sign-file 工具"
                warn "  请安装: sudo apt install linux-headers-$(uname -r)"
            else
                echo "  修复选项："
                echo "    a. 修复全部未签名模块（推荐）"
                echo "    s. 选择特定模块修复"
                echo "    c. 跳过"
                echo ""
                read -p "  请选择 (a/s/c): " fix_choice

                case "$fix_choice" in
                    a)
                        info "  正在签名所有未签名模块..."
                        local FIX_COUNT=0
                        local FAIL_COUNT=0
                        for MOD in "${UNSIGNED_LIST[@]}"; do
                            local MNAME=$(basename "$MOD" | sed 's/\.ko\(\.zst\|\.xz\)\?$//')
                            "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$MOD" 2>/dev/null
                            if [ $? -eq 0 ]; then
                                FIX_COUNT=$((FIX_COUNT + 1))
                                echo -e "    \e[32m✓\e[0m $MNAME"
                            else
                                FAIL_COUNT=$((FAIL_COUNT + 1))
                                echo -e "    \e[31m✗\e[0m $MNAME（签名失败）"
                            fi
                        done
                        echo ""
                        success "  签名完成: $FIX_COUNT 成功, $FAIL_COUNT 失败"
                        setup_dkms_auto_sign
                        ;;
                    s)
                        echo ""
                        echo "  输入要修复的编号（逗号分隔，如: 1,3,5）："
                        read -p "  > " select_nums

                        IFS=',' read -ra SELECTED <<< "$select_nums"
                        local FIX_COUNT=0
                        local ALL_INDEX=0

                        while read -r MOD_PATH; do
                            [ -z "$MOD_PATH" ] && continue
                            ALL_INDEX=$((ALL_INDEX + 1))

                            local IS_UNSIGNED=0
                            for UM in "${UNSIGNED_LIST[@]}"; do
                                if [ "$UM" = "$MOD_PATH" ]; then
                                    IS_UNSIGNED=1
                                    break
                                fi
                            done
                            [ $IS_UNSIGNED -eq 0 ] && continue

                            for SEL in "${SELECTED[@]}"; do
                                SEL=$(echo "$SEL" | tr -d ' ')
                                if [ "$SEL" = "$ALL_INDEX" ]; then
                                    local MNAME=$(basename "$MOD_PATH" | sed 's/\.ko\(\.zst\|\.xz\)\?$//')
                                    "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$MOD_PATH" 2>/dev/null
                                    if [ $? -eq 0 ]; then
                                        FIX_COUNT=$((FIX_COUNT + 1))
                                        echo -e "    \e[32m✓\e[0m $MNAME"
                                    else
                                        echo -e "    \e[31m✗\e[0m $MNAME（签名失败）"
                                    fi
                                fi
                            done
                        done <<< "$THIRD_PARTY_MODS"

                        echo ""
                        success "  已签名 $FIX_COUNT 个模块"
                        setup_dkms_auto_sign
                        ;;
                    *)
                        warn "  已跳过模块签名"
                        ;;
                esac
            fi
        fi
    fi

    echo ""

    # ===== Step 5: 引导链检查 =====
    info "[5/5] 引导链检查..."
    echo ""

    local BOOT_ISSUES=0

    # 检查 EFI 分区文件系统完整性
    local EFI_DEV=$(df /boot/efi 2>/dev/null | tail -1 | awk '{print $1}')
    if [ -n "$EFI_DEV" ] && [ -b "$EFI_DEV" ]; then
        info "  检查 EFI 分区文件系统 ($EFI_DEV)..."

        # 检查是否已经被 remount-ro（这是导致文件丢失的关键原因）
        if mount | grep "/boot/efi" | grep -q "\bro\b"; then
            warn "  EFI 分区已被切换为只读模式！正在修复..."
            umount /boot/efi 2>/dev/null
            fsck.vfat -a "$EFI_DEV" 2>&1 | sed 's/^/    /'
            mount -o rw,fmask=0077,dmask=0077 "$EFI_DEV" /boot/efi 2>/dev/null
            if mount | grep "/boot/efi" | grep -q "\bro\b"; then
                error "  EFI 分区仍为只读，可能存在硬件问题"
                BOOT_ISSUES=$((BOOT_ISSUES + 1))
            else
                success "  EFI 分区已恢复为读写模式 ✓"
            fi
        fi

        # 尝试读取 shimx64.efi 来检测文件系统是否损坏
        if [ -f /boot/efi/EFI/ubuntu/shimx64.efi ]; then
            if ! cat /boot/efi/EFI/ubuntu/shimx64.efi > /dev/null 2>&1; then
                warn "  EFI 分区文件系统可能损坏（文件存在但无法读取）"
                warn "  正在修复..."
                umount /boot/efi 2>/dev/null
                fsck.vfat -a "$EFI_DEV" 2>&1 | sed 's/^/    /'
                mount -o rw,fmask=0077,dmask=0077 "$EFI_DEV" /boot/efi 2>/dev/null
                if cat /boot/efi/EFI/ubuntu/shimx64.efi > /dev/null 2>&1; then
                    success "  EFI 文件系统修复成功 ✓"
                else
                    error "  EFI 文件系统修复后仍无法读取，需要重装引导文件"
                    BOOT_ISSUES=$((BOOT_ISSUES + 1))
                fi
            else
                success "  EFI 文件系统: ✓ 完整可读"
            fi
        else
            # shimx64.efi 不存在，也检查下文件系统
            # dirty bit 可能导致文件丢失
            warn "  shimx64.efi 不存在，检查文件系统..."
            local FSCK_OUT=$(fsck.vfat -n "$EFI_DEV" 2>&1)
            if echo "$FSCK_OUT" | grep -qi "dirty\|corrupt\|error"; then
                warn "  EFI 分区文件系统异常，正在修复..."
                umount /boot/efi 2>/dev/null
                fsck.vfat -a "$EFI_DEV" 2>&1 | sed 's/^/    /'
                mount -o rw,fmask=0077,dmask=0077 "$EFI_DEV" /boot/efi 2>/dev/null
                success "  EFI 文件系统已修复"
            else
                # 文件系统正常但 shim 缺失，直接标记需修复
                BOOT_ISSUES=$((BOOT_ISSUES + 1))
            fi
        fi

        # 修复 fstab 中的 errors=remount-ro（防止未来再次发生只读切换）
        if grep -q "/boot/efi.*errors=remount-ro" /etc/fstab 2>/dev/null; then
            warn "  检测到 fstab 中 EFI 分区使用 errors=remount-ro"
            warn "  这会导致任何 IO 错误后 EFI 分区变为只读，写入静默失败"
            info "  正在修改为 errors=continue..."
            sed -i '/\/boot\/efi/s/errors=remount-ro/errors=continue/' /etc/fstab
            success "  fstab 已更新 ✓"
        fi
    fi

    echo ""

    # 检查 shim
    if dpkg -l shim-signed 2>/dev/null | grep -q "^ii"; then
        success "  shim-signed: ✓ 已安装"
    else
        warn "  shim-signed: ✗ 未安装"
        BOOT_ISSUES=$((BOOT_ISSUES + 1))
    fi

    # 检查 grub-efi
    if dpkg -l grub-efi-amd64-signed 2>/dev/null | grep -q "^ii"; then
        success "  grub-efi-amd64-signed: ✓ 已安装"
    else
        warn "  grub-efi-amd64-signed: ✗ 未安装"
        BOOT_ISSUES=$((BOOT_ISSUES + 1))
    fi

    # 检查 EFI 文件
    if [ -f /boot/efi/EFI/ubuntu/shimx64.efi ]; then
        success "  shimx64.efi: ✓ 存在"
    else
        warn "  shimx64.efi: ✗ 缺失"
        BOOT_ISSUES=$((BOOT_ISSUES + 1))
    fi

    if [ -f /boot/efi/EFI/ubuntu/grubx64.efi ]; then
        success "  grubx64.efi: ✓ 存在"
    else
        warn "  grubx64.efi: ✗ 缺失"
        BOOT_ISSUES=$((BOOT_ISSUES + 1))
    fi

    # 检查 UEFI 启动项是否正确指向 shimx64.efi
    if command -v efibootmgr &>/dev/null; then
        local EFI_ENTRY=$(efibootmgr -v 2>/dev/null | grep -i "ubuntu" | head -1)
        if [ -n "$EFI_ENTRY" ]; then
            if echo "$EFI_ENTRY" | grep -qi "shimx64.efi"; then
                success "  UEFI 启动项: ✓ 指向 shimx64.efi"
            elif echo "$EFI_ENTRY" | grep -qi "grubx64.efi"; then
                warn "  UEFI 启动项: ✗ 直接指向 grubx64.efi（应指向 shimx64.efi）"
                warn "    这是导致 'shim_lock protocol not found' 的直接原因"
                BOOT_ISSUES=$((BOOT_ISSUES + 1))
            else
                warn "  UEFI 启动项: ⚠ 无法识别路径"
                echo "    $EFI_ENTRY"
            fi
        else
            warn "  UEFI 启动项: ✗ 未找到 ubuntu 启动项"
            BOOT_ISSUES=$((BOOT_ISSUES + 1))
        fi
    else
        warn "  efibootmgr: 未安装，无法检查启动项"
    fi

    echo ""

    if [ $BOOT_ISSUES -gt 0 ]; then
        warn "检测到 $BOOT_ISSUES 个引导链问题"
        echo ""
        echo "  是否修复引导链？（重装 shim + grub + 导入 MOK 证书）"
        echo "  适用于出现 'shim_lock protocol not found' 等报错"
        echo ""
        read -p "  修复引导链？(y/n): " fix_boot

        if [ "$fix_boot" = "y" ]; then
            echo ""
            info "  修复引导链..."

            # 先修复 EFI 文件系统（确保写入不会损坏）
            if [ -n "$EFI_DEV" ] && [ -b "$EFI_DEV" ]; then
                info "  检查并修复 EFI 分区文件系统..."
                umount /boot/efi 2>/dev/null
                fsck.vfat -a "$EFI_DEV" 2>&1 | sed 's/^/    /'
                # 强制以 rw 模式挂载，避免 errors=remount-ro 导致静默只读
                mount -o rw,fmask=0077,dmask=0077 "$EFI_DEV" /boot/efi 2>/dev/null
                # 验证挂载确实是 rw
                if mount | grep "/boot/efi" | grep -q "\bro\b"; then
                    error "  EFI 分区无法以读写模式挂载！可能存在硬件问题"
                    error "  请检查 NVMe SSD 健康状态"
                    pause
                    return
                fi
                # 测试写入能力
                if ! touch /boot/efi/.write_test 2>/dev/null; then
                    error "  EFI 分区无法写入！"
                    pause
                    return
                fi
                rm -f /boot/efi/.write_test
                success "  EFI 文件系统检查完成，读写正常 ✓"
                echo ""
            fi

            apt_with_progress "更新软件源" update -qq
            run_with_timeout 180 "重装 shim-signed + grub-efi + mokutil" \
                apt-get install --reinstall -y shim-signed grub-efi-amd64 mokutil

            if [ $? -ne 0 ]; then
                error "  依赖包安装失败"
            else
                success "  依赖包重装完成"

                grub-install --target=x86_64-efi --bootloader-id=ubuntu --efi-directory=/boot/efi --recheck 2>&1
                if [ $? -eq 0 ]; then
                    success "  GRUB 重装完成"
                    update-grub 2>&1
                    success "  GRUB 配置更新完成"
                else
                    error "  GRUB 安装失败"
                fi

                # 确保 UEFI 启动项指向 shimx64.efi
                if command -v efibootmgr &>/dev/null; then
                    local CURRENT_ENTRY=$(efibootmgr -v 2>/dev/null | grep -i "ubuntu" | head -1)
                    if [ -z "$CURRENT_ENTRY" ]; then
                        # 没有 ubuntu 启动项，需要创建
                        info "  未找到 ubuntu 启动项，正在创建..."
                        local EFI_DEV=$(df /boot/efi 2>/dev/null | tail -1 | awk '{print $1}')
                        if [ -n "$EFI_DEV" ]; then
                            local EFI_DISK=$(echo "$EFI_DEV" | sed 's/p\?[0-9]*$//')
                            local EFI_PART=$(echo "$EFI_DEV" | grep -oP '\d+$')
                            efibootmgr -c -d "$EFI_DISK" -p "$EFI_PART" -L "ubuntu" -l "\\EFI\\ubuntu\\shimx64.efi" 2>/dev/null
                            if [ $? -eq 0 ]; then
                                success "  UEFI 启动项已创建: shimx64.efi ✓"
                            else
                                error "  UEFI 启动项创建失败"
                                warn "  请手动执行: sudo efibootmgr -c -d <磁盘> -p <分区号> -L ubuntu -l \\\\EFI\\\\ubuntu\\\\shimx64.efi"
                            fi
                        fi
                    elif echo "$CURRENT_ENTRY" | grep -qi "grubx64.efi" && ! echo "$CURRENT_ENTRY" | grep -qi "shimx64.efi"; then
                        info "  修正 UEFI 启动项指向 shimx64.efi..."
                        local EFI_DEV=$(df /boot/efi 2>/dev/null | tail -1 | awk '{print $1}')
                        if [ -n "$EFI_DEV" ]; then
                            local EFI_DISK=$(echo "$EFI_DEV" | sed 's/p\?[0-9]*$//')
                            local EFI_PART=$(echo "$EFI_DEV" | grep -oP '\d+$')
                            local OLD_BOOTNUM=$(efibootmgr 2>/dev/null | grep -i "ubuntu" | head -1 | grep -oP 'Boot\K[0-9A-Fa-f]+')
                            if [ -n "$OLD_BOOTNUM" ]; then
                                efibootmgr -b "$OLD_BOOTNUM" -B 2>/dev/null
                            fi
                            efibootmgr -c -d "$EFI_DISK" -p "$EFI_PART" -L "ubuntu" -l "\\EFI\\ubuntu\\shimx64.efi" 2>/dev/null
                            if [ $? -eq 0 ]; then
                                success "  UEFI 启动项已修正为 shimx64.efi ✓"
                            else
                                error "  UEFI 启动项修正失败"
                                warn "  请手动执行: sudo efibootmgr -c -d <磁盘> -p <分区号> -L ubuntu -l \\\\EFI\\\\ubuntu\\\\shimx64.efi"
                            fi
                        fi
                    else
                        success "  UEFI 启动项已正确指向 shimx64.efi ✓"
                    fi
                fi

                # 复制 shimx64.efi 到 fallback 路径（解决部分 HP 固件忽略 ubuntu 启动项的问题）
                if [ -f /boot/efi/EFI/ubuntu/shimx64.efi ]; then
                    mkdir -p /boot/efi/EFI/Boot 2>/dev/null
                    cp -f /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/Boot/bootx64.efi 2>/dev/null
                    if [ $? -eq 0 ]; then
                        success "  Fallback 引导: ✓ 已复制到 EFI/Boot/bootx64.efi"
                    fi
                fi

                # 强制同步所有写入到磁盘（关键！防止 EFI 分区因 errors=remount-ro 丢失数据）
                info "  同步数据到磁盘..."
                sync
                sync
                sync
                # 验证文件确实写入成功
                if [ -f /boot/efi/EFI/ubuntu/shimx64.efi ]; then
                    success "  shimx64.efi 验证: ✓ 文件存在且可读"
                else
                    error "  shimx64.efi 验证失败！文件不存在"
                    error "  EFI 分区可能存在严重问题，建议检查硬件"
                fi

                # 导入 shim MOK 证书
                local SHIM_MOK="/usr/share/shim-signed/mok.crt"
                if [ ! -f "$SHIM_MOK" ]; then
                    SHIM_MOK=$(find /usr/share/shim-signed/ -name "*.crt" 2>/dev/null | head -1)
                fi
                if [ -n "$SHIM_MOK" ] && [ -f "$SHIM_MOK" ]; then
                    echo ""
                    warn "  需要设置一个临时密码（重启时在蓝色 MOK Manager 界面输入）"
                    echo ""
                    mokutil --import "$SHIM_MOK"
                    if [ $? -eq 0 ]; then
                        success "  MOK 证书已提交注册请求"
                    fi
                fi
            fi
        fi
    else
        success "  引导链完整 ✓"
        echo ""
        echo "  如仍有 Secure Boot 启动问题，是否强制修复引导链？"
        read -p "  (y/n): " force_fix
        if [ "$force_fix" = "y" ]; then
            echo ""
            info "  强制修复引导链..."

            # 先修复 EFI 文件系统
            if [ -n "$EFI_DEV" ] && [ -b "$EFI_DEV" ]; then
                info "  检查并修复 EFI 分区文件系统..."
                umount /boot/efi 2>/dev/null
                fsck.vfat -a "$EFI_DEV" 2>&1 | sed 's/^/    /'
                mount -o rw,fmask=0077,dmask=0077 "$EFI_DEV" /boot/efi 2>/dev/null
                # 验证 rw 挂载
                if mount | grep "/boot/efi" | grep -q "\bro\b"; then
                    error "  EFI 分区无法以读写模式挂载！可能存在硬件问题"
                    pause
                    return
                fi
                if ! touch /boot/efi/.write_test 2>/dev/null; then
                    error "  EFI 分区无法写入！"
                    pause
                    return
                fi
                rm -f /boot/efi/.write_test
                success "  EFI 文件系统检查完成，读写正常 ✓"
                echo ""
            fi

            apt_with_progress "更新软件源" update -qq
            run_with_timeout 180 "重装 shim-signed + grub-efi + mokutil" \
                apt-get install --reinstall -y shim-signed grub-efi-amd64 mokutil

            if [ $? -ne 0 ]; then
                error "  依赖包安装失败"
            else
                success "  依赖包重装完成"

                grub-install --target=x86_64-efi --bootloader-id=ubuntu --efi-directory=/boot/efi --recheck 2>&1
                if [ $? -eq 0 ]; then
                    success "  GRUB 重装完成"
                    update-grub 2>&1
                    success "  GRUB 配置更新完成"
                else
                    error "  GRUB 安装失败"
                fi

                # 确保 UEFI 启动项指向 shimx64.efi
                if command -v efibootmgr &>/dev/null; then
                    local CURRENT_ENTRY=$(efibootmgr -v 2>/dev/null | grep -i "ubuntu" | head -1)
                    if [ -z "$CURRENT_ENTRY" ]; then
                        info "  未找到 ubuntu 启动项，正在创建..."
                        local EFI_DEV=$(df /boot/efi 2>/dev/null | tail -1 | awk '{print $1}')
                        if [ -n "$EFI_DEV" ]; then
                            local EFI_DISK=$(echo "$EFI_DEV" | sed 's/p\?[0-9]*$//')
                            local EFI_PART=$(echo "$EFI_DEV" | grep -oP '\d+$')
                            efibootmgr -c -d "$EFI_DISK" -p "$EFI_PART" -L "ubuntu" -l "\\EFI\\ubuntu\\shimx64.efi" 2>/dev/null
                            if [ $? -eq 0 ]; then
                                success "  UEFI 启动项已创建: shimx64.efi ✓"
                            else
                                error "  UEFI 启动项创建失败"
                            fi
                        fi
                    elif echo "$CURRENT_ENTRY" | grep -qi "grubx64.efi" && ! echo "$CURRENT_ENTRY" | grep -qi "shimx64.efi"; then
                        info "  修正 UEFI 启动项指向 shimx64.efi..."
                        local EFI_DEV=$(df /boot/efi 2>/dev/null | tail -1 | awk '{print $1}')
                        if [ -n "$EFI_DEV" ]; then
                            local EFI_DISK=$(echo "$EFI_DEV" | sed 's/p\?[0-9]*$//')
                            local EFI_PART=$(echo "$EFI_DEV" | grep -oP '\d+$')
                            local OLD_BOOTNUM=$(efibootmgr 2>/dev/null | grep -i "ubuntu" | head -1 | grep -oP 'Boot\K[0-9A-Fa-f]+')
                            if [ -n "$OLD_BOOTNUM" ]; then
                                efibootmgr -b "$OLD_BOOTNUM" -B 2>/dev/null
                            fi
                            efibootmgr -c -d "$EFI_DISK" -p "$EFI_PART" -L "ubuntu" -l "\\EFI\\ubuntu\\shimx64.efi" 2>/dev/null
                            if [ $? -eq 0 ]; then
                                success "  UEFI 启动项已修正为 shimx64.efi ✓"
                            fi
                        fi
                    else
                        success "  UEFI 启动项已正确指向 shimx64.efi ✓"
                    fi
                fi

                # 复制 shimx64.efi 到 fallback 路径（解决部分 HP 固件忽略启动项的问题）
                if [ -f /boot/efi/EFI/ubuntu/shimx64.efi ]; then
                    mkdir -p /boot/efi/EFI/Boot 2>/dev/null
                    cp -f /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/Boot/bootx64.efi 2>/dev/null
                    if [ $? -eq 0 ]; then
                        success "  Fallback 引导: ✓ 已复制到 EFI/Boot/bootx64.efi"
                    fi
                fi

                # 强制同步到磁盘
                info "  同步数据到磁盘..."
                sync
                sync
                sync
                if [ -f /boot/efi/EFI/ubuntu/shimx64.efi ]; then
                    success "  shimx64.efi 验证: ✓ 文件存在且可读"
                else
                    error "  shimx64.efi 验证失败！文件不存在"
                    error "  EFI 分区可能存在严重问题，建议检查硬件"
                fi

                # 导入 shim MOK 证书
                local SHIM_MOK="/usr/share/shim-signed/mok.crt"
                if [ ! -f "$SHIM_MOK" ]; then
                    SHIM_MOK=$(find /usr/share/shim-signed/ -name "*.crt" 2>/dev/null | head -1)
                fi
                if [ -n "$SHIM_MOK" ] && [ -f "$SHIM_MOK" ]; then
                    echo ""
                    warn "  需要设置一个临时密码（重启时在蓝色 MOK Manager 界面输入）"
                    echo ""
                    mokutil --import "$SHIM_MOK"
                    if [ $? -eq 0 ]; then
                        success "  MOK 证书已提交注册请求"
                    fi
                fi
            fi
            BOOT_ISSUES=1
        fi
    fi

    # ===== 汇总 =====
    echo ""
    echo "══════════════════════════════════════════════════════"
    echo -e "  \e[36m诊断汇总\e[0m"
    echo "══════════════════════════════════════════════════════"
    echo ""

    if [ $SB_ON -eq 1 ]; then
        echo -e "  Secure Boot:     \e[32m已开启\e[0m"
    else
        echo -e "  Secure Boot:     \e[33m未开启\e[0m"
    fi

    if [ -f "$MOK_DER" ]; then
        if command -v mokutil &>/dev/null && mokutil --test-key "$MOK_DER" 2>/dev/null | grep -qi "already enrolled"; then
            echo -e "  MOK 密钥:        \e[32m已注册\e[0m"
        else
            echo -e "  MOK 密钥:        \e[33m待重启注册\e[0m"
        fi
    else
        echo -e "  MOK 密钥:        \e[90m未生成\e[0m"
    fi

    echo -e "  未签名模块:      ${#UNSIGNED_LIST[@]} 个"
    echo -e "  引导链问题:      $BOOT_ISSUES 个"

    echo ""

    # 是否需要重启
    local NEED_REBOOT=0
    if [ -f "$MOK_DER" ] && command -v mokutil &>/dev/null; then
        if mokutil --test-key "$MOK_DER" 2>/dev/null | grep -qi "not enrolled"; then
            NEED_REBOOT=1
        fi
    fi
    if [ $BOOT_ISSUES -gt 0 ]; then
        NEED_REBOOT=1
    fi

    if [ $NEED_REBOOT -eq 1 ]; then
        echo ""
        warn "╔══════════════════════════════════════════════════════════╗"
        warn "║  需要重启才能生效！                                      ║"
        warn "║  重启时如出现蓝色 MOK Manager 界面：                     ║"
        warn "║  Enroll MOK → Continue → Yes → 输入密码 → Reboot        ║"
        warn "╚══════════════════════════════════════════════════════════╝"
        echo ""
        read -p "是否立即重启？(yes/no): " reboot_confirm
        if [ "$reboot_confirm" = "yes" ]; then
            reboot
        else
            warn "请稍后手动执行: sudo reboot"
        fi
    else
        success "当前状态良好，无需重启"
    fi
}

# ============================================================
# 自更新
# ============================================================

self_update() {
    local REPO_URLS=(
        "https://raw.githubusercontent.com/mosh-box/gpu/main"
        "https://ghfast.top/https://raw.githubusercontent.com/mosh-box/gpu/main"
        "https://gh-proxy.com/https://raw.githubusercontent.com/mosh-box/gpu/main"
    )

    info "检查更新..."

    check_network
    if [ $? -ne 0 ]; then
        return
    fi

    local REMOTE_SCRIPT=""
    for REPO_URL in "${REPO_URLS[@]}"; do
        REMOTE_SCRIPT=$(timeout 15 curl -fsSL "$REPO_URL/gpu-manager.sh" 2>/dev/null)
        if [ -n "$REMOTE_SCRIPT" ]; then
            break
        fi
    done

    if [ -z "$REMOTE_SCRIPT" ]; then
        error "无法获取远程版本，请检查网络"
        return
    fi

    local REMOTE_VERSION=$(echo "$REMOTE_SCRIPT" | grep '^VERSION=' | head -1 | cut -d'"' -f2)

    if [ -z "$REMOTE_VERSION" ]; then
        warn "无法解析远程版本号"
        return
    fi

    if [ "$REMOTE_VERSION" = "$VERSION" ]; then
        success "当前已是最新版本 v$VERSION"
        return
    fi

    info "发现新版本: v$REMOTE_VERSION（当前: v$VERSION）"

    confirm_action "是否更新到 v$REMOTE_VERSION"
    if [ $? -ne 0 ]; then
        return
    fi

    info "正在更新..."
    echo "$REMOTE_SCRIPT" > /usr/local/bin/gpu-manager
    chmod +x /usr/local/bin/gpu-manager

    if [ $? -eq 0 ]; then
        success "更新完成！请重新运行 sudo gpu-manager"
        exit 0
    else
        error "更新失败"
    fi
}

# ============================================================
# 帮助信息
# ============================================================

show_help() {
    echo "GPU Manager v$VERSION"
    echo ""
    echo "用法: sudo gpu-manager [选项]"
    echo ""
    echo "选项:"
    echo "  --help, -h          显示帮助信息"
    echo "  --version, -v       显示版本号"
    echo "  --tpm-rebind DEV    非交互式 TPM 重新绑定（需手动输入恢复密钥）"
    echo "  --tpm-status        查看 TPM 绑定状态"
    echo "  --update            检查并更新到最新版本"
    echo ""
    echo "无参数运行进入交互式菜单。"
    echo "注意：必须使用 sudo 运行。"
    echo ""
    echo "日志文件: $LOG_FILE"
}

# ============================================================
# 命令行参数处理（非交互模式）
# ============================================================

if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    show_help
    exit 0
fi

if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then
    echo "GPU Manager v$VERSION"
    exit 0
fi

# 以下命令需要 root
check_root

if [ "$1" = "--tpm-status" ]; then
    tpm_status
    exit 0
fi

if [ "$1" = "--tpm-rebind" ]; then
    if [ -z "$2" ]; then
        error "用法: sudo gpu-manager --tpm-rebind /dev/nvmeXnXpX"
        exit 1
    fi
    DISK_DEV="$2"
    info "非交互式 TPM 绑定: $DISK_DEV"
    udevadm trigger
    tpm2_pcrread || { error "TPM 读取失败"; exit 1; }
    clevis luks bind -d "$DISK_DEV" tpm2 '{"pcr_bank":"sha256","pcr_ids":"0,1,7"}' || { error "绑定失败"; exit 1; }
    update-initramfs -u -k 'all' || { error "initramfs 更新失败"; exit 1; }
    success "TPM 绑定完成，请 reboot 校验"
    exit 0
fi

if [ "$1" = "--update" ]; then
    self_update
    exit 0
fi

# ============================================================
# 启动检查
# ============================================================

check_os || exit 1

log "INFO" "GPU Manager v$VERSION 启动"

# ============================================================
# 主菜单
# ============================================================

while true
do
    clear

    echo -e "\e[36m"
    echo "=================================================="
    echo "              GPU MANAGER  v$VERSION"
    echo "=================================================="
    echo -e "\e[0m"

    get_status_bar

    echo ""
    echo "──────────────────────────────────────────────────"
    echo ""
    echo " ── GPU 驱动管理 ──────────────────────────────────"
    echo "  1. Auto Repair NVIDIA Driver  自动修复 NVIDIA 驱动"
    echo "  2. Check GPU Status           检查 GPU 状态"
    echo "  3. Disable Nouveau            禁用 Nouveau 驱动"
    echo "  4. Remove NVIDIA Drivers      卸载 NVIDIA 驱动"
    echo ""
    echo " ── TPM 磁盘加密 ─────────────────────────────────"
    echo "  5. Rebind TPM                 重新绑定 TPM"
    echo "  6. Check TPM Status           查看 TPM 状态"
    echo ""
    echo " ── Secure Boot ─────────────────────────────────"
    echo "  7. Secure Boot Manager        诊断与修复"
    echo ""
    echo " ── 系统维护 ─────────────────────────────────────"
    echo "  8. Update APT Sources         更新软件源"
    echo "  9. Self Update                检查更新"
    echo "  10. Uninstall GPU Manager     卸载本工具"
    echo "  0.  Exit                      退出"
    echo ""

    read -p "请选择功能 Select Option: " choice

    case $choice in

        1)
            info "正在检测 NVIDIA GPU..."

            GPU_INFO=$(lspci | grep -i nvidia)

            if [ -z "$GPU_INFO" ]; then
                error "未检测到 NVIDIA GPU"
                pause
                continue
            fi

            success "已检测到 NVIDIA GPU"
            echo ""
            echo "$GPU_INFO"
            echo ""

            info "正在检查已安装 NVIDIA 驱动..."

            DRIVER_PACKAGES=$(dpkg -l | awk '/^ii/ && /nvidia-driver/ {print $2}')
            DRIVER_COUNT=$(echo "$DRIVER_PACKAGES" | grep -c nvidia-driver)

            if [ -z "$DRIVER_PACKAGES" ]; then
                warn "未检测到 NVIDIA 驱动"
            elif [ "$DRIVER_COUNT" -gt 1 ]; then
                warn "检测到多个 NVIDIA 驱动版本："
                echo ""
                echo "$DRIVER_PACKAGES"
                echo ""
                warn "多个 NVIDIA 驱动可能导致驱动冲突"

                confirm_action "是否卸载全部 NVIDIA 驱动并重新安装"
                if [ $? -ne 0 ]; then
                    pause
                    continue
                fi

                info "正在卸载旧版 NVIDIA 驱动..."
                apt_with_progress "卸载 NVIDIA 驱动" purge $DRIVER_PACKAGES -y

                if [ $? -eq 0 ]; then
                    success "NVIDIA 驱动卸载完成"
                else
                    error "NVIDIA 驱动卸载失败"
                    pause
                    continue
                fi

                apt_with_progress "清理依赖" autoremove -y
            else
                success "当前仅检测到一个 NVIDIA 驱动版本"
            fi

            echo ""
            info "正在检查 Nouveau 驱动..."

            if lsmod | grep -q nouveau; then
                warn "检测到 Nouveau 驱动"
                warn "禁用 Nouveau 后需要更新 initramfs"

                confirm_action "是否禁用 Nouveau 驱动"
                if [ $? -ne 0 ]; then
                    pause
                    continue
                fi

                info "正在禁用 Nouveau 驱动..."
                echo "blacklist nouveau" | tee /etc/modprobe.d/blacklist-nouveau.conf > /dev/null
                echo "options nouveau modeset=0" | tee -a /etc/modprobe.d/blacklist-nouveau.conf > /dev/null

                run_with_timeout 180 "更新 initramfs" update-initramfs -u

                if [ $? -eq 0 ]; then
                    success "Nouveau 已禁用"
                else
                    error "Nouveau 禁用失败"
                    pause
                    continue
                fi
            else
                success "未检测到 Nouveau 驱动"
            fi

            echo ""

            # 更新软件源（确保能找到最新驱动版本）
            apt_update
            if [ $? -ne 0 ]; then
                pause
                continue
            fi

            # 使用专用驱动安装函数
            install_nvidia_driver

            if [ $? -eq 0 ]; then
                ask_reboot
            fi

            pause
            ;;

        2)
            info "正在检查 GPU 状态..."

            GPU_INFO=$(lspci | grep -i nvidia)

            if [ -z "$GPU_INFO" ]; then
                error "未检测到 NVIDIA GPU"
            else
                success "已检测到 NVIDIA GPU"
                echo ""
                echo "$GPU_INFO"
                echo ""

                info "正在检查 NVIDIA-SMI..."
                nvidia-smi

                if [ $? -eq 0 ]; then
                    echo ""
                    success "GPU 驱动运行正常"
                else
                    echo ""
                    error "NVIDIA-SMI 执行失败"
                    warn "当前驱动可能异常"
                fi
            fi

            pause
            ;;

        3)
            warn "即将禁用 Nouveau 驱动"
            warn "此操作需要更新 initramfs"

            confirm_action "是否继续"
            if [ $? -ne 0 ]; then
                pause
                continue
            fi

            info "正在禁用 Nouveau 驱动..."
            echo "blacklist nouveau" | tee /etc/modprobe.d/blacklist-nouveau.conf > /dev/null
            echo "options nouveau modeset=0" | tee -a /etc/modprobe.d/blacklist-nouveau.conf > /dev/null

            run_with_timeout 180 "更新 initramfs" update-initramfs -u

            if [ $? -eq 0 ]; then
                success "Nouveau 禁用完成"
            else
                error "Nouveau 禁用失败"
            fi

            pause
            ;;

        4)
            info "正在检查 NVIDIA 驱动..."

            DRIVER_PACKAGES=$(dpkg -l | awk '/^ii/ && /nvidia-driver/ {print $2}')

            if [ -z "$DRIVER_PACKAGES" ]; then
                warn "未检测到 NVIDIA 驱动"
                pause
                continue
            fi

            echo ""
            success "检测到以下 NVIDIA 驱动："

            INDEX=1
            declare -a DRIVER_ARRAY

            while read -r line
            do
                DRIVER_ARRAY[$INDEX]=$line
                echo "$INDEX. $line"
                INDEX=$((INDEX + 1))
            done <<< "$DRIVER_PACKAGES"

            echo ""
            echo "a. 卸载全部驱动"
            echo "c. 取消操作"
            echo ""

            read -p "请选择需要卸载的驱动编号: " selection

            if [ "$selection" = "c" ]; then
                warn "用户取消操作"
                pause
                continue
            fi

            if [ "$selection" = "a" ]; then
                warn "即将卸载全部 NVIDIA 驱动"
                confirm_action "确认继续"
                if [ $? -ne 0 ]; then
                    pause
                    continue
                fi
                info "正在卸载全部 NVIDIA 驱动..."
                apt_with_progress "卸载 NVIDIA 驱动" purge $DRIVER_PACKAGES -y
            else
                TARGET_DRIVER=${DRIVER_ARRAY[$selection]}
                if [ -z "$TARGET_DRIVER" ]; then
                    error "无效编号"
                    pause
                    continue
                fi
                warn "即将卸载：$TARGET_DRIVER"
                confirm_action "是否继续"
                if [ $? -ne 0 ]; then
                    pause
                    continue
                fi
                info "正在卸载 $TARGET_DRIVER ..."
                apt_with_progress "卸载 $TARGET_DRIVER" purge $TARGET_DRIVER -y
            fi

            if [ $? -eq 0 ]; then
                success "驱动卸载完成"
                apt_with_progress "清理依赖" autoremove -y
                success "系统清理完成"
            else
                error "驱动卸载失败"
            fi

            pause
            ;;

        5)
            tpm_rebind
            pause
            ;;

        6)
            tpm_status
            pause
            ;;


        7)
            secure_boot_manager
            pause
            ;;

        8)
            apt_update
            pause
            ;;

        9)
            self_update
            pause
            ;;

        10)
            warn "即将卸载 GPU Manager"
            confirm_action "是否继续"
            if [ $? -ne 0 ]; then
                pause
                continue
            fi

            info "正在卸载 GPU Manager..."
            rm -f /usr/local/bin/gpu-manager

            if [ $? -eq 0 ]; then
                success "GPU Manager 卸载完成"
            else
                error "GPU Manager 卸载失败"
            fi

            exit 0
            ;;


        0)
            success "GPU Manager 已退出"
            exit 0
            ;;

        *)
            error "无效选项 Invalid Option"
            pause
            ;;

    esac

done

