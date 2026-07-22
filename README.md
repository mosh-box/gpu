# GPU Manager

Ubuntu GPU 驱动、Secure Boot/MOK、TPM 与数据盘 RAID 管理工具。

## 安装

```bash
sudo bash install.sh
sudo gpu-manager
```

## RAID 存储管理

主菜单选择 `6. RAID Management` 后可以：

1. 查看磁盘、挂载点和现有 MD RAID 状态。
2. 通过交互式向导，从未挂载的非系统磁盘创建 RAID0、RAID1、RAID5、RAID6 或 RAID10。
3. 选择现有 MD 阵列，实时查看同步、恢复、重塑、检查或修复进度。
4. 查看系统盘 RAID1迁移指引并生成只读检测报告。

支持的磁盘数量：

- RAID0：至少 2 块，无容错。
- RAID1：至少 2 块，全部成员保存镜像。
- RAID5：至少 3 块，可容忍 1 块盘故障。
- RAID6：至少 4 块，可容忍 2 块盘故障。
- RAID10：至少 4 块且必须是偶数，使用 `near=2` 布局。

创建数据 RAID 时，工具会显示设备路径、容量、型号、序列号和 WWN，并执行以下保护：

- 承载 `/`、`/boot`、`/boot/efi` 的物理磁盘永远不可选。
- 已挂载磁盘、活动 LVM/LUKS/RAID 成员和可移动磁盘不可选。
- 清盘前重新检查磁盘状态，避免选择后设备状态发生变化。
- 检查所选磁盘数量是否符合 RAID 级别要求，并提示磁盘容量差异造成的浪费或性能影响。
- 需要先输入 `yes`，再输入精确确认短语，例如 `ERASE RAID5`。
- 阵列创建后可选择保持未格式化，或格式化为 ext4 并挂载到 `/data/`、`/mnt/` 下。
- 自动将阵列 UUID 写入 `mdadm.conf`，并使用文件系统 UUID 写入 `fstab`。
- RAID1/5/6/10 创建后可以立即进入终端进度界面；也可稍后从菜单进入。界面显示成员健康、动作、进度条、百分比、速度和预计剩余时间，按 `q` 只退出界面，不会停止后台同步。

> RAID0 没有冗余，任意成员盘损坏都会导致整个阵列数据丢失。RAID1/5/6/10 也不能替代独立备份。

## 系统盘 RAID1边界

工具不会把正在运行的系统盘直接当作普通数据盘清空并创建 RAID。系统盘迁移需要先建立降级阵列、复制系统、配置 EFI/GRUB，并在新启动链路验证成功后才能处理原系统盘。

菜单中的系统盘 RAID1功能只提供迁移指引和只读检测报告，报告默认保存到：

```text
/var/log/gpu-manager-raid-audit-YYYYMMDD-HHMMSS.log
```

## 查看版本与帮助

```bash
gpu-manager --version
gpu-manager --help
```
