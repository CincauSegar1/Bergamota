# Porting Bergamota to Poco F5 (Xiaomi `marble` · Qualcomm SM7475 / Snapdragon 7+ Gen 2)

Status: Port configuration, DTB parsing, ADT generation, bootloader adaptation, and GPU firmware acquisition completed.

---

## 1. Hardware Architecture Overview

| Component | Poco F1 (`beryllium`) | Poco F5 (`marble`) |
| :--- | :--- | :--- |
| **SoC** | Qualcomm Snapdragon 845 (SDM845) | **Qualcomm Snapdragon 7+ Gen 2 (SM7475-AB / Diwali/Cape)** |
| **Process Node** | 10nm LPP | **4nm TSMC** (SM8475-derived architecture) |
| **CPU Cluster** | 4x Kryo 385 Gold (A75) + 4x Silver (A55)<br>ARMv8.2-A | **1x Cortex-X2 @ 2.91 GHz + 3x Cortex-A710 @ 2.49 GHz + 4x Cortex-A510 @ 1.8 GHz**<br>**ARMv9.0-A** |
| **PAC (Pointer Auth)** | None (ARMv8.2). Requires Renegade `pacstrip`. | **Native Hardware PAC (FEAT_PAuth)** supported in ARMv9-A! |
| **Interrupt Controller** | ARM GICv3 (`GICD 0x17a00000`, `GICR 0x17a60000`) | **ARM GICv3 (`GICD 0x17100000`, `GICR 0x17180000`)** |
| **Storage** | UFS 2.1 (`ufshc@1d84000`) | **UFS 3.1 (`ufshc@1d84000`)** |
| **Display Panel** | 1080 x 2246 LCD | **1080 x 2400 AMOLED (120Hz, Dolby Vision)** |
| **Android Boot Header** | Header Version 1 (appended DTB) | **Header Version 4 (GKI layout) & Version 2 (Fastboot boot)** |
| **GPU** | Adreno 630 (A6xx) | **Adreno 725 (A7xx family / Adreno 662 internal, Chip ID `0x06060201`)** |
| **GPU Microcode** | `a630_sqe.fw`, `a630_zap.mbn` | **`a730_sqe.fw`, `a730_zap.mbn`** |

---

## 2. Boot Chain & Bootloader Adaptation (`enxerto/`)

1. **Board Configuration ([`enxerto/board.h`](file:///storage/emulated/0/Bergamota-develop/enxerto/board.h))**:
   - `BOARD_NAME`: `"marble"`
   - `FB_BASE`: `0x9c000000UL`
   - `FB_W`: `1080`
   - `FB_H`: `2400`
   - `IMEM_RESTART_REASON`: `0x146bf65cUL`
   - `GICD_BASE`: `0x17100000UL` (GIC Distributor)
   - `GICR_BASE`: `0x17180000UL`, size `0x200000UL` (GIC Redistributors for 8 cores)
   - `UFS_BASE`: `0x01d84000UL`
   - `PSHOLD`: `0x0c264000UL`

2. **UI & Identification ([`enxerto/bootui.c`](file:///storage/emulated/0/Bergamota-develop/enxerto/bootui.c), [`enxerto/fastboot.c`](file:///storage/emulated/0/Bergamota-develop/enxerto/fastboot.c))**:
   - Added `POCO F5` device brand string for boot progress and charging UI.
   - Fastboot reports product as `marble`.

3. **Packaging ([`enxerto/build.sh`](file:///storage/emulated/0/Bergamota-develop/enxerto/build.sh))**:
   - Compiles with `-DBOARD_MARBLE` and uses `dtb/marble/dtb`.
   - Produces Android Boot Image Header Version 4 (`enxerto-boot.img`) matching Android 13/14 GKI format, plus Header Version 2 (`enxerto-boot-v2.img`) for direct `fastboot boot` tethered loading.

---

## 3. Apple Device Tree (ADT) Generation (`tools/mkadt.py`)

- Downloaded extracted Qualcomm SM7475 Diwali device tree blob to [`dtb/marble/dtb`](file:///storage/emulated/0/Bergamota-develop/dtb/marble/dtb).
- Updated `tools/mkadt.py` with `marble` board definition:
  - ARM GICv3 relative to `SOC_BASE` (`0x01000000`): GICD at `0x16100000`, GICR at `0x16180000`.
  - CPU nodes for Cortex-A510, Cortex-A710, and Cortex-X2.
  - Generated verified [`dtb/marble/marble-hi-3x.adt`](file:///storage/emulated/0/Bergamota-develop/dtb/marble/marble-hi-3x.adt).

---

## 4. GPU Subsystem: Adreno 725 Bring-up

### Hardware Identification
- Device Tree Node: `//soc/qcom,kgsl-3d0@3d00000`
- Chip ID: `0x06060201` (`qcom,chipid`)
- GMU Node: `//soc/qcom,gmu@3d69000` (reg `0x3d6a000`, size `0x34000`, PDC `0xb290000`)
- IRQ: `0x12c` (SPI 300) for 3D engine; `0x130`/`0x131` for GMU.

### Downloaded Firmware
- Microcode SQE: [`firmware/marble/a730_sqe.fw`](file:///storage/emulated/0/Bergamota-develop/firmware/marble/a730_sqe.fw) (from linux-firmware upstream)
- PAS ZAP Shader: [`firmware/marble/a730_zap.mbn`](file:///storage/emulated/0/Bergamota-develop/firmware/marble/a730_zap.mbn)

### Userland & Kernel ABI
- Updated [`xnu/gpu-abi/sweet_adreno_abi.h`](file:///storage/emulated/0/Bergamota-develop/xnu/gpu-abi/sweet_adreno_abi.h):
  - Added `SWEET_MSM_CHIP_ID_A725` (`0x06060201`)
  - Added `SWEET_MSM_GPU_ID_A725` (`725`)
- Updated [`gpu/freedreno-sweet/sweet_drm.c`](file:///storage/emulated/0/Bergamota-develop/gpu/freedreno-sweet/sweet_drm.c):
  - Added support for matching `SweetAdreno725` and generic `SweetAdreno` IOKit services.
- Chlorophyll Metal Driver:
  - Cloned into [`gpu/metal/`](file:///storage/emulated/0/Bergamota-develop/gpu/metal/)
  - Translates AIR (`.metallib`) to Mesa NIR, compiled via Freedreno's `ir3` backend.
