#!/bin/bash
# =============================================================================
# run_att_gfx1250.sh
#
# 用自编译的 rocprofv3 在 gfx1250 上抓 ATT/SQTT trace 并解码，一键跑通。
# 内含在 gfx1250 上跑通 --att 所必需的三处运行时修复（详见 README）：
#   1) LD_LIBRARY_PATH 含 /opt/rocm/lib —— aqlprofile 裸名 dlopen 需要
#   2) rocprofv3 由 build_rocprofv3_gfx1250.sh 编出（已直链真 comgr，非 stub）
#   3) --att-library-path 指向支持 gfx1250 的新版 trace-decoder（>=0.1.5）
#
# 用法：
#   bash run_att_gfx1250.sh -- <你的程序及参数>
# 例：
#   bash run_att_gfx1250.sh -- \
#     python profile_mha_flydsl_varlen_minimal.py --causal true -b 1 -nh 32 \
#       -sq 1024 -sk 1024 --warmup 5 --repeat 20
#
# 可用环境变量覆盖：
#   ROCPROF        rocprofv3 可执行路径（默认 ./rocprof-install/bin/rocprofv3）
#   DECODER_DIR    新版 trace-decoder 所在目录（含 librocprof-trace-decoder.so）
#   KERNEL_REGEX   --kernel-include-regex（默认 fmha_fwd_kernel_0）
#   OUTDIR         输出目录（默认 ./att_out）
#   HIP_VISIBLE_DEVICES  目标 GPU（默认 0）
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${ROCM_PATH:=/opt/rocm}"
: "${CORE:=/opt/venv/lib/python3.12/site-packages/_rocm_sdk_core/lib}"
: "${SYSDEPS:=/opt/venv/lib/python3.12/site-packages/_rocm_sdk_devel/lib/rocm_sysdeps}"
: "${ROCPROF:=$REPO_ROOT/rocprof-install/bin/rocprofv3}"
: "${DECODER_DIR:=}"
: "${KERNEL_REGEX:=fmha_fwd_kernel_0}"
: "${OUTDIR:=$REPO_ROOT/att_out}"
: "${HIP_VISIBLE_DEVICES:=0}"
export HIP_VISIBLE_DEVICES

# ---- 运行时环境（修复 1）----------------------------------------------------
export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH"
# /opt/rocm/lib 必须在内：HSA runtime 用裸名 dlopen("libhsa-amd-aqlprofile64.so")，
# 该裸名 .so 软链只在 /opt/rocm/lib（$CORE 里只有 .so.1）。缺它 → ATT 采集时
# aqlprofile 取扩展表失败 → abort("aqlprofile API table load failed")。
export LD_LIBRARY_PATH="$CORE:$SYSDEPS/lib:$ROCM_PATH/lib:${LD_LIBRARY_PATH:-}"

# ---- 取程序命令（-- 之后的部分）--------------------------------------------
APPARGS=()
seen_sep=0
for a in "$@"; do
  if [ "$seen_sep" = 1 ]; then APPARGS+=("$a"); fi
  if [ "$a" = "--" ]; then seen_sep=1; fi
done
if [ "${#APPARGS[@]}" -eq 0 ]; then
  echo "用法: bash run_att_gfx1250.sh -- <程序及参数>" >&2
  exit 2
fi

# ---- 组装 rocprofv3 参数 ----------------------------------------------------
EXTRA=()
# 修复 3：新版 decoder（支持 gfx1250）。给了 DECODER_DIR 才加。
if [ -n "$DECODER_DIR" ] && [ -f "$DECODER_DIR/librocprof-trace-decoder.so" ]; then
  EXTRA+=(--att-library-path "$DECODER_DIR")
fi

rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"

echo "== rocprofv3   = $ROCPROF"
echo "== decoder_dir = ${DECODER_DIR:-<容器自带（可能不支持 gfx1250）>}"
echo "== kernel      = $KERNEL_REGEX"
echo "== outdir      = $OUTDIR"
echo "== HIP_VISIBLE_DEVICES = $HIP_VISIBLE_DEVICES"
echo "== app         = ${APPARGS[*]}"

"$ROCPROF" --att "${EXTRA[@]}" -d "$OUTDIR" \
  --kernel-include-regex "$KERNEL_REGEX" -- \
  "${APPARGS[@]}"
rc=$?
echo "== rocprofv3 exit=$rc =="

# ---- 简单校验解码结果 -------------------------------------------------------
code_json=$(find "$OUTDIR" -name code.json 2>/dev/null | head -1)
if [ -n "$code_json" ] && grep -q '"code":\[' "$code_json" 2>/dev/null; then
  echo "== 解码成功：$code_json 含反汇编指令 =="
elif [ -n "$code_json" ]; then
  echo "== 警告：$code_json 的 code 为空 —— decoder 可能不支持该架构（换更新的 DECODER_DIR）=="
fi
exit $rc
