#!/usr/bin/env python3
"""Marble binary fixes for the sweet kernel.

Framebuffer: the kernel was built for beryllium/sweet, where the ABL splash is
at 0xa8000000.  On marble ABL moves it to 0xb8000000 because the v4 boot image
is loaded at 0xa8000000.  Three spots hardcode the old address:

  0x51c300  _start_first_cpu: bootstrap L3 block, Normal-NC VA=PA
            movk x10, #0xa800, lsl #16
  0x510538  arm_vm_init/sweet_early_map_final: final Normal-NC kernel alias
            movk x8, #0xa800, lsl #16
  0xc51f70  _early_fb initial value (8 bytes, little endian)

Every one becomes 0xb8000000.  Without this the early console draws into the
dead boot image (0xa8000000) and the final alias maps the wrong page, so the
panel keeps the loader frame and no kernel output is visible.

Early thread: arm_init calls PE_init_platform (mark 2) before
thread_bootstrap/machine_set_current_thread (mark 4).  PE_init_platform ->
pe_arm_init_interrupts -> kprintf -> hw_lock_try ->
__prepare_preemption_disable_measurement -> current_percpu_base(), which reads
TPIDR_EL1 (= 0 this early) and faults at [0 + 0x200]:

  0x50c7d4  _current_percpu_base: if current_thread() is NULL return 0, the
            boot CPU's valid per-CPU offset, instead of dereferencing NULL.

Boot payload poison: __start (0x751e488, before the kernel page tables exist)
poisons the loaded payload at PA 0xa84f1b00..0xa85266c0.  common_start then
branches to 0x751e4ac, a second poison loop at PA 0xa8526700..0xa855d2c0, but
that runs *after* SCTLR_EL1 enables the kernel MMU, which maps only the kernel
segments (PA >= 0xb0000000) - the old payload is gone, so the first store takes
a data abort.  Skip the loop; only the trailing add/sub/ret is needed:

  0x51c418  common_start: b 0x751e4ac (poison) -> b 0x751e4c8 (add/sub/ret).

Exception vector: the el1_sp0 synchronous vector validates SP_EL0 against
[TPIDR_EL1 + 0x150]/[+0x208].  With TPIDR_EL1 still 0 it dereferences [0x150]
and masks the original fault with a secondary abort.  The el1_sp1 vector is
already NULL-safe; do the same for sp0 by going straight to the frame builder:

  0x516034  el1_sp0 sync vector: add x3,x1,#0x150 -> b 0x751a0b8 (_fleh_synchronous).

Physical timer: marble's non-secure EL1 cannot touch CNTP_* (it is undefined,
the physical timer is owned by the secure/hyp world); the kernel uses CNTV_*
for the tick.  _fiq_context_init enables CNTV_CTL_EL0 then disables the
physical timer, and that store is the only CNTP access in the whole kernel:

  0x520790  _fiq_context_init: msr CNTP_CTL_EL0, x8 -> nop.

skmem (socket memory, new in iOS 18): _skmem_init calls _skmem_region_alloc,
which returns a segment pointer that lands outside the mapped kernel heap
(e.g. 0xfffffe78bf4b4000), then _skmem_sysctl_init writes to it.  The kernel
data abort is routed by the el1_sp0 vector (EC 0x26) to fleh_invalid_stack,
which panics with "Invalid kernel stack pointer".  Skip the segment alloc and
sysctl init (leave the segment NULL, which _skmem_sysctl_init already checks):

  0x997a40  _skmem_init: bl _skmem_region_alloc -> b 0x799ba60 (return).

  patch-marble-fb.py [KERNEL] [OUT]
"""
import os
import sys

PATCHES = (
    (0x51c300, bytes.fromhex('0a00b5f2'), bytes.fromhex('0a00b7f2'),
     'movk x10, #0xa800, lsl #16 -> #0xb800'),
    (0x510538, bytes.fromhex('0800b5f2'), bytes.fromhex('0800b7f2'),
     'movk x8, #0xa800, lsl #16 -> #0xb800'),
    (0xc51f70, bytes.fromhex('000000a800000000'), bytes.fromhex('000000b800000000'),
     '_early_fb 0xa8000000 -> 0xb8000000'),
    (0x50c7d4,
     bytes.fromhex('fd7bbfa9fd03009125470094080041f900fd5093fd7bc1a8c0035fd6'),
     bytes.fromhex('80d038d5800000b4080041f900fd5093c0035fd6000080d2c0035fd6'),
     '_current_percpu_base: return 0 when TPIDR_EL1 is 0 (early kprintf/lock path)'),
    (0x51c418, bytes.fromhex('25f8ff17'), bytes.fromhex('2cf8ff17'),
     'common_start: skip post-MMU payload poison loop (old payload unmapped)'),
    (0x516034, bytes.fromhex('23400591'), bytes.fromhex('21000014'),
     'el1_sp0 sync vector: skip stack validation -> b 0x751a0b8 (_fleh_synchronous)'),
    (0x520790, bytes.fromhex('28e21bd5'), bytes.fromhex('1f2003d5'),
     '_fiq_context_init: nop msr CNTP_CTL_EL0 (EL1 physical timer undefined)'),
    (0x997a40, bytes.fromhex('66220094'), bytes.fromhex('08000014'),
     '_skmem_init: skip segment alloc + sysctl init (segment pointer unmapped)'),
    (0x579478, bytes.fromhex('890240f9'), bytes.fromhex('0e000014'),
     'sweet_ufs: skip UTRLBA/UTRLBAU/UTRLRSR readback (write-only/start race) -> TUR'),
    (0x58261c, bytes.fromhex('8088a152'), bytes.fromhex('0088a152'),
     'sweet_spmi: SP_CORE_PA 0xc440000 -> 0xc400000 (marble spmi0 core)'),
    (0x582630, bytes.fromhex('00009452'), bytes.fromhex('00009a52'),
     'sweet_spmi: SP_CFG_PA low 0xa000 -> 0xd000 (marble spmi0 cnfg 0xc42d000)'),
    (0x582634, bytes.fromhex('0088a172'), bytes.fromhex('4088a172'),
     'sweet_spmi: SP_CFG_PA high 0xc40 -> 0xc42 (marble spmi0 cnfg 0xc42d000)'),
    (0x582648, bytes.fromhex('00cca152'), bytes.fromhex('8088a152'),
     'sweet_spmi: SP_OBS_PA 0xe600000 -> 0xc440000 (marble spmi0 obsrvr)'),
    (0x5794bc,
     bytes.fromhex('00d5ffd000940c91c100805202008052030080520400885232010094e002003400d5ffd000940c91c10080520200805203008052040088522a010094e001003400d5ffd000940c91c100805202008052030080520400885222010094e0000034'),
     bytes.fromhex('081a805288620039680380d20802c0f2e83300f9e0830191c10080520200805203008052040088522e01009400e28452a8dbf7979f62003900d5ffd000940c91c100805202008052030080520400885224010094200100341f2003d51f2003d5'),
     'sweet_ufs: send START_STOP_UNIT(0x10) to Device W-LUN 0xd0 + delay 10ms before TUR (Marble UFS active init)'),
    (0x57998c, bytes.fromhex('5d290094'), bytes.fromhex('1f2003d5'),
     'sweet_ufs: nop call to _sweet_usb_probe (beryllium USB GCC PA 0x100000 faults on marble)'),
    (0x583f00, bytes.fromhex('fc6fbaa9fa6701a9'), bytes.fromhex('00008052c0035fd6'),
     '_sweet_usb_probe: return 0 immediately (do not touch beryllium GCC PA 0x100000)'),
    (0x517aa4, bytes.fromhex('f44fbea9fd7b01a9'), bytes.fromhex('20008052c0035fd6'),
     '_arm64_platform_error: return 1 immediately (suppress unhandled platform error panic)'),
    (0xeb8f8,
     b'SWEET: root volume is not authenticated (error %d); continuing unsealed\n\x00',
     b'SWEET: root volume auth bypassed (unsealed root)\n\x00' + b'\x00' * 23,
     'root volume auth: show bypassed instead of unauthenticated warning'),
    (0x57b828, bytes.fromhex('6a8ef897'), bytes.fromhex('1f2003d5'),
     'sweet_ufs_syncer: nop bl printf (silence SWEET UFS STATS console spam)'),
    (0x57c1ac, bytes.fromhex('490b8052'), bytes.fromhex('89028052'),
     'sweet_sample_thread: initial sleep 90s -> 20s for fast diagnostics'),
    (0x57c20c, bytes.fromhex('e80240b909611953230d084b'), bytes.fromhex('e80240b9c9038052037d091b'),
     'sweet_sample_thread: loop sleep 120s -> 30s for fast periodic diagnostics'),
    (0xb62168,
     bytes.fromhex('a80038d5003d0012086b46f9c80100b4e96646f92b2100914a00a052ecbb6fb26d010a8bad696cf8aefd60d31f202e6bc00000545f0108eb620000544a8140910dff27367b0a039433010a8b'),
     bytes.fromhex('e96646f9a80038d5083d48d30ab56ed34a81409133010a8b0d000014') + bytes.fromhex('1f2003d5') * 12,
     'pe_init_fiq: direct redistributor calculation for SM7475 (stride 0x40000, 8 cores)'),
    (0x4f5498, bytes.fromhex('ff8301d1f44f04a9'), bytes.fromhex('c0035fd61f2003d5'),
     '_pmap_assert_free: return immediately (disable development assertion panic)'),
    (0x4f5428, bytes.fromhex('fd7bbfa9fd030091'), bytes.fromhex('20008052c0035fd6'),
     '_pmap_verify_free: return 1 (TRUE) immediately (disable development assertion panic)'),
    (0x84cf0c, bytes.fromhex('ffc307d1fc6f19a9'), bytes.fromhex('c0035fd61f2003d5'),
     '_sweet_syserr_trace: return immediately (suppress syscall error tracer printf crash)'),
    (0x84cd10, bytes.fromhex('ff4302d1f65706a9'), bytes.fromhex('c0035fd61f2003d5'),
     '_sweet_machtrap_trace: return immediately (suppress mach trap tracer printf crash)'),
#    (0x37b36c, bytes.fromhex('fc6fbaa9fa6701a9'), bytes.fromhex('c0035fd61f2003d5'),
#     '_sweet_crash_log: return immediately (disable crash console spam and printf crashes)'),
    (0x8c4bb4, bytes.fromhex('c00200b4ff8300d1'), bytes.fromhex('00008052c0035fd6'),
     '_exit_reason_get_string_desc: return NULL immediately (prevent non-null-terminated payload printf crash)'),
    (0x8c5378, bytes.fromhex('60ce43f9c00100b4'), bytes.fromhex('0f0000141f2003d5'),
     '_proc_prepareexit: skip sweet crash reason printf (bypass 0044-sweet-crash-log-reason %s crash)'),
    (0x39ec48, bytes.fromhex('5a01899a137d4093'), bytes.fromhex('4fda05141f2003d5'),
     '___doprnt: hook string pointer check (branch to safe_string_check trampoline)'),
    (0x39f018, bytes.fromhex('406bfb38c0020034'), bytes.fromhex('65d905141f2003d5'),
     '___doprnt: hook char read (branch to safe_char_read trampoline)'),
    (0x515584, bytes.fromhex('1f2003d5') * 19,
     bytes.fromhex('5a01899a137d40935f030aebc00000541a7808d5df3f03d5097438d549000036fa030aaaaa25fa1748031b8b087808d5df3f03d5087438d588000037406bfb38400000349626fa17aa26fa17'),
     'trampoline: safe_string_check + safe_char_read (bulletproof MMU at s1e1r probe for ___doprnt)'),
    (0x88eee4, bytes.fromhex('ffc300d1f44f01a9'), bytes.fromhex('c0035fd61f2003d5'),
     '_hfs_mark_inconsistent: return immediately (prevent dirty unjournaled root from flagging runtime corruption)'),
    (0x859918, bytes.fromhex('68720d91ea1740f9'), bytes.fromhex('1700805224000014'),
     '_BlockMarkFreeInternal: line 3362 return success when freeing already unallocated blocks (bypass EIO)'),
    (0x859400, bytes.fromhex('6a720d91e80314aa'), bytes.fromhex('170080521d000014'),
     '_BlockMarkFreeInternal: line 3154 return success for out-of-bounds block free (bypass EIO)'),
    (0x867e40, bytes.fromhex('a3010054'), bytes.fromhex('1f2003d5'),
     '_hfs_getnewvnode: line 946 nop b.lo (bypass c_totalblocks < cf_blocks check)'),
    (0x867e60, bytes.fromhex('a8000054'), bytes.fromhex('1f2003d5'),
     '_hfs_getnewvnode: line 946 nop b.hi (bypass logicalSize > cf_blocks check)'),
    (0x853df0, bytes.fromhex('0d010054'), bytes.fromhex('0b010054'),
     '_MapFileBlockC: line 628 b.lt instead of b.le (allow tmpOff == 0 at extent boundary, bypass EINVAL)'),
    (0x87bf3c, bytes.fromhex('ff8301d1'), bytes.fromhex('c0035fd6'),
     '_hfs_generate_volume_notifications: return immediately (disable VeryLowDisk/LowDisk flags and VFS signal)'),
    (0x892f10, bytes.fromhex('ff8301d1fa6701a9f85f02a9f65703a9'),
     bytes.fromhex('00d842b94000003500008252c0035fd6'),
     '_hfs_freeblks: ldr w0, [x0, #0x2d8]; cbnz w0, #8; mov w0, #0x1000; ret (bypass reserveBlocks clamp, prevent ENOSPC/Code 640)'),
    (0x511918, bytes.fromhex('1f500071'), bytes.fromhex('c0035fd6'),
     '_sweet_early_mark: return immediately (eliminate bottom debug color blocks)'),
    (0x511920,
     bytes.fromhex('ffc301d1fc6f01a9fa6702a9f85f03a9f65704a9f44f05a9fd7b06a9fd830191f40300aae04100b008a07839a81c0037e24100d0'),
     bytes.fromhex('fd7bbfa992a6f997880240b9498c8d52a9aeac721f01096ba1000054004099524073a772927af997fdffff17fd7bc1a8c0035fd6'),
     'dead code at _sweet_early_mark+8: bluetoothd crash quiesce trampoline (sleep forever on SEGV)'),
    (0x8c5374, bytes.fromhex('fed7ea97'), bytes.fromhex('6b31f197'),
     '_proc_prepareexit: redirect bl _sweet_crash_log to bluetoothd quiesce trampoline'),
    (0x5826a4, bytes.fromhex('e0010054'), bytes.fromhex('1f2003d5'),
     '_sweet_spmi_init: nop b.eq (allow SM7475 SPMI arbiter 0x70000000)'),
    (0x5826a8, bytes.fromhex('3f050871'), bytes.fromhex('3f051071'),
     '_sweet_spmi_init: cmp w9, #0x401 (allow up to 1024 APIDs for SM7475 SPMI arbiter)'),
    (0x5826ac, bytes.fromhex('a2010054'), bytes.fromhex('1f2003d5'),
     '_sweet_spmi_init: nop b.cs 0x5826e0 (allow SM7475 SPMI arbiter 0x70000000)'),
    (0x57c37c, bytes.fromhex('ff8304d1fc6f0ca9'), bytes.fromhex('c0035fd61f2003d5'),
     '_sweet_keys_init: return immediately (disable beryllium keys to prevent data abort on SM7475)'),
    (0x5828bc, bytes.fromhex('08080037'), bytes.fromhex('1f2003d5'),
     '_sweet_spmi_read: nop tbnz allowed check (allow reading PMIC PON/chgr/batt registers)'),
    (0xb524f0, bytes.fromhex('80738252'), bytes.fromhex('00718252'),
     '_SweetBattery::publish: mov w0, #5000 (NominalChargeCapacity = 5000 mAh for Poco F5 BM5G)'),
    (0xb52d40, bytes.fromhex('80738252'), bytes.fromhex('00718252'),
     '_SweetBattery::publish: mov w0, #5000 (AppleRawMaxCapacity = 5000 mAh for Poco F5 BM5G)'),
    (0xb53f18, bytes.fromhex('c8030034'), bytes.fromhex('1f2003d5'),
     '_SweetBattery::start: nop cbz (keep 30s battery periodic timer active in static fallback mode)'),
    (0xb2b0a0, bytes.fromhex('ff8301d1'), bytes.fromhex('c0035fd6'),
     'IOPMrootDomain::startIdleSleepTimer: return immediately (disable auto-lock idle sleep)'),
    (0xb349f4, bytes.fromhex('a1020034'), bytes.fromhex('1f2003d5'),
     'IOPMrootDomain::handleSetDisplayPowerOn: nop cbz (ignore display power-off requests)'),
    (0xb4726c, bytes.fromhex('ff0302d1'), bytes.fromhex('c0035fd6'),
     'AppleCLCD::blackout: return immediately (never wipe framebuffer to black)'),
    (0xb4d0d8, bytes.fromhex('17913e39'), bytes.fromhex('1f913e39'),
     'IOMobileFramebufferUserClient::externalMethod: strb wzr, [x8, #0xfa4] (never set fPowerOff to 1, inhibit screen blackout)'),
    (0x511960,
     bytes.fromhex('1f2003d5083a009008694fb909810071a30200548a2a0b534a9d08328b06140b6b6d1c536cc100110d3a0090adb947f90e3a0090ce794fb9cf7d091bf0030baaf101100baa5931b8100600911f020ceb83ffff5429050011ef010e8b3f01086be3feff549f3f03d5f30300aa1aa078395bd0503904000014f30300aa1b0080521a008052f64100b0dc324eb9e84100b015b17839680a80523900805257dcffb0f7ca2c91f84100b018d3389105000014e86a7938390700913f3700f1800100549aff07379fff17f1a9969f1a89000037086b3c389c070091dc320eb9bbfeff34001d0013ddfeff97f2ffff17f70313aa68a27839da324eb9e94100b0'),
     bytes.fromhex('090090d269f8a0f209c0dff2e9fffff22a0140f94a0200b5fd7bbfa9fd030091000091d2e04da1f20100825288d986d248eaa0f208c0dff2e8fffff200013fd6fd7bc1a8ea0300aa090090d269f8a0f209c0dff2e9fffff22a0100f9aa0000b4481140b91f010c72e4079f1a0200001404008052e503042ae603042a0700805248e03bd509008cd24995a8f20809c99a24010035490180520b09c99a6ba1099bc10a805221000b4b02ea81520300805208000014890280520b09c99a6ba1099b010a805221000b0b820a825283bb8052e00313aa88638cd2a8f6a0f208c0dff2e8fffff200013fd608838fd2a8f6a0f208c0dff2e8fffff200011fd6'),
     'dead code at _sweet_early_mark+0x48: dynamic battery charging & SOC trampoline'),
    (0xb53788,
     bytes.fromhex('810c8052020d82520300805224008052250080520600805227008052'),
     bytes.fromhex('76f8e6171f2003d51f2003d51f2003d51f2003d51f2003d51f2003d5'),
     '_SweetBattery::pollBeryllium: branch to dynamic battery trampoline at 0x511960'),
    (0xb53bf8,
     bytes.fromhex('810c8052020d82520300805224008052250080520600805227008052'),
     bytes.fromhex('5af7e6171f2003d51f2003d51f2003d51f2003d51f2003d51f2003d5'),
     '_SweetBattery::poll fallback: branch to dynamic battery trampoline at 0x511960'),
)


def main():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, 'xnu/out-0139/kernel.development.sweet')
    dst = sys.argv[2] if len(sys.argv) > 2 else src + '.marble'
    data = bytearray(open(src, 'rb').read())
    for off, old, new, what in PATCHES:
        got = bytes(data[off:off + len(old)])
        if got != old:
            raise SystemExit(f'{src}: {off:#x}: expected {old.hex()}, got {got.hex()} ({what})')
        data[off:off + len(new)] = new
        print(f'{off:#x}: {what}')

    # Inject native Marble Goodix hardware touch driver into _touch_thread (0x57d284)
    touch_bin = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'marble_touch.bin')
    if os.path.exists(touch_bin):
        touch_code = open(touch_bin, 'rb').read()
        touch_off = 0x57d284
        data[touch_off:touch_off + len(touch_code)] = touch_code
        print(f'{touch_off:#x}: injected native Marble Goodix hardware touch driver ({len(touch_code)} bytes)')

    open(dst, 'wb').write(data)
    print(f'wrote {dst} ({len(data)} bytes)')


if __name__ == '__main__':
    main()
