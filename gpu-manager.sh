#!/bin/bash

# ============================================================
# GPU Manager
# ============================================================

VERSION="1.7.0"
LOG_FILE="/var/log/gpu-manager.log"
APT_TIMEOUT=300
DRIVER_TIMEOUT=600
NETWORK_TIMEOUT=10

# MOK 密钥管理（Secure Boot 签名用）
MOK_KEY_DIR="/var/lib/gpu-manager/mok"
MOK_PRIV="$MOK_KEY_DIR/mok.priv"
MOK_DER="$MOK_KEY_DIR/mok.der"
MOK_PASSWORD="enkey123"

# 本次会话是否已更新过 apt 索引 / 是否有待重启确认的 MOK 操作
APT_FRESH=0
MOK_ENROLL_PENDING=0
MOK_DELETE_PENDING=0
MOK_FAIL_REASON=""   # MOK 配置失败时由 setup_mok_key 写入“具体命中原因+处置”

# 卸载流程实际执行情况（用于判断是否需要询问重启）
DRIVER_REMOVED=0
MOK_CLEANED=0

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

# MOK 注册重启提醒（重启前重点提示）
show_mok_enroll_guide() {
    echo ""
    warn "╔══════════════════════════════════════════════════════════╗"
    warn "║        ⚠ 重启前必读：MOK 密钥注册步骤（重要！）⚠         ║"
    warn "╠══════════════════════════════════════════════════════════╣"
    warn "║  重启后系统会进入蓝色 MOK Manager 界面，请按以下步骤操作：║"
    warn "║                                                          ║"
    warn "║   1) 选择  Enroll MOK                                    ║"
    warn "║   2) 选择  Continue                                      ║"
    warn "║   3) 选择  Yes                                           ║"
    warn "║   4) 输入密码:  $MOK_PASSWORD                              ║"
    warn "║   5) 选择  Reboot                                        ║"
    warn "║                                                          ║"
    warn "║  注意：MOK 界面有超时，错过后驱动将无法在 Secure Boot    ║"
    warn "║  下加载，需要重新注册！                                  ║"
    warn "║  完成后 Secure Boot + GPU 驱动即可正常共存。             ║"
    warn "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

# MOK 删除重启提醒
show_mok_delete_guide() {
    echo ""
    warn "╔══════════════════════════════════════════════════════════╗"
    warn "║       ⚠ 重启前必读：MOK 密钥删除确认步骤（重要！）⚠      ║"
    warn "╠══════════════════════════════════════════════════════════╣"
    warn "║  重启后系统会进入蓝色 MOK Manager 界面，请按以下步骤操作：║"
    warn "║                                                          ║"
    warn "║   1) 选择  Delete MOK                                    ║"
    warn "║   2) 选择  Continue                                      ║"
    warn "║   3) 选择  Yes                                           ║"
    warn "║   4) 输入密码:  $MOK_PASSWORD                              ║"
    warn "║   5) 选择  Reboot                                        ║"
    warn "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

# 询问是否重启（重启前自动带出 MOK 提醒）
ask_reboot() {
    echo ""
    warn "操作完成后需要重启才能生效！"

    if [ "$MOK_ENROLL_PENDING" -eq 1 ]; then
        show_mok_enroll_guide
    fi
    if [ "$MOK_DELETE_PENDING" -eq 1 ]; then
        show_mok_delete_guide
    fi

    read -p "是否立即重启？(yes/no): " reboot_confirm
    if [ "$reboot_confirm" = "yes" ]; then
        info "正在重启..."
        reboot
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
    run_with_timeout $APT_TIMEOUT "$MSG" apt-get "$@"
    return $?
}

# ============================================================
# 基础检查
# ============================================================

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

# 等待并修复 dpkg 状态
fix_dpkg_state() {
    # 检查 dpkg 锁（避免操作卡住）
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

    return 0
}

# ============================================================
# 操作前统一预检：依赖 + apt 索引保持最新
# 所有功能操作前都必须先通过本检查，避免运行中途失败
# ============================================================

preflight() {
    echo ""
    info "═══ 运行前检查：依赖与软件源 ═══"

    fix_dpkg_state || return 1

    # 更新 apt 索引（每次会话首次操作时执行，确保软件源为最新）
    if [ "$APT_FRESH" -ne 1 ]; then
        check_network || return 1

        apt_with_progress "更新软件源索引" update -qq
        if [ $? -eq 0 ]; then
            success "软件源已更新到最新"
            APT_FRESH=1
        else
            error "软件源更新失败，请检查网络或软件源配置"
            return 1
        fi
    else
        success "软件源索引已是最新（本次会话已更新）"
    fi

    # 检查并补齐基础依赖
    local NEED_INSTALL=""
    command -v lspci          &>/dev/null || NEED_INSTALL+=" pciutils"
    command -v mokutil        &>/dev/null || NEED_INSTALL+=" mokutil"
    command -v openssl        &>/dev/null || NEED_INSTALL+=" openssl"
    command -v ubuntu-drivers &>/dev/null || NEED_INSTALL+=" ubuntu-drivers-common"
    command -v dkms           &>/dev/null || NEED_INSTALL+=" dkms"
    [ -d "/usr/src/linux-headers-$(uname -r)" ] || NEED_INSTALL+=" linux-headers-$(uname -r)"

    if [ -n "$NEED_INSTALL" ]; then
        info "安装缺失依赖:$NEED_INSTALL"
        apt_with_progress "安装基础依赖" install -y $NEED_INSTALL
        if [ $? -ne 0 ]; then
            error "依赖安装失败，无法继续"
            error "详细日志: /tmp/gpu-manager-cmd-output.log"
            return 1
        fi
        success "依赖安装完成"
    else
        success "基础依赖完整"
    fi

    echo ""
    return 0
}

# ============================================================
# Secure Boot / MOK
# ============================================================

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

# 自动检测是否需要安装 MOK 密钥
# 需要的条件：UEFI + Secure Boot 开启 + 密钥未注册
mok_enroll_needed() {
    [ -d /sys/firmware/efi ] || return 1
    check_secure_boot || return 1

    if [ -f "$MOK_DER" ] && command -v mokutil &>/dev/null && \
       mokutil --test-key "$MOK_DER" 2>/dev/null | grep -qi "already enrolled"; then
        return 1
    fi
    return 0
}

# 生成 MOK 密钥并自动注册（默认密码 enkey123，无需手动输入）
setup_mok_key() {
    info "Secure Boot 已开启，自动配置 MOK 密钥签名驱动模块..."
    echo ""

    # 失败时由本函数写入“具体命中的那一条原因 + 对应处置”，供上层精准提示
    MOK_FAIL_REASON=""

    # ── 自动处理(1)：缺 openssl / mokutil，能装就装，不提醒 ──────────
    local _missing=""
    command -v openssl &>/dev/null || _missing+=" openssl"
    command -v mokutil &>/dev/null || _missing+=" mokutil"
    if [ -n "$_missing" ]; then
        info "缺少签名工具:$_missing，自动安装..."
        apt_with_progress "安装 MOK 签名工具" install -y $_missing
        if ! command -v openssl &>/dev/null || ! command -v mokutil &>/dev/null; then
            MOK_FAIL_REASON=$(cat <<EOF
[原因] 签名工具$_missing 缺失且自动安装失败（通常是软件源不可用 / 无网络）。
[处置] 请手动执行后重试本工具：
        sudo apt update && sudo apt install -y$_missing
        详细日志: /tmp/gpu-manager-cmd-output.log
EOF
)
            error "MOK 签名工具自动安装失败"
            return 1
        fi
        success "签名工具已安装"
    fi

    # ── 自动检测(3)：efivars 只读 / 非真正 UEFI，无法写入 MOK，必须用户处理 ──
    if [ ! -d /sys/firmware/efi ]; then
        MOK_FAIL_REASON=$(cat <<'EOF'
[原因] 当前为 Legacy/BIOS 启动（无 /sys/firmware/efi），根本不支持 MOK 注册。
[处置] 这类机器本不该开 Secure Boot —— 进 BIOS 关闭 Secure Boot 后重跑本工具即可直接装驱动。
EOF
)
        error "非 UEFI 启动，无法注册 MOK"
        return 1
    fi
    if mount | grep -q 'efivars.*[(,]ro[,)]'; then
        MOK_FAIL_REASON=$(cat <<'EOF'
[原因] efivars 以只读(ro)挂载（常见于虚拟机/云主机），MOK 密钥写不进 UEFI。
[处置] 这类机器通常无需 MOK —— 进 BIOS/控制台关闭 Secure Boot 后重跑本工具即可。
        （如确为物理机，可尝试: sudo mount -o remount,rw /sys/firmware/efi/efivars 后重试）
EOF
)
        error "efivars 只读，无法写入 MOK 密钥"
        return 1
    fi

    # 检查是否已有 MOK 密钥
    if [ -f "$MOK_PRIV" ] && [ -f "$MOK_DER" ]; then
        # 检查密钥是否已注册到 UEFI
        if mokutil --test-key "$MOK_DER" 2>/dev/null | grep -qi "already enrolled"; then
            success "MOK 密钥已存在且已注册，无需重复操作"
            return 0
        else
            info "MOK 密钥文件存在但未注册到 UEFI，将自动重新注册"
        fi
    else
        # 生成新密钥
        info "生成 MOK 签名密钥..."
        mkdir -p "$MOK_KEY_DIR"
        openssl req -new -x509 -newkey rsa:2048 -keyout "$MOK_PRIV" -outform DER \
            -out "$MOK_DER" -nodes -days 36500 \
            -subj "/CN=GPU Manager MOK Signing Key/" 2>/dev/null

        if [ $? -ne 0 ]; then
            # 区分(2)：是否磁盘空间不足导致写不进去
            local _avail
            _avail=$(df -Pk /var 2>/dev/null | awk 'NR==2{print $4}')
            if [ -n "$_avail" ] && [ "$_avail" -lt 10240 ]; then
                MOK_FAIL_REASON=$(printf '%s\n%s\n        %s\n' \
                    "[原因] /var 可用空间不足（剩余 $((_avail/1024)) MB），密钥文件写不进去。" \
                    "[处置] 清理磁盘后重试本工具：" \
                    "df -h /var   # 确认空间，清理后重跑")
            else
                MOK_FAIL_REASON=$(printf '%s\n%s\n        %s\n' \
                    "[原因] openssl 生成密钥失败（非空间问题）。" \
                    "[处置] 手动复现以查看具体报错：" \
                    "sudo openssl req -new -x509 -newkey rsa:2048 -keyout $MOK_PRIV -outform DER -out $MOK_DER -nodes -days 36500 -subj '/CN=GPU Manager MOK Signing Key/'")
            fi
            error "MOK 密钥生成失败"
            return 1
        fi
        success "MOK 密钥已生成: $MOK_DER"
    fi

    # 自动注册，使用默认密码（重启时在 MOK Manager 界面输入同一密码）
    info "自动注册 MOK 密钥（默认密码: $MOK_PASSWORD）..."
    printf '%s\n%s\n' "$MOK_PASSWORD" "$MOK_PASSWORD" | mokutil --import "$MOK_DER" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        success "MOK 密钥已提交注册请求（密码: $MOK_PASSWORD）"
        MOK_ENROLL_PENDING=1
        show_mok_enroll_guide
        return 0
    fi

    # ── 自动处理(4)：可能是有未确认的待注册请求冲突，撤销后自动重试一次 ──
    warn "首次注册失败，自动清理可能存在的待确认请求后重试..."
    printf '%s\n%s\n' "$MOK_PASSWORD" "$MOK_PASSWORD" | mokutil --revoke-import >/dev/null 2>&1
    printf '%s\n%s\n' "$MOK_PASSWORD" "$MOK_PASSWORD" | mokutil --import "$MOK_DER" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        success "清理冲突后注册成功（密码: $MOK_PASSWORD）"
        MOK_ENROLL_PENDING=1
        show_mok_enroll_guide
        return 0
    fi

    MOK_FAIL_REASON=$(printf '%s\n%s\n        %s\n' \
        "[原因] mokutil --import 注册失败（已自动撤销待确认请求并重试仍失败）。" \
        "[处置] 手动注册以查看 mokutil 的具体报错：" \
        "sudo mokutil --import $MOK_DER")
    error "MOK 密钥自动注册失败"
    return 1
}

# 手动入口：注册 MOK 密钥并重启进入蓝色 MOK Manager 界面
# （独立于装驱动流程，用户想单独触发“重启后弹出 MOK 注册界面”时使用）
enroll_mok_and_reboot() {
    echo ""
    info "╔══════════════════════════════════════════════════════╗"
    info "║   注册 MOK 密钥 → 重启进入 MOK Manager 注册界面        ║"
    info "╚══════════════════════════════════════════════════════╝"
    echo ""

    # 前置检查：没有 UEFI / Secure Boot 未开启时，重启不会弹出 MOK 界面
    if [ ! -d /sys/firmware/efi ]; then
        error "当前为 Legacy/BIOS 启动，不支持 MOK，重启也不会出现 MOK 界面"
        return 1
    fi
    if ! check_secure_boot; then
        warn "Secure Boot 当前未开启：未签名模块本就能直接加载，无需 MOK。"
        warn "若仍要预先注册密钥（为日后开启 Secure Boot 做准备），可继续。"
        confirm_action "是否仍要注册 MOK 密钥并重启"
        [ $? -ne 0 ] && return 1
    fi

    # 复用统一的密钥生成 + 注册逻辑（含自动装工具、清冲突重试、精准报错）
    setup_mok_key
    if [ $? -ne 0 ]; then
        echo ""
        error "MOK 密钥注册失败，无法进入 MOK 界面"
        if [ -n "$MOK_FAIL_REASON" ]; then
            echo ""
            while IFS= read -r _line; do warn "  $_line"; done <<<"$MOK_FAIL_REASON"
        fi
        return 1
    fi

    # setup_mok_key 成功有两种情况：
    #   - 本次新提交了注册请求 → MOK_ENROLL_PENDING=1，重启即弹 MOK 界面
    #   - 密钥早已注册 → 无待确认请求，重启不会再弹界面
    if [ "$MOK_ENROLL_PENDING" -ne 1 ]; then
        echo ""
        success "MOK 密钥此前已注册，无需重复操作；重启不会再出现 MOK 界面。"
        warn  "如需强制重新走一遍注册界面，可先在菜单 3 卸载 MOK 密钥后再用本功能。"
        return 0
    fi

    echo ""
    success "MOK 注册请求已提交，重启后即可看到蓝色 MOK Manager 界面。"
    ask_reboot
    return 0
}

# 自动卸载 MOK 密钥（删除注册 + 清理密钥文件与 DKMS 签名配置）
remove_mok_key() {
    info "正在自动卸载 MOK 密钥..."
    echo ""

    if [ ! -f "$MOK_DER" ] && [ ! -d "$MOK_KEY_DIR" ]; then
        success "未发现 GPU Manager 生成的 MOK 密钥，无需卸载"
    else
        if [ -f "$MOK_DER" ] && command -v mokutil &>/dev/null; then
            # 已注册：提交删除请求（重启时确认）
            if mokutil --test-key "$MOK_DER" 2>/dev/null | grep -qi "already enrolled"; then
                info "MOK 密钥已注册，提交删除请求（密码: $MOK_PASSWORD）..."
                printf '%s\n%s\n' "$MOK_PASSWORD" "$MOK_PASSWORD" | mokutil --delete "$MOK_DER" >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    success "MOK 删除请求已提交，重启后确认生效"
                    MOK_DELETE_PENDING=1
                else
                    error "MOK 删除请求提交失败"
                    error "可手动执行: sudo mokutil --delete $MOK_DER"
                fi
            else
                # 未注册但可能有待处理的注册请求：撤销
                info "MOK 密钥未注册，撤销可能存在的待注册请求..."
                printf '%s\n%s\n' "$MOK_PASSWORD" "$MOK_PASSWORD" | mokutil --revoke-import >/dev/null 2>&1
                success "已撤销待注册请求（如有）"
            fi
        fi

        # 删除密钥文件
        rm -rf "$MOK_KEY_DIR"
        success "MOK 密钥文件已删除: $MOK_KEY_DIR"
        MOK_CLEANED=1
    fi

    # 清理 DKMS 自动签名配置
    if [ -f /etc/dkms/sign_helper.sh ]; then
        rm -f /etc/dkms/sign_helper.sh
        success "DKMS 签名脚本已删除"
        MOK_CLEANED=1
    fi
    if [ -f /etc/dkms/framework.conf ] && \
       grep -qE 'GPU Manager: auto-sign|sign_helper\.sh|/var/lib/gpu-manager/mok' /etc/dkms/framework.conf; then
        sed -i '/GPU Manager: auto-sign/d; /sign_helper\.sh/d; /\/var\/lib\/gpu-manager\/mok/d' /etc/dkms/framework.conf
        success "DKMS 自动签名配置已清理"
        MOK_CLEANED=1
    fi

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

# ============================================================
# GPU 检测
# ============================================================

detect_nvidia_gpu() {
    lspci 2>/dev/null | grep -i nvidia
}

detect_amd_gpu() {
    lspci 2>/dev/null | grep -Ei 'VGA|3D|Display' | grep -Ei 'AMD|ATI'
}

# ============================================================
# NVIDIA 驱动安装：后台运行 + 实时分析日志输出当前阶段和速率
# ============================================================

install_nvidia_driver() {
    local LOG_TMP="/tmp/gpu-manager-driver-install.log"
    local NEED_MOK=0

    # ===== 自动检测是否需要 MOK 密钥 =====
    # 仅当“UEFI + Secure Boot 已开启”才需要 MOK：进入后由 setup_mok_key 决定
    # 加不加密钥——未注册才生成并注册，已注册则跳过、只复用现有密钥签名模块。
    # Secure Boot 关闭时走下面 elif 分支，完全不碰 MOK。
    if [ -d /sys/firmware/efi ] && check_secure_boot; then
        echo ""
        info "╔══════════════════════════════════════════════════════╗"
        info "║  检测到 Secure Boot 已开启，需要 MOK 密钥签名驱动     ║"
        info "╚══════════════════════════════════════════════════════╝"
        echo ""

        setup_mok_key
        if [ $? -ne 0 ]; then
            echo ""
            error "============================================================"
            error "  MOK key auto-config FAILED -- installation ABORTED"
            error "============================================================"
            echo ""
            warn  "为什么中止：本机已开启 Secure Boot，驱动模块必须用 MOK 密钥"
            warn  "签名后才能被内核加载。密钥没配好就装驱动，装完 nvidia-smi"
            warn  "依然会失败（couldn't communicate with the NVIDIA driver），"
            warn  "白白浪费 5-15 分钟编译时间，所以这里直接停下来。"
            echo ""
            # 只打印本次实际命中的那一条原因与处置（脚本已尽力自动修复，剩下的需用户处理）
            if [ -n "$MOK_FAIL_REASON" ]; then
                warn  "本次失败的具体原因与对应解决办法："
                echo ""
                while IFS= read -r _line; do warn "  $_line"; done <<<"$MOK_FAIL_REASON"
            else
                warn  "未能识别具体原因，详见日志: /tmp/gpu-manager-cmd-output.log"
            fi
            echo ""
            warn  "【最省事的替代方案】进 BIOS/UEFI 关闭 Secure Boot，"
            warn  "关闭后无需 MOK，重新运行本工具即可直接安装。"
            echo ""
            error "解决上述问题后，请重新运行本工具。"
            return 1
        else
            NEED_MOK=1
            # 提前配置 DKMS 自动签名，这样 ubuntu-drivers autoinstall
            # 在 DKMS 编译模块时就会直接用 MOK 密钥签名，
            # 避免 ubuntu-drivers 自己触发 mokutil --import 再次要求输入密码
            setup_dkms_auto_sign
        fi
    elif [ -d /sys/firmware/efi ]; then
        info "UEFI 系统，Secure Boot 未开启，无需 MOK 密钥"
        echo ""
    fi

    # 检查推荐驱动版本
    local RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | grep "recommended" | awk '{print $3}')
    if [ -n "$RECOMMENDED" ]; then
        info "系统推荐驱动: $RECOMMENDED"
    else
        warn "未检测到推荐驱动版本，将使用 autoinstall 自动选择"
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
    ubuntu-drivers autoinstall > "$LOG_TMP" 2>&1 &
    local CMD_PID=$!

    local ELAPSED=0
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

# ============================================================
# AMD 驱动安装（内核内置 amdgpu + 用户态组件）
# ============================================================

install_amd_driver() {
    echo ""
    info "AMD GPU 使用内核内置 amdgpu 驱动，安装固件与用户态组件..."
    echo ""

    apt_with_progress "安装 AMD 驱动组件" install -y \
        linux-firmware mesa-vulkan-drivers mesa-utils \
        libdrm-amdgpu1 xserver-xorg-video-amdgpu

    if [ $? -ne 0 ]; then
        error "AMD 驱动组件安装失败"
        error "详细日志: /tmp/gpu-manager-cmd-output.log"
        return 1
    fi

    success "AMD 驱动组件安装完成"

    # 检查 amdgpu 模块状态
    if lsmod | grep -q amdgpu; then
        success "amdgpu 内核模块已加载"
    else
        warn "amdgpu 内核模块尚未加载，重启后生效"
    fi

    return 0
}

# ============================================================
# 自动检测并安装 GPU 驱动（NVIDIA / AMD）
# ============================================================

auto_install_drivers() {
    preflight || return 1

    info "正在检测 GPU 设备..."
    echo ""

    local NVIDIA_INFO=$(detect_nvidia_gpu)
    local AMD_INFO=$(detect_amd_gpu)

    if [ -z "$NVIDIA_INFO" ] && [ -z "$AMD_INFO" ]; then
        error "未检测到 NVIDIA 或 AMD GPU"
        return 1
    fi

    if [ -n "$NVIDIA_INFO" ]; then
        success "已检测到 NVIDIA GPU:"
        echo "$NVIDIA_INFO"
        echo ""
    fi
    if [ -n "$AMD_INFO" ]; then
        success "已检测到 AMD GPU:"
        echo "$AMD_INFO"
        echo ""
    fi

    local INSTALL_OK=0

    # ===== NVIDIA 流程 =====
    if [ -n "$NVIDIA_INFO" ]; then
        # 检查多版本驱动冲突
        info "正在检查已安装 NVIDIA 驱动..."
        local DRIVER_PACKAGES=$(dpkg -l | awk '/^ii/ && /nvidia-driver/ {print $2}')
        local DRIVER_COUNT=$(echo "$DRIVER_PACKAGES" | grep -c nvidia-driver)

        if [ -n "$DRIVER_PACKAGES" ] && [ "$DRIVER_COUNT" -gt 1 ]; then
            warn "检测到多个 NVIDIA 驱动版本，可能导致冲突，自动清理后重装："
            echo "$DRIVER_PACKAGES"
            echo ""
            apt_with_progress "卸载冲突的 NVIDIA 驱动" purge $DRIVER_PACKAGES -y
            apt_with_progress "清理依赖" autoremove -y
        fi

        # 自动禁用 Nouveau（与 NVIDIA 官方驱动冲突）
        if lsmod | grep -q nouveau; then
            info "检测到 Nouveau 驱动，自动禁用..."
            echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf
            echo "options nouveau modeset=0" >> /etc/modprobe.d/blacklist-nouveau.conf
            run_with_timeout 180 "更新 initramfs" update-initramfs -u
            if [ $? -eq 0 ]; then
                success "Nouveau 已禁用"
            else
                warn "Nouveau 禁用过程出现问题，继续安装"
            fi
        fi

        echo ""
        install_nvidia_driver
        if [ $? -eq 0 ]; then
            INSTALL_OK=1
        fi
    fi

    # ===== AMD 流程 =====
    if [ -n "$AMD_INFO" ]; then
        install_amd_driver
        if [ $? -eq 0 ]; then
            INSTALL_OK=1
        fi
    fi

    if [ $INSTALL_OK -eq 1 ]; then
        ask_reboot
        return 0
    fi
    return 1
}

# ============================================================
# 自动卸载 NVIDIA 驱动 / MOK 密钥（可选范围）
# ============================================================

remove_nvidia_driver() {
    info "正在自动卸载 NVIDIA 驱动..."
    local NVIDIA_PACKAGES=$(dpkg -l | awk '/^ii/ && $2 ~ /nvidia/ {print $2}')

    if [ -z "$NVIDIA_PACKAGES" ]; then
        success "未检测到已安装的 NVIDIA 驱动包，无需卸载"
        return 0
    fi

    echo "$NVIDIA_PACKAGES" | sed 's/^/  /'
    echo ""
    run_with_timeout $DRIVER_TIMEOUT "卸载 NVIDIA 驱动包" apt-get purge -y $NVIDIA_PACKAGES
    if [ $? -ne 0 ]; then
        error "NVIDIA 驱动卸载失败"
        error "详细日志: /tmp/gpu-manager-cmd-output.log"
        return 1
    fi
    apt_with_progress "清理无用依赖" autoremove --purge -y
    success "NVIDIA 驱动已全部卸载"
    DRIVER_REMOVED=1

    # 恢复 Nouveau（删除黑名单，让开源驱动接管显示）
    if [ -f /etc/modprobe.d/blacklist-nouveau.conf ]; then
        rm -f /etc/modprobe.d/blacklist-nouveau.conf
        run_with_timeout 180 "更新 initramfs" update-initramfs -u
        success "已恢复 Nouveau 开源驱动（重启后生效）"
    fi

    return 0
}

auto_remove_nvidia_and_mok() {
    echo ""
    echo "  请选择卸载范围："
    echo "    a. 全部卸载（NVIDIA 驱动 + MOK 密钥）"
    echo "    b. 仅卸载 NVIDIA 驱动"
    echo "    c. 仅卸载 MOK 密钥"
    echo "    q. 取消"
    echo ""
    read -p "  请选择 (a/b/c/q): " remove_choice

    local DO_DRIVER=0
    local DO_MOK=0
    case "$remove_choice" in
        a) DO_DRIVER=1; DO_MOK=1 ;;
        b) DO_DRIVER=1 ;;
        c) DO_MOK=1 ;;
        *)
            warn "已取消操作"
            return 1
            ;;
    esac

    if [ $DO_DRIVER -eq 1 ] && [ $DO_MOK -eq 1 ]; then
        warn "本操作将自动卸载全部 NVIDIA 驱动，并删除 GPU Manager 的 MOK 密钥"
    elif [ $DO_DRIVER -eq 1 ]; then
        warn "本操作将自动卸载全部 NVIDIA 驱动"
    else
        warn "本操作将删除 GPU Manager 的 MOK 密钥"
    fi
    confirm_action "确认继续"
    if [ $? -ne 0 ]; then
        return 1
    fi
    echo ""

    preflight || return 1

    local STEP=0
    local TOTAL=$((DO_DRIVER + DO_MOK))

    if [ $DO_DRIVER -eq 1 ]; then
        STEP=$((STEP + 1))
        info "[$STEP/$TOTAL] 卸载 NVIDIA 驱动..."
        remove_nvidia_driver || return 1
        echo ""
    fi

    if [ $DO_MOK -eq 1 ]; then
        STEP=$((STEP + 1))
        info "[$STEP/$TOTAL] 卸载 MOK 密钥..."
        remove_mok_key
        echo ""
    fi

    # 根据实际执行情况决定是否需要重启：
    # - 卸载了驱动或提交了 MOK 删除请求 → 需要重启
    # - 只清理了密钥文件/配置 → 无需重启
    # - 什么都没检测到 → 直接结束
    if [ "$DRIVER_REMOVED" -eq 1 ] || [ "$MOK_DELETE_PENDING" -eq 1 ]; then
        success "卸载完成"
        ask_reboot
    elif [ "$MOK_CLEANED" -eq 1 ]; then
        success "卸载完成，本次仅清理了本地文件，无需重启"
    else
        success "未检测到需要卸载的内容，未做任何更改，无需重启"
    fi
    return 0
}

# ============================================================
# GPU 状态检查
# ============================================================

check_gpu_status() {
    info "正在检查 GPU 状态..."
    echo ""

    local NVIDIA_INFO=$(detect_nvidia_gpu)
    local AMD_INFO=$(detect_amd_gpu)

    if [ -z "$NVIDIA_INFO" ] && [ -z "$AMD_INFO" ]; then
        error "未检测到 NVIDIA 或 AMD GPU"
        return 1
    fi

    if [ -n "$NVIDIA_INFO" ]; then
        success "已检测到 NVIDIA GPU:"
        echo "$NVIDIA_INFO"
        echo ""

        info "正在检查 NVIDIA-SMI..."
        if command -v nvidia-smi &>/dev/null; then
            nvidia-smi
            if [ $? -eq 0 ]; then
                echo ""
                success "NVIDIA 驱动运行正常"
            else
                echo ""
                error "NVIDIA-SMI 执行失败，当前驱动可能异常"
            fi
        else
            warn "nvidia-smi 未安装（驱动未安装或未生效）"
        fi
        echo ""
    fi

    if [ -n "$AMD_INFO" ]; then
        success "已检测到 AMD GPU:"
        echo "$AMD_INFO"
        echo ""

        if lsmod | grep -q amdgpu; then
            success "amdgpu 内核驱动运行正常"
        else
            warn "amdgpu 内核驱动未加载"
        fi
    fi

    return 0
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

    # Step 0: 统一预检（依赖 + apt 最新）
    preflight || return

    # Step 1: 检查并安装 TPM 专用依赖
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
        ask_reboot
    elif [ $? -eq 124 ]; then
        error "initramfs 更新超时，请手动执行: sudo update-initramfs -u -k 'all'"
    else
        error "initramfs 更新失败，请手动执行: sudo update-initramfs -u -k 'all'"
    fi
}

# ============================================================
# 状态摘要
# ============================================================

get_status_bar() {
    local GPU_STATUS="N/A"
    local DRIVER_STATUS="N/A"

    local HAS_NVIDIA=0
    local HAS_AMD=0
    lspci 2>/dev/null | grep -qi nvidia && HAS_NVIDIA=1
    lspci 2>/dev/null | grep -Ei 'VGA|3D|Display' | grep -qiE 'AMD|ATI' && HAS_AMD=1

    if [ $HAS_NVIDIA -eq 1 ] && [ $HAS_AMD -eq 1 ]; then
        GPU_STATUS="\e[32m✓ NVIDIA+AMD\e[0m"
    elif [ $HAS_NVIDIA -eq 1 ]; then
        GPU_STATUS="\e[32m✓ NVIDIA\e[0m"
    elif [ $HAS_AMD -eq 1 ]; then
        GPU_STATUS="\e[32m✓ AMD\e[0m"
    else
        GPU_STATUS="\e[31m✗ 未检测到\e[0m"
    fi

    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        DRIVER_STATUS="\e[32m✓ 正常\e[0m"
    elif [ $HAS_AMD -eq 1 ] && [ $HAS_NVIDIA -eq 0 ] && lsmod 2>/dev/null | grep -q amdgpu; then
        DRIVER_STATUS="\e[32m✓ 正常\e[0m"
    elif dpkg -l 2>/dev/null | grep -q "^ii.*nvidia-driver"; then
        DRIVER_STATUS="\e[33m⚠ 已装未加载\e[0m"
    else
        DRIVER_STATUS="\e[31m✗ 未安装\e[0m"
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

    echo -e "  GPU: $GPU_STATUS | 驱动: $DRIVER_STATUS | MOK: $MOK_STATUS"
}

# ============================================================
# 帮助信息
# ============================================================

show_help() {
    echo "GPU Manager"
    echo ""
    echo "用法: sudo gpu-manager [选项]"
    echo ""
    echo "选项:"
    echo "  --help, -h          显示帮助信息"
    echo "  --version, -v       显示版本号"
    echo "  --tpm-rebind DEV    非交互式 TPM 重新绑定（需手动输入恢复密钥）"
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

# ============================================================
# 启动检查
# ============================================================

check_os || exit 1

log "INFO" "GPU Manager 启动"

# ============================================================
# 主菜单
# ============================================================

while true
do
    clear

    echo -e "\e[36m"
    echo "=================================================="
    echo "                   GPU MANAGER"
    echo "=================================================="
    echo -e "\e[0m"

    get_status_bar

    echo ""
    echo "──────────────────────────────────────────────────"
    echo ""
    echo " ── GPU 驱动管理 ──────────────────────────────────"
    echo "  1. Auto Install GPU Driver    自动检测并安装驱动 (NVIDIA/AMD)"
    echo "  2. Check GPU Status           检查 GPU 状态"
    echo "  3. Remove Driver / MOK        卸载 NVIDIA 驱动 / MOK 密钥（可选范围）"
    echo ""
    echo " ── Secure Boot / MOK ────────────────────────────"
    echo "  4. Enroll MOK & Reboot        注册 MOK 密钥并重启进入 MOK 界面"
    echo ""
    echo " ── TPM 磁盘加密 ─────────────────────────────────"
    echo "  5. Rebind TPM                 重新绑定 TPM"
    echo ""
    echo " ── 系统维护 ─────────────────────────────────────"
    echo "  6. Uninstall GPU Manager      卸载本工具"
    echo "  0. Exit                       退出"
    echo ""

    read -p "请选择功能 Select Option: " choice

    case $choice in

        1)
            auto_install_drivers
            pause
            ;;

        2)
            check_gpu_status
            pause
            ;;

        3)
            auto_remove_nvidia_and_mok
            pause
            ;;

        4)
            enroll_mok_and_reboot
            pause
            ;;

        5)
            tpm_rebind
            pause
            ;;

        6)
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
