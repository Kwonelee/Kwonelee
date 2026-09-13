#!/bin/bash
# =========================================================
# XX-OES-TOOLBOX 维护工具箱 v1.1.27
# aminsire@qq.com
# =========================================================

SCRIPT_URL="https://us1.vvvvvv.de5.net/sh/xx-oes-toolbox.sh"
EMMC_BOOT_DEV="/dev/mmcblk1p1"
EMMC_SYS_DEV="/dev/mmcblk1p2"
ENV_FILE="/boot/fnEnv.txt"
VERSION="v1.1.27"

DTB_LIST=(
    "OES Plus (A311D) - 极客满血修复版 (开启NPU)|https://us1.vvvvvv.de5.net/sh/oes-dtb/meson-g12b-s922x-oes-plus-00050000-a311d-npu.dtb|meson-g12b-s922x-oes-plus-00050000.dtb"
    "OES Plus (A311D) - 官方默认原版|https://us1.vvvvvv.de5.net/sh/oes-dtb/meson-g12b-s922x-oes-plus-00050000.dtb|meson-g12b-s922x-oes-plus-00050000.dtb"
    "OES Plus (S922X) - 官方默认原版|https://us1.vvvvvv.de5.net/sh/oes-dtb/meson-g12b-s922x-oes-plus-00050000.dtb|meson-g12b-s922x-oes-plus-00050000.dtb"
    "OES (A311D) - 官方默认原版|https://us1.vvvvvv.de5.net/sh/oes-dtb/meson-g12b-a311d-oes-00050000.dtb|meson-g12b-a311d-oes-00050000.dtb"
)

if [ "$EUID" -ne 0 ]; then echo -e "\033[31m[错误] 请使用 sudo 或 root 身份运行！\033[0m"; exit 1; fi

ui_select() {
    local prompt="$1"; shift; local options=("$@"); local selected=0; local key=""
    echo -e "\033[36m$prompt\033[0m" >&2
    echo -e "\033[33m(请使用 ↑ / ↓ 键移动光标，回车键 确认)\033[0m" >&2
    while true; do
        for i in "${!options[@]}"; do
            if [ $i -eq $selected ]; then echo -e "\033[K\033[32m  ➜ \033[7m ${options[$i]} \033[0m" >&2
            else echo -e "\033[K    ${options[$i]}" >&2; fi
        done
        read -rsn1 key
        case "$key" in
            $'\x1b') read -rsn2 -t 0.1 seq
                if [[ "$seq" == "[A" ]]; then ((selected > 0)) && ((selected--))
                elif [[ "$seq" == "[B" ]]; then ((selected < ${#options[@]} - 1)) && ((selected++)); fi ;;
            "") echo "$selected"; return ;;
        esac
        echo -en "\033[${#options[@]}A" >&2
    done
}

ui_confirm() {
    local opts=("⛔ 取消并返回" "⚠️ 确认执行 (不可逆!)")
    local sel=$(ui_select "$1" "${opts[@]}")
    if [ "$sel" -eq 1 ]; then return 0; else return 1; fi
}

check_deps() {
    local pkgs_to_install=()
    for pkg in "$@"; do
        local cmd="$pkg"
        [ "$pkg" == "dosfstools" ] && cmd="mkfs.vfat"; [ "$pkg" == "btrfs-progs" ] && cmd="mkfs.btrfs"
        [ "$pkg" == "smartmontools" ] && cmd="smartctl"; [ "$pkg" == "e2fsprogs" ] && cmd="resize2fs"
        if ! command -v "$cmd" &> /dev/null; then pkgs_to_install+=("$pkg"); fi
    done
    if [ ${#pkgs_to_install[@]} -gt 0 ]; then
        echo -e "\n\033[33m[需要安装扩展包]: ${pkgs_to_install[*]}\033[0m"
        if ui_confirm "是否允许自动下载并安装？"; then apt update -y -q && apt install -y -q "${pkgs_to_install[@]}"
        else return 1; fi
    fi; return 0
}

# --- [ V1.1.27 优化：物理级硬件探测 ] ---
detect_hardware() {
    HW_MODEL=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')
    REAL_CPU="未知 SoC"
    
    # 策略 1：去底层 dmesg 抓物理探针 (最准确)
    local phys_cpu=$(dmesg 2>/dev/null | grep -iE "soc0: Amlogic Meson" | head -n 1)
    
    # 策略 2：去 sysfs 读硅片微码 (避免 dmesg 被冲刷掉)
    if [ -z "$phys_cpu" ] && [ -f "/sys/devices/soc0/soc_id" ]; then
        phys_cpu=$(cat /sys/devices/soc0/soc_id 2>/dev/null)
    fi

    if [[ "$phys_cpu" == *"A311D"* ]]; then
        REAL_CPU="A311D (支持 NPU)"
    elif [[ "$phys_cpu" == *"S922X"* ]]; then
        REAL_CPU="S922X (无 NPU)"
    else
        # 策略 3：如果物理侦测均失败，去读伪装的设备树 (DTB) 兜底
        HW_COMPAT=$(cat /sys/firmware/devicetree/base/compatible 2>/dev/null | tr -d '\0')
        if [[ "$HW_COMPAT" == *"a311d"* ]]; then REAL_CPU="A311D (DTB推测)"
        elif [[ "$HW_COMPAT" == *"s922x"* ]]; then REAL_CPU="S922X (DTB推测)"
        fi
    fi
}

scan_os_partitions() {
    OS_PARTS=(); OS_PARTS_RAW=()
    while read -r part size fstype mountpoint; do
        [ -z "$part" ] && continue; local is_os=0
        if [ -n "$mountpoint" ] && [ "$mountpoint" != "/" ]; then [ -f "$mountpoint/etc/fstab" ] && is_os=1
        elif [ "$mountpoint" == "/" ]; then is_os=1
        else
            mnt_dir="/tmp/scan_$(basename $part)"; mkdir -p "$mnt_dir"
            if mount -o ro -t "$fstype" "$part" "$mnt_dir" 2>/dev/null; then
                [ -f "$mnt_dir/etc/fstab" ] && is_os=1; umount "$mnt_dir" 2>/dev/null
            fi; rm -rf "$mnt_dir"
        fi
        if [ "$is_os" -eq 1 ]; then
            local tag=""
            [ "$part" == "$EMMC_SYS_DEV" ] && tag="[内置 eMMC 备用区]"
            [ "$mountpoint" == "/" ] && tag="$tag [当前运行中]"
            OS_PARTS+=("$part ($size, $fstype) $tag"); OS_PARTS_RAW+=("$part")
        fi
    done < <(lsblk -ln -p -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -E "btrfs|ext4")
}

scan_fs_partitions() {
    FS_PARTS=(); FS_PARTS_RAW=()
    while read -r part size fstype; do
        [ -z "$part" ] && continue; local tag=""
        [ "$part" == "$EMMC_SYS_DEV" ] && tag="[内置 eMMC 系统区]"
        FS_PARTS+=("$part ($size, $fstype) $tag"); FS_PARTS_RAW+=("$part")
    done < <(lsblk -ln -p -o NAME,SIZE,FSTYPE | grep -E "btrfs|ext4|vfat")
}

switch_boot() {
    echo -e "\n\033[36m>>> 正在深度扫描可用系统分区...\033[0m"
    scan_os_partitions
    local sel=$(ui_select "请选择要设为【下一次开机启动】的分区：" "${OS_PARTS[@]}" "✨ 手动强制输入路径 (God Mode)" "返回")
    if [ "$sel" -eq ${#OS_PARTS[@]} ]; then
        read -p "请输入绝对路径 (如 /dev/sda1): " TARGET_DEV
        if [ ! -b "$TARGET_DEV" ]; then echo -e "\033[31m无效路径！\033[0m"; sleep 2; return; fi
    elif [ "$sel" -eq $(( ${#OS_PARTS[@]} + 1 )) ]; then return
    else TARGET_DEV="${OS_PARTS_RAW[$sel]}"; fi
    
    ROOTWAIT="extraargs=rootwait"
    [ "$TARGET_DEV" == "$EMMC_SYS_DEV" ] && ROOTWAIT=""
    TARGET_PARTUUID=$(blkid -s PARTUUID -o value $TARGET_DEV)
    TARGET_UUID=$(blkid -s UUID -o value $TARGET_DEV)
    EMMC_BOOT_UUID=$(blkid -s UUID -o value $EMMC_BOOT_DEV)

    # --- [ 核心优化：智能防掉线，自动修补孤儿 /boot ] ---
    local temp_boot_mounted=0
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "\033[33m[警告] 系统 /boot 处于孤儿状态，正在强行搭接物理引导区进行施救...\033[0m"
        mount "$EMMC_BOOT_DEV" /boot 2>/dev/null
        if [ -f "$ENV_FILE" ]; then
            temp_boot_mounted=1
            echo -e "\033[32m[成功] 物理引导区已强行接通，路标修正继续。\033[0m"
        else
            echo -e "\033[31m[致命错误] eMMC 引导区严重损毁或格式错误，无法挂载 /boot，修复中止！\033[0m"
            read -p ""; return
        fi
    fi

    echo ">>> 修改引导路标..."
    cp $ENV_FILE ${ENV_FILE}.bak
    sed -i '/rootdev=/d' $ENV_FILE; sed -i '/extraargs=rootwait/d' $ENV_FILE
    echo "rootdev=PARTUUID=$TARGET_PARTUUID" >> $ENV_FILE
    [ -n "$ROOTWAIT" ] && echo "$ROOTWAIT" >> $ENV_FILE

    echo ">>> 修正目标系统挂载表..."
    mkdir -p /tmp/target_fstab_mount
    mount $TARGET_DEV /tmp/target_fstab_mount
    sed -i -E "s|UUID=[a-zA-Z0-9-]+(\s+/\s+btrfs)|UUID=$TARGET_UUID\1|g" /tmp/target_fstab_mount/etc/fstab
    sed -i -E "s|UUID=[a-zA-Z0-9-]+(\s+/boot\s+vfat)|UUID=$EMMC_BOOT_UUID\1|g" /tmp/target_fstab_mount/etc/fstab
    umount /tmp/target_fstab_mount
    
    # 善后孤儿挂载
    if [ "$temp_boot_mounted" -eq 1 ]; then umount /boot 2>/dev/null; fi
    
    systemctl daemon-reload >/dev/null 2>&1
    echo -e "\033[32m[成功] 切换与引导修复完成！重启生效。\033[0m"; read -p "按回车键继续..."
}

update_dtb() {
    check_deps "wget" || return
    local opts=(); for item in "${DTB_LIST[@]}"; do opts+=("$(echo "$item" | awk -F'|' '{print $1}')"); done
    local sel=$(ui_select "请选择要配置的 DTB 文件：" "${opts[@]}" "返回主菜单")
    [ "$sel" -eq ${#DTB_LIST[@]} ] && return
    DOWN_URL=$(echo "${DTB_LIST[$sel]}" | awk -F'|' '{print $2}')
    TARGET_FILENAME=$(echo "${DTB_LIST[$sel]}" | awk -F'|' '{print $3}')
    DTB_TARGET_PATH="/boot/dtb/amlogic/$TARGET_FILENAME"
    [ -f "$DTB_TARGET_PATH" ] && cp $DTB_TARGET_PATH ${DTB_TARGET_PATH}.bak_$(date +%s)
    echo -e "\n>>> 下载中: $DOWN_URL"; wget -qO /tmp/new.dtb $DOWN_URL
    if [ $? -eq 0 ]; then mv /tmp/new.dtb $DTB_TARGET_PATH; chmod 755 $DTB_TARGET_PATH; echo -e "\033[32m[成功] DTB 已写入\033[0m"
    else echo -e "\033[31m[错误] 下载失败\033[0m"; fi; read -p "按回车键继续..."
}

partition_disk() {
    check_deps "parted" "dosfstools" "btrfs-progs" || return

    DISK_OPTS=(); DISK_RAW=()
    while read -r name size model; do
        [ -z "$name" ] && continue
        DISK_OPTS+=("$name ($size) - $model"); DISK_RAW+=("$name")
    done < <(lsblk -d -ln -p -o NAME,SIZE,MODEL | grep -v "loop" | grep -v "boot")

    if [ ${#DISK_OPTS[@]} -eq 0 ]; then echo -e "\033[31m未检测到可用物理磁盘\033[0m"; sleep 2; return; fi
    local disk_sel=$(ui_select "请选择要【全盘清空并分区】的物理盘：" "${DISK_OPTS[@]}" "返回")
    [ "$disk_sel" -eq ${#DISK_RAW[@]} ] && return; TARGET_DISK="${DISK_RAW[$disk_sel]}"

    CURRENT_ROOT=$(findmnt -n -o SOURCE /)
    if [[ "$CURRENT_ROOT" == "$TARGET_DISK"* ]]; then
        echo -e "\n\033[31m[阻断] 系统正运行在目标盘，禁止操作！\033[0m"; read -p ""; return
    fi

    local is_emmc=0
    if [[ "$TARGET_DISK" == *"/dev/mmcblk"* ]]; then is_emmc=1; fi

    local mode_sel
    local emmc_size_sel=0
    if [ "$is_emmc" -eq 1 ]; then
        echo -e "\n\033[36m>>> 检测到 eMMC，已启用 Amlogic 底核保护机制。\033[0m"
        local emmc_opts=(
            "16GB" 
            "29GB (官方默认标准，推荐)" 
            "32GB" 
            "榨干全部容量 (单一系统区)"
            "返回"
        )
        emmc_size_sel=$(ui_select "请为 eMMC [系统区] 分配容量 (剩余将自动化为数据存储区) :" "${emmc_opts[@]}")
        [ "$emmc_size_sel" -eq 4 ] && return
        mode_sel=2
    else
        mode_sel=$(ui_select "请选择外置磁盘的分区模式：" "两分区 (系统区 + 数据区) [推荐外挂盘]" "三分区 (525M引导 + 系统区 + 数据区) [推荐主引导盘]" "返回")
        [ "$mode_sel" -eq 2 ] && return
    fi

    local SYS_SIZE
    if [ "$mode_sel" -ne 2 ]; then
        local size_vals=(16 32 64 128)
        local size_sel=$(ui_select "请为 外置盘系统区 分配容量：" "16GB" "32GB (推荐)" "64GB" "128GB" "返回")
        [ "$size_sel" -eq 4 ] && return; SYS_SIZE=${size_vals[$size_sel]}
    fi

    if ! ui_confirm "彻底清空 $TARGET_DISK 所有数据，是否继续？"; then return; fi
    echo -e "\n>>> 解除锁定并重置表..."
    for part in $(lsblk -ln -p -o NAME "$TARGET_DISK" | grep -v "^$TARGET_DISK$"); do umount -qf "$part" 2>/dev/null; swapoff "$part" 2>/dev/null; done

    if [[ "$TARGET_DISK" == *"nvme"* ]]; then P_PREFIX="${TARGET_DISK}p"; else P_PREFIX="${TARGET_DISK}"; fi
    if [[ "$is_emmc" -eq 1 ]]; then P_PREFIX="${TARGET_DISK}p"; fi

    if [ "$mode_sel" -eq 2 ]; then
        echo ">>> [底核操作] 备份 Amlogic U-Boot (4MB)..."
        dd if="$TARGET_DISK" of=/tmp/u-boot-backup.img bs=1M count=4 2>/dev/null
        
        echo ">>> 重建 msdos (MBR) 结构，执行智能分割..."
        parted -s "$TARGET_DISK" mklabel msdos
        parted -s "$TARGET_DISK" mkpart primary fat32 700MiB 1212MiB
        
        if [ "$emmc_size_sel" -eq 3 ]; then
            parted -s "$TARGET_DISK" mkpart primary btrfs 1213MiB 100%
        else
            local sys_gb=29
            [ "$emmc_size_sel" -eq 0 ] && sys_gb=16
            [ "$emmc_size_sel" -eq 1 ] && sys_gb=29
            [ "$emmc_size_sel" -eq 2 ] && sys_gb=32
            
            local end_root=$(( 1213 + sys_gb * 1024 ))
            parted -s "$TARGET_DISK" mkpart primary btrfs 1213MiB ${end_root}MiB
            parted -s "$TARGET_DISK" mkpart primary btrfs ${end_root}MiB 100%
        fi
        
        echo ">>> [底核操作] 缝合复原 U-Boot..."
        dd if=/tmp/u-boot-backup.img of="$TARGET_DISK" conv=fsync bs=1 count=442 2>/dev/null
        dd if=/tmp/u-boot-backup.img of="$TARGET_DISK" conv=fsync bs=512 skip=1 seek=1 2>/dev/null
        
        partprobe "$TARGET_DISK" 2>/dev/null; udevadm settle 2>/dev/null; sleep 2
        echo ">>> 格式化 eMMC 物理分区 (抗干扰模式)..."
        mkfs.vfat -F 16 -n "BOOT_EMMC" ${P_PREFIX}1
        mkfs.btrfs -K -f -L ROOT_EMMC ${P_PREFIX}2
        if [ "$emmc_size_sel" -ne 3 ]; then mkfs.btrfs -K -f -L DATA_EMMC ${P_PREFIX}3; fi
        rm /tmp/u-boot-backup.img
        
    else
        wipefs -a -f "$TARGET_DISK" 2>/dev/null; sleep 1
        parted -s $TARGET_DISK mklabel gpt; partprobe "$TARGET_DISK" 2>/dev/null; udevadm settle 2>/dev/null; sleep 3

        if [ "$mode_sel" -eq 0 ]; then
            parted -s $TARGET_DISK mkpart primary btrfs 1MiB ${SYS_SIZE}GiB
            parted -s $TARGET_DISK mkpart primary btrfs ${SYS_SIZE}GiB 100%
            partprobe "$TARGET_DISK" 2>/dev/null; udevadm settle 2>/dev/null; sleep 2
            mkfs.btrfs -K -f ${P_PREFIX}1; mkfs.btrfs -K -f ${P_PREFIX}2
        elif [ "$mode_sel" -eq 1 ]; then
            END_SYS=$(( 525 + SYS_SIZE * 1024 ))
            parted -s $TARGET_DISK mkpart primary fat32 1MiB 525MiB
            parted -s $TARGET_DISK mkpart primary btrfs 525MiB ${END_SYS}MiB
            parted -s $TARGET_DISK mkpart primary btrfs ${END_SYS}MiB 100%
            partprobe "$TARGET_DISK" 2>/dev/null; udevadm settle 2>/dev/null; sleep 2
            mkfs.vfat -F 32 ${P_PREFIX}1; mkfs.btrfs -K -f ${P_PREFIX}2; mkfs.btrfs -K -f ${P_PREFIX}3
        fi
    fi
    udevadm trigger; sleep 1; echo -e "\033[32m[成功] 分区及抗干扰文件系统重建完毕！\033[0m"; read -p "按回车键继续..."
}

clone_system() {
    check_deps "rsync" || return
    
    # 1. 交互式选择源分区与目标分区
    scan_os_partitions
    local src_sel=$(ui_select "请选择【源】系统分区 :" "${OS_PARTS[@]}" "✨ 手动输入路径" "返回")
    if [ "$src_sel" -eq ${#OS_PARTS[@]} ]; then read -p "输入源路径: " SRC_DEV
    elif [ "$src_sel" -eq $(( ${#OS_PARTS[@]} + 1 )) ]; then return
    else SRC_DEV="${OS_PARTS_RAW[$src_sel]}"; fi

    scan_fs_partitions
    local dst_sel=$(ui_select "请选择【目标】分区 :" "${FS_PARTS[@]}" "✨ 手动输入路径" "返回")
    if [ "$dst_sel" -eq ${#FS_PARTS[@]} ]; then read -p "输入目标路径: " DST_DEV
    elif [ "$dst_sel" -eq $(( ${#FS_PARTS[@]} + 1 )) ]; then return
    else DST_DEV="${FS_PARTS_RAW[$dst_sel]}"; fi

    # 2. 基础安全拦截
    if [ "$SRC_DEV" == "$DST_DEV" ]; then echo -e "\033[31m源和目标不能相同\033[0m"; sleep 2; return; fi
    CURRENT_ROOT=$(findmnt -n -o SOURCE /)
    if [[ "$DST_DEV" == "$CURRENT_ROOT" ]]; then echo -e "\033[31m不能覆盖自己！\033[0m"; read -p ""; return; fi
    if ! ui_confirm "擦除 $DST_DEV 并克隆，是否继续？"; then return; fi

    # 3. 强制解除占用并重置目标分区
    echo -e "\n>>> 正在强制刷新并准备目标分区..."
    umount -qf "$DST_DEV" 2>/dev/null
    
    echo ">>> 正在执行强制格式化 (抹除旧残留)..."
    mkfs.btrfs -K -f "$DST_DEV" >/dev/null 2>&1
    
    # 强制内核重读分区表并扫描，防止 failed to recognize exfat type 等灵异报错
    partprobe "$DST_DEV" 2>/dev/null
    btrfs device scan 2>/dev/null
    sync && sleep 2

    # 4. 挂载与 Btrfs 透明压缩配置
    mkdir -p /tmp/clone_src /tmp/clone_dst
    mount "$SRC_DEV" /tmp/clone_src
    
    # 【核心注入】：执行挂载时直接开启透明压缩 zstd:1
    mount -t btrfs -o compress=zstd:1 "$DST_DEV" /tmp/clone_dst
    if [ $? -ne 0 ]; then
        echo -e "\033[31m[错误] 无法挂载目标分区 $DST_DEV\033[0m"
        umount /tmp/clone_src 2>/dev/null
        read -p "按回车返回..." temp; return
    fi

    # 设置 Btrfs 目录级压缩属性，确保写入文件被压缩
    btrfs property set /tmp/clone_dst compression zstd:1 2>/dev/null

    # 5. 执行高阶 Rsync 全量克隆
    echo ">>> Rsync 全量克隆中 (开启透明压缩，拦截 vol 递归黑洞)..."
    # 【核心注入】：增加 -x(不跨文件系统) -H(硬链接) -A(ACL) -X(扩展属性) -S(稀疏文件) --info=progress2 --numeric-ids
    rsync -axHAXS --info=progress2 --numeric-ids --delete \
        --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/etc/fstab","/vol00/*","/vol1/*","/lost+found"} \
        /tmp/clone_src/ /tmp/clone_dst/
    
    local res=$?
    
    # 6. 容错判断与后期收尾工作
    # 【核心注入】：允许退出码 0(完美), 23(部分文件属性报错), 24(文件在传输时消失)
    if [ $res -eq 0 ] || [ $res -eq 23 ] || [ $res -eq 24 ]; then
        sync 
        mkdir -p /tmp/clone_dst/{dev,proc,sys,run,tmp,mnt,media}
        
        # 继承原版的路标修复逻辑 (修改 fstab UUID)
        DST_UUID=$(blkid -s UUID -o value "$DST_DEV")
        EMMC_BOOT_UUID=$(blkid -s UUID -o value "$EMMC_BOOT_DEV")
        cp /tmp/clone_src/etc/fstab /tmp/clone_dst/etc/fstab
        sed -i -E "s|UUID=[a-zA-Z0-9-]+(\s+/\s+btrfs)|UUID=$DST_UUID\1|g" /tmp/clone_dst/etc/fstab
        sed -i -E "s|UUID=[a-zA-Z0-9-]+(\s+/boot\s+vfat)|UUID=$EMMC_BOOT_UUID\1|g" /tmp/clone_dst/etc/fstab
        
        # 7. 交互判断：是否进一步优化 (Btrfs Defrag)
        echo -e "\n\033[33m>>> 是否执行进一步存储优化(收缩空间)? [y/N] (10秒后自动跳过):\033[0m"
        read -t 10 -n 1 opt_choice
        echo ""
        
        if [[ "$opt_choice" == "y" || "$opt_choice" == "Y" ]]; then
            echo -e "\033[36m正在执行最终存储优化 (深度碎片整理并压缩)... 这可能需要几分钟。\033[0m"
            btrfs filesystem defragment -r -czstd /tmp/clone_dst >/dev/null 2>&1
            echo -e "\033[32m存储优化已完成！\033[0m"
        else
            echo -e "\033[36m已跳过深度优化。由于已开启透明压缩，当前占用已处于较低水平。\033[0m"
        fi
        
        # 原版的异步垃圾回收
        echo ">>> [系统健康] 唤醒异步垃圾回收(TRIM)，保护固态寿命..."
        fstrim -v /tmp/clone_dst > /dev/null 2>&1
        
        # 收尾
        umount /tmp/clone_src /tmp/clone_dst 2>/dev/null
        systemctl daemon-reload >/dev/null 2>&1
        echo -e "\033[32m[成功] 系统克隆完成！(注：已自动忽略非致命的临时文件报错)\033[0m"
        read -p "按回车键继续..." temp
    else
        echo -e "\033[31m[错误] 克隆失败！rsync 错误码: $res\033[0m"
        umount /tmp/clone_src /tmp/clone_dst 2>/dev/null
        read -p "按回车键继续..." temp
    fi
}
clone_system_bak() {
    check_deps "rsync" || return
    scan_os_partitions
    local src_sel=$(ui_select "请选择【源】系统分区 :" "${OS_PARTS[@]}" "✨ 手动输入路径" "返回")
    if [ "$src_sel" -eq ${#OS_PARTS[@]} ]; then read -p "输入源路径: " SRC_DEV
    elif [ "$src_sel" -eq $(( ${#OS_PARTS[@]} + 1 )) ]; then return
    else SRC_DEV="${OS_PARTS_RAW[$src_sel]}"; fi

    scan_fs_partitions
    local dst_sel=$(ui_select "请选择【目标】分区 :" "${FS_PARTS[@]}" "✨ 手动输入路径" "返回")
    if [ "$dst_sel" -eq ${#FS_PARTS[@]} ]; then read -p "输入目标路径: " DST_DEV
    elif [ "$dst_sel" -eq $(( ${#FS_PARTS[@]} + 1 )) ]; then return
    else DST_DEV="${FS_PARTS_RAW[$dst_sel]}"; fi

    if [ "$SRC_DEV" == "$DST_DEV" ]; then echo -e "\033[31m源和目标不能相同\033[0m"; sleep 2; return; fi
    CURRENT_ROOT=$(findmnt -n -o SOURCE /)
    if [[ "$DST_DEV" == "$CURRENT_ROOT" ]]; then echo -e "\033[31m不能覆盖自己！\033[0m"; read -p ""; return; fi

    if ! ui_confirm "擦除 $DST_DEV 并克隆，是否继续？"; then return; fi

    echo -e "\n>>> 格式化目标分区 $DST_DEV..."
    umount -qf "$DST_DEV" 2>/dev/null; mkfs.btrfs -K -f $DST_DEV
    mkdir -p /tmp/clone_src /tmp/clone_dst
    mount $SRC_DEV /tmp/clone_src; mount $DST_DEV /tmp/clone_dst
    
    echo ">>> Rsync 全量克隆中 (已拦截 vol 递归黑洞)..."
    rsync -aAXv --delete --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/etc/fstab","/vol00/*","/vol1/*"} /tmp/clone_src/ /tmp/clone_dst/
    mkdir -p /tmp/clone_dst/{dev,proc,sys,run,tmp,mnt,media}
    
    DST_UUID=$(blkid -s UUID -o value $DST_DEV); EMMC_BOOT_UUID=$(blkid -s UUID -o value $EMMC_BOOT_DEV)
    cp /tmp/clone_src/etc/fstab /tmp/clone_dst/etc/fstab
    sed -i -E "s|UUID=[a-zA-Z0-9-]+(\s+/\s+btrfs)|UUID=$DST_UUID\1|g" /tmp/clone_dst/etc/fstab
    sed -i -E "s|UUID=[a-zA-Z0-9-]+(\s+/boot\s+vfat)|UUID=$EMMC_BOOT_UUID\1|g" /tmp/clone_dst/etc/fstab
    
    # --- [ 核心优化：后台安全异步垃圾回收 ] ---
    echo ">>> [系统健康] 唤醒异步垃圾回收(TRIM)，保护固态寿命..."
    fstrim -v /tmp/clone_dst > /dev/null 2>&1
    
    umount /tmp/clone_src && umount /tmp/clone_dst; systemctl daemon-reload >/dev/null 2>&1
    echo -e "\033[32m[成功] 克隆完毕！\033[0m"; read -p "按回车键继续..."
}

ota_sync() {
    check_deps "rsync" || return
    scan_fs_partitions
    local t_sel=$(ui_select "接收同步的【备用系统区】:" "${FS_PARTS[@]}" "返回")
    [ "$t_sel" -eq ${#FS_PARTS[@]} ] && return; DST_DEV="${FS_PARTS_RAW[$t_sel]}"
    if ! ui_confirm "增量同步至 $DST_DEV，是否继续？"; then return; fi
    mkdir -p /tmp/ota_dst; mount $DST_DEV /tmp/ota_dst
    echo ">>> 无损增量同步中..."
    rsync -avP --delete --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/etc/fstab","/etc/network/interfaces","/vol00/*","/vol1/*"} / /tmp/ota_dst/
    mkdir -p /tmp/ota_dst/{dev,proc,sys,run,tmp,mnt,media}
    
    fstrim -v /tmp/ota_dst > /dev/null 2>&1
    
    umount /tmp/ota_dst; echo -e "\033[32m[成功] 同步完毕！\033[0m"; read -p "按回车键继续..."
}

check_health() {
    check_deps "smartmontools" || return
    clear; echo -e "\033[36m================ 🏥 深度体检 ================\033[0m"
    if [ -b "/dev/sda" ]; then
        echo -e "\n\033[33m[1] SATA 固态硬盘 (/dev/sda)\033[0m\n-------------------------------------------------"
        local pass=$(smartctl -H /dev/sda | grep -i "test result" | awk -F': ' '{print $2}')
        [ "$pass" == "PASSED" ] && pass="\033[32m健康 (PASSED)\033[0m" || pass="\033[31m警告 ($pass)\033[0m"
        local hours=$(smartctl -A /dev/sda | awk '/^ *9 / {print $10}'); local days=$(( hours / 24 ))
        local temp=$(smartctl -A /dev/sda | awk '/^194 / {print $10}'); local bad_sec=$(smartctl -A /dev/sda | awk '/^ *5 / {print $10}')
        local lbas=$(smartctl -A /dev/sda | awk '/^241 / {print $10}')
        local health_pct=$(smartctl -A /dev/sda | awk '/Wear_Leveling_Count|SSD_Life_Left|Media_Wearout_Indicator|Remaining_Lifetime_Perc|Percent_Lifetime_Remain|Available_Reservd_Space/ {print $4}' | head -n 1)
        echo -e " • 总体状态 : $pass"
        if [ -n "$health_pct" ]; then
            if [ "$health_pct" -gt 80 ]; then echo -e " • 剩余健康 : \033[32m$health_pct%\033[0m \033[36m(状态极佳)\033[0m"
            elif [ "$health_pct" -gt 30 ]; then echo -e " • 剩余健康 : \033[33m$health_pct%\033[0m \033[33m(正常损耗)\033[0m"
            else echo -e " • 剩余健康 : \033[31m$health_pct%\033[0m \033[31m(预警!)\033[0m"; fi
        fi
        [ -n "$hours" ] && echo -e " • 通电时间 : $hours 小时 \033[36m(约 $days 天)\033[0m"
        [ -n "$temp" ] && echo -e " • 当前温度 : $temp °C"
        if [ -n "$bad_sec" ]; then
            if [ "$bad_sec" -eq 0 ]; then echo -e " • 坏块数量 : \033[32m0 个 (完好)\033[0m"
            else echo -e " • 坏块数量 : \033[31m$bad_sec 个 (警告)\033[0m"; fi
        fi
        if [ -n "$lbas" ]; then
            local tbw=$(awk "BEGIN {printf \"%.2f\", $lbas * 512 / 1000000000000}"); echo -e " • 累计写入 : \033[36m约 $tbw TB\033[0m"
        fi
    fi
    echo -e "\n\033[33m[2] 内置 eMMC 闪存 (/dev/mmcblk1)\033[0m\n-------------------------------------------------"
    if [ -e "/sys/class/block/mmcblk1/device/life_time" ]; then
        local life_raw=$(cat /sys/class/block/mmcblk1/device/life_time); local type_a=$(echo "$life_raw" | awk '{print $1}')
        local dec_a=$((16#${type_a#0x}))
        if [ "$dec_a" -eq 0 ]; then echo -e " • 寿命消耗 : \033[36m未定义 (0x00)\033[0m"
        elif [ "$dec_a" -eq 11 ]; then echo -e " • 寿命消耗 : \033[31m已损坏 (>100%)\033[0m"
        else
            local pct_start=$(( (dec_a - 1) * 10 )); local pct_end=$(( dec_a * 10 )); local remain_start=$(( 100 - pct_end )); local remain_end=$(( 100 - pct_start ))
            if [ "$dec_a" -le 4 ]; then echo -e " • 剩余寿命 : \033[32m约 $remain_start% ~ $remain_end%\033[0m"
            elif [ "$dec_a" -le 8 ]; then echo -e " • 剩余寿命 : \033[33m约 $remain_start% ~ $remain_end%\033[0m"
            else echo -e " • 剩余寿命 : \033[31m约 $remain_start% ~ $remain_end%\033[0m (预警!)"
            fi
        fi
    fi
    echo ""; read -p "按回车键返回主菜单..."
}

flash_img() {
    check_deps "gzip" "losetup" "e2fsprogs" || return
    
    local opts=(); local raw=()
    while read -r img; do opts+=("$img"); raw+=("$img"); done < <(find . /vol1/1000/ -maxdepth 2 -type f \( -name "*.img" -o -name "*.img.gz" \) 2>/dev/null)
    opts+=("✨ 手动强制输入路径 (God Mode)")
    opts+=("取消返回")
    
    local img_sel=$(ui_select "请选择要刷入的镜像包 (支持 .img / .img.gz)：" "${opts[@]}")
    if [ "$img_sel" -eq ${#raw[@]} ]; then
        read -p "请输入绝对路径: " IMG_FILE
        if [ ! -f "$IMG_FILE" ]; then echo -e "\033[31m文件不存在！\033[0m"; sleep 2; return; fi
    elif [ "$img_sel" -eq $(( ${#raw[@]} + 1 )) ]; then return
    else IMG_FILE="${raw[$img_sel]}"; fi

    if [[ "$IMG_FILE" == *.gz ]]; then
        echo -e "\n>>> 检测到 .img.gz，正在解压..."
        local new_img="${IMG_FILE%.gz}"
        if [ ! -f "$new_img" ]; then gzip -d -k "$IMG_FILE" || { echo -e "\033[31m解压失败\033[0m"; read -p ""; return; }; fi
        IMG_FILE="$new_img"
    fi

    local f_mode=$(ui_select "请选择刷写模式：" "1. 💥 极速全盘盲刷 (覆盖整块物理盘，破坏极强)" "2. 🚀 高阶分区分裂 (剥离镜像分区，定向注入现有分区)" "取消")
    [ "$f_mode" -eq 2 ] && return

    if [ "$f_mode" -eq 0 ]; then
        DISK_OPTS=(); DISK_RAW=()
        while read -r name size model; do
            [ -z "$name" ] && continue; [[ "$name" == *"/dev/mmcblk"* ]] && continue 
            DISK_OPTS+=("$name ($size) - $model"); DISK_RAW+=("$name")
        done < <(lsblk -d -ln -p -o NAME,SIZE,MODEL | grep -v "loop")
        DISK_OPTS+=("取消返回")
        local d_sel=$(ui_select "请选择写入的物理磁盘 (极度危险)：" "${DISK_OPTS[@]}")
        [ "$d_sel" -eq ${#DISK_RAW[@]} ] && return; TARGET_DISK="${DISK_RAW[$d_sel]}"

        if ! ui_confirm "抹除 $TARGET_DISK 所有数据，是否继续？"; then return; fi
        echo -e "\n>>> 全盘刷写进行中..."
        dd if="$IMG_FILE" of="$TARGET_DISK" bs=4M status=progress
        sync; echo -e "\033[32m[成功] 物理盘全盘写入完成。\033[0m"; read -p "按回车键继续..."

    elif [ "$f_mode" -eq 1 ]; then
        CURRENT_ROOT=$(findmnt -n -o SOURCE /)
        
        echo -e "\n>>> 挂载虚拟磁盘探测镜像结构..."
        LOOP_DEV=$(losetup -fP --show "$IMG_FILE")
        if [ -z "$LOOP_DEV" ]; then echo -e "\033[31m挂载失败。\033[0m"; read -p ""; return; fi
        sleep 1
        
        scan_fs_partitions
        local target1=""
        local target2=""

        if [ -b "${LOOP_DEV}p1" ]; then
            local p1_sel=$(ui_select "【1/2】找到镜像内的 引导区(Partition 1)。请选择目标：" "${FS_PARTS[@]}" "⏩ 跳过此分区")
            [ "$p1_sel" -lt ${#FS_PARTS[@]} ] && target1="${FS_PARTS_RAW[$p1_sel]}"
        fi

        if [ -b "${LOOP_DEV}p2" ]; then
            local p2_sel=$(ui_select "【2/2】找到镜像内的 系统区(Partition 2)。请选择目标：" "${FS_PARTS[@]}" "⏩ 跳过此分区")
            [ "$p2_sel" -lt ${#FS_PARTS[@]} ] && target2="${FS_PARTS_RAW[$p2_sel]}"
        fi

        if [ -z "$target1" ] && [ -z "$target2" ]; then losetup -d "$LOOP_DEV"; return; fi
        
        if [[ "$target1" == "$CURRENT_ROOT" ]] || [[ "$target2" == "$CURRENT_ROOT" ]]; then
            echo -e "\n\033[31m[严重阻断] 目标分区正在运行当前的系统！禁止执行 dd 强制覆盖。\n💡 请先通过菜单 [1] 切换到备用分区启动。\033[0m"
            losetup -d "$LOOP_DEV"; read -p "按回车键返回..." ; return
        fi

        if ! ui_confirm "确定将镜像注入物理分区？目标原有数据将被彻底清除！"; then losetup -d "$LOOP_DEV"; return; fi

        if [ -n "$target1" ]; then
            echo -e "\n>>> 正在注入镜像引导区 -> $target1"
            umount -qf "$target1" 2>/dev/null
            mkdir -p /tmp/img_boot /tmp/real_boot
            mkfs.vfat -F 16 -n "BOOT_EMMC" "$target1" 2>/dev/null
            mount "${LOOP_DEV}p1" /tmp/img_boot
            mount "$target1" /tmp/real_boot
            cp -r /tmp/img_boot/* /tmp/real_boot/ 2>/dev/null; sync
            umount /tmp/img_boot /tmp/real_boot
        fi

        if [ -n "$target2" ]; then
            echo -e "\n>>> 正在注入镜像系统区 -> $target2"
            umount -qf "$target2" 2>/dev/null
            dd if="${LOOP_DEV}p2" of="$target2" bs=4M status=progress; sync
            
            echo -e "\n>>> 触发空间拉伸引擎..."
            local ftype=$(blkid -s TYPE -o value "$target2")
            if [ "$ftype" == "btrfs" ]; then
                mkdir -p /tmp/resize_mnt; mount "$target2" /tmp/resize_mnt
                btrfs filesystem resize max /tmp/resize_mnt; umount /tmp/resize_mnt
            elif [ "$ftype" == "ext4" ]; then
                e2fsck -f -y "$target2"; resize2fs "$target2"
            fi
        fi
        
        losetup -d "$LOOP_DEV"
        echo -e "\n\033[32m[大功告成] 高阶定点注入完毕！\033[0m"
        if ui_confirm "是否立即调用【启动切换】AI修复 UUID 引导路标？(强烈推荐)"; then switch_boot; else read -p "按回车继续..."; fi
    fi
}

update_script() {
    check_deps "wget" || return
    echo -e "\n\033[36m>>> 拉取最新脚本...\033[0m"
    wget -qO /tmp/oes-toolbox.sh $SCRIPT_URL
    if [ $? -eq 0 ]; then cat /tmp/oes-toolbox.sh > "$0"; chmod +x "$0"; echo -e "\033[32m[成功] 热更新完成！\033[0m"; sleep 1; exec "$0"
    else echo -e "\033[31m[错误] 更新失败。\033[0m"; sleep 2; fi
}

detect_hardware
MAIN_MENU=(
    "🔄 切换系统启动"
    "🌳 在线配置 DTB"
    "🪓 磁盘一键灵活分区"
    "💽 系统全量热克隆"
    "🧬 系统OTA 差异热同步"
    "🏥 深度体检 eMMC与SATA 寿命健康度"
    "⚡ 高阶极速线刷"
    "🚀 在线更新本工具箱"
    "❌ 退出"
)

while true; do
    clear
    echo "================================================="
    echo -e "\033[32m     XX-OES-TOOLBOX 维护工具箱 $VERSION \033[0m"
    echo "================================================="
    echo -e " 硬件探测: [\033[36m$HW_MODEL\033[0m] | [\033[36m$REAL_CPU\033[0m]"
    echo " 当前根目录: $(findmnt -n -o SOURCE /)"
    echo "================================================="
    choice=$(ui_select "请选择要执行的操作：" "${MAIN_MENU[@]}")
    case $choice in
        0) switch_boot ;; 1) update_dtb ;; 2) partition_disk ;; 3) clone_system ;; 4) ota_sync ;; 5) check_health ;; 6) flash_img ;; 7) update_script ;; 8) echo "再见！"; exit 0 ;;
    esac
done