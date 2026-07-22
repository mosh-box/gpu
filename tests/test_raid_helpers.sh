#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
GPU_MANAGER="$SCRIPT_DIR/../gpu-manager.sh"

source "$GPU_MANAGER"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[ "$VERSION" = "1.9.0" ] || fail "version should be 1.9.0"

[ "$(raid_min_devices 0)" = "2" ] || fail "RAID0 minimum device count is wrong"
[ "$(raid_min_devices 5)" = "3" ] || fail "RAID5 minimum device count is wrong"
[ "$(raid_min_devices 6)" = "4" ] || fail "RAID6 minimum device count is wrong"
[ "$(raid_min_devices 10)" = "4" ] || fail "RAID10 minimum device count is wrong"

raid_device_count_valid 0 2 || fail "RAID0 with two devices rejected"
raid_device_count_valid 1 2 || fail "RAID1 with two devices rejected"
raid_device_count_valid 5 3 || fail "RAID5 with three devices rejected"
raid_device_count_valid 6 4 || fail "RAID6 with four devices rejected"
raid_device_count_valid 10 4 || fail "RAID10 with four devices rejected"
raid_device_count_valid 10 6 || fail "RAID10 with six devices rejected"
if raid_device_count_valid 5 2; then fail "RAID5 with two devices accepted"; fi
if raid_device_count_valid 6 3; then fail "RAID6 with three devices accepted"; fi
if raid_device_count_valid 10 5; then fail "RAID10 with odd device count accepted"; fi

SAMPLE_PROGRESS='[==>.................]  resync = 12.3% (123/1000) finish=10.2min speed=123456K/sec'
[ "$(printf '%s\n' "$SAMPLE_PROGRESS" | extract_md_progress_percent)" = "12.3" ] || fail "progress percentage parser failed"
[ "$(render_progress_bar 50 10)" = "[#####-----]" ] || fail "progress bar rendering failed"

# 创建向导的菜单序号必须准确映射到 mdadm RAID level。
(
    create_data_raid() { echo "DISPATCH_LEVEL=$1"; }
    for CASE in "1:0" "2:1" "3:5" "4:6" "5:10"; do
        CHOICE=${CASE%%:*}
        EXPECTED_LEVEL=${CASE##*:}
        ACTUAL_LEVEL=$(printf '%s\n' "$CHOICE" | create_raid_wizard | sed -n 's/^DISPATCH_LEVEL=//p')
        [ "$ACTUAL_LEVEL" = "$EXPECTED_LEVEL" ] || fail "wizard choice $CHOICE mapped to RAID$ACTUAL_LEVEL instead of RAID$EXPECTED_LEVEL"
    done
)

validate_raid_name "data-raid0" || fail "valid RAID name rejected"
validate_raid_name "R1_data.01" || fail "valid dotted RAID name rejected"
if validate_raid_name "-bad"; then fail "name beginning with dash accepted"; fi
if validate_raid_name "bad name"; then fail "name containing space accepted"; fi

validate_raid_mountpoint "/data/data-raid0" || fail "valid /data mount rejected"
validate_raid_mountpoint "/mnt/storage/raid1" || fail "valid /mnt mount rejected"
if validate_raid_mountpoint "/home/user/data"; then fail "unsafe mount root accepted"; fi
if validate_raid_mountpoint "/data/../etc"; then fail "parent traversal accepted"; fi
if validate_raid_mountpoint "/data//raid"; then fail "double slash accepted"; fi

(
    get_system_backing_disks() { echo "/dev/nvme0n1"; }
    lsblk() { echo "disk 0 0"; }
    disk_has_mounted_children() { return 1; }
    disk_has_active_storage_stack() { return 1; }
    disk_is_lvm_pv() { return 1; }

    if disk_is_raid_candidate "/dev/nvme0n1"; then
        fail "system backing disk accepted as RAID candidate"
    fi
    disk_is_raid_candidate "/dev/nvme1n1" || fail "safe data disk rejected"
)

# 错误的最终确认短语必须在任何 wipefs/mdadm 调用之前终止。
(
    get_system_backing_disks() { echo "/dev/system"; }
    list_raid_candidate_disks() { printf '%s\n' /dev/data-a /dev/data-b; }
    disk_is_raid_candidate() { return 0; }
    show_disk_identity() { :; }
    show_disk_signatures() { :; }
    confirm_action() { return 0; }
    lsblk() {
        if [[ "$*" == *"-dnbo SIZE"* ]]; then
            echo 1000000000
        fi
    }
    wipefs() { fail "wipefs called before exact confirmation phrase"; }
    mdadm() { fail "mdadm called before exact confirmation phrase"; }

    if printf '1 2\n\nWRONG\n' | create_data_raid 0 >/dev/null 2>&1; then
        fail "RAID creation accepted an incorrect final confirmation phrase"
    fi
)

# 如果无法识别系统承载盘，必须 fail closed，不进入候选盘选择。
(
    get_system_backing_disks() { :; }
    list_raid_candidate_disks() { fail "candidate enumeration ran without protected system disk"; }
    if create_data_raid 1 </dev/null >/dev/null 2>&1; then
        fail "RAID creation continued without identifying the system disk"
    fi
)

grep -Fq '6. RAID Management' "$GPU_MANAGER" || fail "RAID main menu entry missing"
grep -Eq '^[[:space:]]*6\)' "$GPU_MANAGER" || fail "RAID main menu case missing"
grep -Eq '^[[:space:]]*7\)' "$GPU_MANAGER" || fail "uninstall menu case missing"
grep -Fq '创建数据盘 RAID0/1/5/6/10' "$GPU_MANAGER" || fail "multi-level RAID menu missing"
grep -Fq '查看同步/恢复实时进度' "$GPU_MANAGER" || fail "RAID progress menu missing"

echo "PASS: RAID helper tests"
