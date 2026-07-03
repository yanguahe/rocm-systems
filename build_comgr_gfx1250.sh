#!/bin/bash
# =============================================================================
# build_comgr_gfx1250.sh
#
# 自包含编译脚本：在装有 ROCm 7.12.0 (TheRock / python-wheel 布局) 的容器内，
# 从本仓库 comgr/ 源码编译一个 **基于 LLVM23** 的 libamd_comgr.so。
#
# 为什么需要它：rocprofv3 --att 解码 gfx1250 trace 时，用 comgr 反汇编 code
# object。容器自带的 comgr 基于 LLVM22，不认识 gfx1250 的新指令编码（如
# v_writelane_b32 的 VOP3 编码 0xd7610000），会把整条指令流吐成非法 `.long`，
# 导致 code.json 残缺。编译 kernel 用的是 LLVM23，故 comgr 也必须用 LLVM23 才
# 能对齐反汇编。本脚本产出的 comgr 供 rocprofv3 运行时前置加载。
#
# 依赖（必须外部预先备好，体积数 GB，不入库）：
#   一个已编译好的 LLVM23 build 目录，要求：
#     - commit 与编译 kernel 的 LLVM 一致（本环境 = ROCm/llvm-project 7f77ca0）；
#     - 启用了 mlir;clang;lld 三个 project（comgr 需 LLVM/Clang/LLD 的 cmake 包）；
#     - 启用了 zstd（-DLLVM_ENABLE_ZSTD=ON），否则运行期抓 trace 会因
#       `zstd::decompress is unavailable` 而 abort。
#   通过环境变量 LLVM_BUILD_DIR 指向它（默认见下方）。
#
# 用法（在容器 hyg_fyd1 内，从仓库根目录）：
#   LLVM_BUILD_DIR=/path/to/llvm-project/build \
#   bash build_comgr_gfx1250.sh
#
# 产物：
#   ./comgr/build/libamd_comgr.so.3.0.0   —— 编译出的新 comgr（软链 .so.3 / .so）
# 部署：把该 .so.3.0.0 + 软链放到一个目录，运行 rocprofv3 前用
#   LD_LIBRARY_PATH 前置该目录（须在 _rocm_sdk_core/lib 之前），使其胜出。
#   同时 LD_LIBRARY_PATH 需含 $SYSDEPS/lib（新 comgr 运行期依赖 libzstd）。
# =============================================================================
set -euo pipefail

# ---- 可调参数 ----------------------------------------------------------------
: "${ROCM_PATH:=/opt/rocm}"
: "${JOBS:=$(nproc)}"
# 编译 kernel 的那版 LLVM23 build（含 mlir;clang;lld + zstd）。必须存在。
: "${LLVM_BUILD_DIR:=/data/yanguahe/code/wk_sp1/llvm-project/buildmlir}"
# ROCm TheRock wheel 里的真实库/头文件位置
: "${CORE:=/opt/venv/lib/python3.12/site-packages/_rocm_sdk_core/lib}"
: "${SYSDEPS:=/opt/venv/lib/python3.12/site-packages/_rocm_sdk_devel/lib/rocm_sysdeps}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMGR_SRC="$REPO_ROOT/comgr"
BUILD_DIR="$COMGR_SRC/build"

echo "=============================================================="
echo " comgr build (LLVM23) for gfx1250 disassembly"
echo "   REPO_ROOT      = $REPO_ROOT"
echo "   COMGR_SRC      = $COMGR_SRC"
echo "   LLVM_BUILD_DIR = $LLVM_BUILD_DIR"
echo "   ROCM_PATH      = $ROCM_PATH"
echo "   JOBS           = $JOBS"
echo "=============================================================="

# ---- 0. 前置检查 -------------------------------------------------------------
[ -f "$COMGR_SRC/CMakeLists.txt" ] || { echo "ERR: 找不到 comgr 源码：$COMGR_SRC"; exit 1; }
for d in llvm clang lld; do
    [ -d "$LLVM_BUILD_DIR/lib/cmake/$d" ] || {
        echo "ERR: LLVM_BUILD_DIR 缺 lib/cmake/$d —— 该 LLVM build 需启用 mlir;clang;lld"; exit 1; }
done
# AMDDeviceLibs cmake 包（comgr device-libs 需要）：优先取 wheel 里的
DEVLIB="$SYSDEPS/../llvm/lib/cmake/AMDDeviceLibs"
[ -f "$DEVLIB/AMDDeviceLibsConfig.cmake" ] || {
    echo "ERR: 找不到 AMDDeviceLibsConfig.cmake：$DEVLIB"; exit 1; }
# zstd cmake 包（LLVM 加了 zstd 后，其 export 引用 imported target zstd::libzstd_shared）
ZSTDCMAKE="$SYSDEPS/lib/cmake/zstd"
[ -d "$ZSTDCMAKE" ] || { echo "ERR: 找不到 zstd cmake 包：$ZSTDCMAKE"; exit 1; }

# ---- 1. 安装依赖 -------------------------------------------------------------
echo "== [1/3] 检查 cmake/ninja =="
if ! cmake --version 2>/dev/null | head -1 | grep -qE '3\.(2[1-9]|[3-9][0-9])'; then
    python3 -m pip install --upgrade "cmake>=3.31" ninja || true
fi
echo "   cmake: $(command -v cmake)  $(cmake --version | head -1)"
echo "   ninja: $(command -v ninja)  $(ninja --version 2>/dev/null)"
export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH"
git config --global --add safe.directory "$REPO_ROOT" 2>/dev/null || true

# ---- 2. CMake configure -----------------------------------------------------
echo "== [2/3] CMake configure =="
# 关键点：
#  - CMAKE_PREFIX_PATH 必须含 $ZSTDCMAKE，否则 LLVM/LLD 的 export 引用的 imported
#    target zstd::libzstd_shared 找不到 → configure 报 "target not found"。
#  - 显式给 -Dzstd_LIBRARY/-Dzstd_INCLUDE_DIR，让 LLVM 的 module-mode Findzstd
#    能重建 target（双保险）。
#  - SPIRV 是可选，本 build 未编 LLVMSPIRVLib，comgr 会自动 "SPIRV Disabled"，无碍。
rm -f "$BUILD_DIR/CMakeCache.txt"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$LLVM_BUILD_DIR/lib/cmake/llvm;$LLVM_BUILD_DIR/lib/cmake/clang;$LLVM_BUILD_DIR/lib/cmake/lld;$DEVLIB;$ZSTDCMAKE;$SYSDEPS" \
    -DLLVM_DIR="$LLVM_BUILD_DIR/lib/cmake/llvm" \
    -DClang_DIR="$LLVM_BUILD_DIR/lib/cmake/clang" \
    -DLLD_DIR="$LLVM_BUILD_DIR/lib/cmake/lld" \
    -DLLVM_ENABLE_ZSTD=ON \
    -Dzstd_INCLUDE_DIR="$SYSDEPS/include" \
    -Dzstd_LIBRARY="$SYSDEPS/lib/libzstd.so" \
    -DBUILD_TESTING=OFF \
    ..

# ---- 3. 编译 ----------------------------------------------------------------
echo "== [3/3] 编译 amd_comgr =="
ninja -j"$JOBS" amd_comgr

echo "=============================================================="
SO="$BUILD_DIR/libamd_comgr.so.3.0.0"
if [ -f "$SO" ]; then
    echo " 完成。产物：$SO"
    echo " zstd 链接检查："
    ldd "$SO" 2>/dev/null | grep -i zstd || echo "   (警告：未见 zstd，运行期可能 abort)"
else
    echo " 失败：未生成 $SO"; exit 1
fi
echo "=============================================================="
