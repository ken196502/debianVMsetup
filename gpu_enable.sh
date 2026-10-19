#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# ============================================================
# Debian: 自动检测并启用 GPU（开机加载驱动模块 + 持久化）
# 支持 NVIDIA / AMD / Intel 核显，自动识别硬件
# ============================================================

if [[ "$(id -u)" -ne 0 ]]; then
    echo "错误：请使用 root 运行：sudo bash gpu_enable.sh" >&2
    exit 1
fi

if [[ ! -f /etc/debian_version ]]; then
    echo "错误：此脚本仅面向 Debian。" >&2
    exit 1
fi

# 检测 GPU 厂商
echo "==> 1. 检测 GPU 设备"
if ! command -v lspci >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y pciutils
fi

PCI="$(lspci -nn 2>/dev/null || true)"

has_nvidia=0
has_amd=0
has_intel=0

if echo "$PCI" | grep -qiE 'NVIDIA'; then has_nvidia=1; fi
if echo "$PCI" | grep -qiE 'Advanced Micro Devices|AMD/ATI'; then has_amd=1; fi
if echo "$PCI" | grep -qiE 'Intel Corporation.*(HD Graphics|UHD Graphics|Iris|Arc)'; then has_intel=1; fi

if [[ "$has_nvidia$has_amd$has_intel" == "000" ]]; then
    echo "未检测到受支持的 GPU（NVIDIA/AMD/Intel）。"
    exit 0
fi

echo "检测结果：NVIDIA=$has_nvidia  AMD=$has_amd  Intel=$has_intel"

echo "==> 2. 安装依赖与驱动"
DEBIAN_FRONTEND=noninteractive apt-get update

MODULES_LOAD=""   # 需要开机自动加载的模块

# ---------- NVIDIA ----------
if [[ "$has_nvidia" -eq 1 ]]; then
    echo "-- 配置 NVIDIA --"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        nvidia-driver \
        nvidia-smi \
        nvidia-persistenced || true

    # 让 nvidia 相关模块开机加载
    echo "nvidia"        >> /etc/modules-load.d/gpu.conf
    echo "nvidia-uvm"    >> /etc/modules-load.d/gpu.conf
    echo "nvidia-drm"    >> /etc/modules-load.d/gpu.conf
    echo "nvidia-modeset">> /etc/modules-load.d/gpu.conf

    # 开机启用持久化守护进程（保持 GPU 初始化、避免掉卡）
    if command -v nvidia-persistenced >/dev/null 2>&1; then
        systemctl enable nvidia-persistenced || true
    fi
fi

# ---------- AMD ----------
if [[ "$has_amd" -eq 1 ]]; then
    echo "-- 配置 AMD --"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        firmware-linux-nonfree \
        mesa-utils || true
    echo "amdgpu" >> /etc/modules-load.d/gpu.conf
fi

# ---------- Intel 核显 ----------
if [[ "$has_intel" -eq 1 ]]; then
    echo "-- 配置 Intel 核显 --"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        firmware-linux-nonfree \
        intel-media-va-driver-nonfree \
        mesa-utils || true
    echo "i915" >> /etc/modules-load.d/gpu.conf
fi

# 去重 /etc/modules-load.d/gpu.conf
echo "==> 3. 持久化模块配置"
sort -u -o /etc/modules-load.d/gpu.conf /etc/modules-load.d/gpu.conf

# 生成 modprobe 配置，确保模块可加载
echo "==> 4. 立即加载模块"
systemctl restart systemd-modules-load.service || true

if [[ "$has_nvidia" -eq 1 ]]; then
    modprobe -a nvidia nvidia-uvm nvidia-drm nvidia-modeset 2>/dev/null || true
    systemctl restart nvidia-persistenced 2>/dev/null || true
fi
if [[ "$has_amd" -eq 1 ]]; then
    modprobe amdgpu 2>/dev/null || true
fi
if [[ "$has_intel" -eq 1 ]]; then
    modprobe i915 2>/dev/null || true
fi

echo "==> 5. 验证"
if [[ "$has_nvidia" -eq 1 ]]; then
    echo "--- nvidia-smi ---"
    nvidia-smi || echo "警告：nvidia-smi 不可用，请重启后重试。"
fi
if [[ "$has_amd" -eq 1 ]] || [[ "$has_intel" -eq 1 ]]; then
    echo "--- 内核已加载的 GPU 模块 ---"
    lsmod | grep -E 'amdgpu|i915|nvidia' || true
fi

echo
echo "GPU 启用完成。相关模块已配置为开机自动加载。"
echo "如为新装驱动，建议重启一次以确保彻底生效：sudo reboot"
