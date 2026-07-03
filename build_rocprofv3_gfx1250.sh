#!/bin/bash
# =============================================================================
# build_rocprofv3_gfx1250.sh
#
# 自包含编译脚本：在装有 ROCm 7.12.0 (TheRock / python-wheel 布局) 的容器内，
# 从本仓库源码编译 + 安装 rocprofv3 (rocprofiler-sdk)，目标 GPU = gfx1250。
#
# 本脚本对应的 rocprofiler-sdk 源码 commit 必须与容器内已装的 ROCm 运行时匹配
# (本仓库 pin 在 0208c97b，对应 rocprofv3 1.1.0 / ROCm 7.12.0)，否则 HSA API
# 表结构不一致会导致编译期 static_assert 失败。
#
# 用法（在容器 hyg_fyd1 内，从仓库根目录）：
#   bash build_rocprofv3_gfx1250.sh
#
# 产物：
#   ./rocprofiler-sdk-build/          —— 构建目录
#   $INSTALL_PREFIX/bin/rocprofv3     —— 安装后的可执行文件
# =============================================================================
set -euo pipefail

# ---- 可调参数 ----------------------------------------------------------------
: "${ROCM_PATH:=/opt/rocm}"
: "${INSTALL_PREFIX:=$(pwd)/rocprof-install}"
: "${GPU_TARGETS:=gfx1250}"
: "${JOBS:=$(nproc)}"
# ROCm TheRock wheel 里的真实库/头文件位置（依赖来源）
: "${CORE:=/opt/venv/lib/python3.12/site-packages/_rocm_sdk_core/lib}"
: "${SYSDEPS:=/opt/venv/lib/python3.12/site-packages/_rocm_sdk_devel/lib/rocm_sysdeps}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

echo "=============================================================="
echo " rocprofv3 build for gfx1250"
echo "   REPO_ROOT      = $REPO_ROOT"
echo "   ROCM_PATH      = $ROCM_PATH"
echo "   INSTALL_PREFIX = $INSTALL_PREFIX"
echo "   GPU_TARGETS    = $GPU_TARGETS"
echo "   JOBS           = $JOBS"
echo "=============================================================="

# ---- 1. 安装依赖软件包 -------------------------------------------------------
# 系统包：编译器工具链 + git + pkg-config。ROCm / libelf / libdw / sqlite3 等
# 都由容器内的 ROCm wheel (CORE / SYSDEPS) 提供，无需额外 apt 安装。
echo "== [1/5] 安装依赖 =="
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || true
    apt-get install -y --no-install-recommends \
        git build-essential pkg-config python3 python3-pip ca-certificates || true
fi
# cmake 需 >=3.21（本仓库某些子模块要 3.31+），系统自带的常常过旧 → 用 pip 版。
# ninja 同理。若容器已自带新版 (如 /opt/venv/bin) 则跳过。
if ! cmake --version 2>/dev/null | head -1 | grep -qE '3\.(2[1-9]|[3-9][0-9])'; then
    python3 -m pip install --upgrade "cmake>=3.31" ninja || true
fi
echo "   cmake: $(command -v cmake)  $(cmake --version | head -1)"
echo "   ninja: $(command -v ninja)  $(ninja --version 2>/dev/null)"

# ---- 2. 编译环境变量 ---------------------------------------------------------
echo "== [2/5] 设置编译环境 =="
export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH"
export HIP_PLATFORM=amd                       # hipconfig 探测有时返回空，显式钉死
export LD_LIBRARY_PATH="$CORE:$SYSDEPS/lib:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="$SYSDEPS/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# ---- 3. 初始化 rocprofiler-sdk 子模块 ---------------------------------------
echo "== [3/5] 初始化子模块 =="
git config --global --add safe.directory "$REPO_ROOT" 2>/dev/null || true
git submodule sync projects/rocprofiler-sdk 2>/dev/null || true
git submodule update --init --recursive projects/rocprofiler-sdk

# ---- 4. CMake configure -----------------------------------------------------
echo "== [4/5] CMake configure =="
# 关键：钉死 amd_comgr_DIR 到“真库”版 cmake 包（lib/cmake/amd_comgr，target 为
# SHARED libamd_comgr.so.3），否则 find_package 可能命中 lib/cmake/amd_comgr_stub
# （Implib.so lazy-load stub），运行到 ATT 解码首次调 comgr 时其隔离 dlmopen 在
# rocprofv3 进程内失败 → abort("implib-gen: libamd_comgr.so.3 ... failed")。
: "${AMD_COMGR_DIR:=$ROCM_PATH/lib/cmake/amd_comgr}"
rm -rf rocprofiler-sdk-build
cmake -B rocprofiler-sdk-build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DCMAKE_PREFIX_PATH="$ROCM_PATH;$SYSDEPS" \
    -Damd_comgr_DIR="$AMD_COMGR_DIR" \
    -DGPU_TARGETS="$GPU_TARGETS" \
    -DROCPROFILER_BUILD_TESTS=OFF \
    -DROCPROFILER_BUILD_SAMPLES=OFF \
    projects/rocprofiler-sdk

# ---- 5. 编译 + 安装 ---------------------------------------------------------
echo "== [5/5] 编译 + 安装 =="
cmake --build rocprofiler-sdk-build --target all --parallel "$JOBS"
cmake --install rocprofiler-sdk-build

echo "=============================================================="
echo " 完成。rocprofv3 位于：$INSTALL_PREFIX/bin/rocprofv3"
"$INSTALL_PREFIX/bin/rocprofv3" --version 2>/dev/null | head -3 || true
echo "=============================================================="
