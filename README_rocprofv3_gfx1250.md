# 在 gfx1250 上跑通 `rocprofv3 --att`（ROCm 7.12.0 / TheRock wheel 布局）

本仓库根目录附带两个脚本，把在 **gfx1250**（MI4xx/Navi4 级）上从源码编译 rocprofv3、
并成功抓取 + 解码 ATT/SQTT trace 所需的全部修复固化下来：

| 脚本 | 作用 |
|---|---|
| `build_rocprofv3_gfx1250.sh` | 一键编译 + 安装 rocprofv3（含依赖安装、子模块、configure、build、install） |
| `run_att_gfx1250.sh`         | 一键抓取 + 解码 ATT trace（内含运行时环境修复） |

> 适用环境：容器内已装 ROCm 7.12.0，采用 TheRock / python-wheel 布局
> （真实库在 `/opt/venv/lib/python3.12/site-packages/_rocm_sdk_core/lib`，
> `/opt/rocm/lib/*` 多为指向它的软链）。本仓库源码需 pin 在与容器运行时匹配的
> commit（如 `0208c97b`，对应 rocprofv3 1.1.0 / ROCm 7.12.0），否则 HSA API 表
> 结构不一致会导致编译期 `static_assert` 失败。

---

## 一、编译

```bash
# 在容器内，从本仓库根目录：
bash build_rocprofv3_gfx1250.sh
```

产物：`./rocprof-install/bin/rocprofv3`

可用环境变量覆盖：`ROCM_PATH` / `INSTALL_PREFIX` / `GPU_TARGETS` / `JOBS` /
`AMD_COMGR_DIR`（默认 `$ROCM_PATH/lib/cmake/amd_comgr`，即“真库”版）。

## 二、抓取 + 解码 trace

需要一份**支持 gfx1250 的** `librocprof-trace-decoder.so`（容器自带的旧版可能不支持）。
放到某目录后用 `DECODER_DIR` 指向它：

```bash
DECODER_DIR=/path/to/new-decoder-dir \
bash run_att_gfx1250.sh -- \
  python profile_mha_flydsl_varlen_minimal.py --causal true --return_lse true \
    -b 1 -nh 32 -sq 1024 -sk 1024 --random-value false --warmup 5 --repeat 20
```

成功后 `att_out/ui_output_*/code.json` 会含逐指令反汇编 + 命中/延迟/stall/idle，
`filenames.json` 应显示 `"gfxip":12,"gfxv":"navi"`（gfx1250 正确识别）。

---

## 三、为什么需要这些修复（三个根因）

在 gfx1250 上 `rocprofv3 --att` 原本会连环 SIGABRT。逐个定位到三个独立根因：

### 1. 采集阶段 abort：`aqlprofile API table load failed`
HSA runtime 用**裸名** `dlopen("libhsa-amd-aqlprofile64.so")` 加载 aqlprofile，
但 TheRock 布局下裸名 `.so` 软链只在 `/opt/rocm/lib`（`_rocm_sdk_core/lib` 里只有
`.so.1`）。运行时 `LD_LIBRARY_PATH` 不含 `/opt/rocm/lib` → dlopen 失败 → aqlprofile
在 `aqlprofile_att_create_packets` 内 `abort()`。
**修复**：`run_att_gfx1250.sh` 把 `/opt/rocm/lib` 加进 `LD_LIBRARY_PATH`。

### 2. 解码阶段 abort：`implib-gen: libamd_comgr.so.3 ... failed via callback`
容器里有两套 `amd_comgr` cmake 包：`lib/cmake/amd_comgr`（真库 SHARED）与
`lib/cmake/amd_comgr_stub`（Implib.so lazy-load stub）。`find_package` 可能命中
stub 版，链入静态跳板；运行到解码首次调 comgr 时，stub 的隔离 `dlmopen` 在
rocprofv3 进程内失败 → abort。
**修复**：`build_rocprofv3_gfx1250.sh` 用 `-Damd_comgr_DIR=<真库版目录>` 直链真库。

### 3. 解码空数据：`INVALID_SHADER_DATA` / `gfxv:"vega"`
闭源 `librocprof-trace-decoder.so` 旧版（如 Mar8/0.1.x 之前）不认识 gfx1250 的
SQTT 格式，`rocprof_trace_decoder_parse_data` 返回 `INVALID_SHADER_DATA`，
`code.json` 里 `code:null`、架构被误判为 gfx9/vega。
**修复**：用支持 gfx1250 的新版 decoder（>=0.1.5），`--att-library-path` 指向它。

> 定位方法：这三个 abort 的真实原因都被 rocprofv3 的 signal handler 掩盖成
> `Resource deadlock avoided`。用 `--disable-signal-handlers true` +
> 在 rocprofv3 里装 `std::set_terminate`（打印真实异常 + backtrace）一次抓到真凶。
