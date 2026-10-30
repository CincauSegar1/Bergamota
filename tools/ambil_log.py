#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
 Project Apple / Bergamota - Universal USB Boot Log Capture Tool
================================================================================
 Script ini digunakan di Laptop (Windows / macOS / Linux) untuk menangkap seluruh
 log booting iOS 18 (Apple Logo / XNU / Userspace / Daemons) secara otomatis
 dari awal hingga akhir, lalu menyimpannya ke dalam file .txt di folder yang sama.

 Fitur Utama:
  1. ADB / Recovery Mode (Full Persistent SWEETLOG):
     - Menarik 4 MiB persistent console ring buffer langsung dari partisi UFS userdata.
     - Berisi SEMUA log kernel printf dan daemon (/dev/console) dari awal boot sampai akhir.
     - Juga otomatis menarik dmesg, pstore ramoops, dan last_kmsg jika tersedia.
  2. Live Serial / USB COM Port:
     - Memindai dan membaca streaming serial (COM1-COM64 di Windows, /dev/ttyUSB*, /dev/ttyACM*).
  3. Live UDP Network Receiver (Port 5140):
     - Menangkap siaran log UDP langsung saat USB CDC-ECM / sweetusb aktif.
  4. Fastboot Diagnostic:
     - Mendeteksi perangkat dalam mode fastboot dan mengambil info getvar.
  5. Auto File Logging:
     - Otomatis membuat file .txt bertanda waktu: log_apple_ios18_<timestamp>.txt
     - Menyimpan dan menampilkan log secara real-time.
================================================================================
"""

import sys
import os
import time
import datetime
import struct
import socket
import select
import subprocess
import threading
import platform
import re

# Deteksi ketersediaan modul opsional serial (pyserial)
try:
    import serial
    import serial.tools.list_ports
    HAVE_PYSERIAL = True
except ImportError:
    HAVE_PYSERIAL = False

# Konfigurasi
UDP_PORT = 5140
SERIAL_BAUDRATE = 115200
SWEETLOG_MAGIC = b'SWEETLOG'
SWEETLOG_RING_SIZE = 4 * 1024 * 1024  # 4 MiB
SWEETLOG_BLOCKS = 1025                 # 1 blok header (4 KiB) + 1024 blok ring (4 MiB)

# ANSI Colors untuk tampilan terminal
class Col:
    CYAN = '\033[96m' if sys.stdout.isatty() else ''
    GREEN = '\033[92m' if sys.stdout.isatty() else ''
    YELLOW = '\033[93m' if sys.stdout.isatty() else ''
    RED = '\033[91m' if sys.stdout.isatty() else ''
    MAGENTA = '\033[95m' if sys.stdout.isatty() else ''
    BOLD = '\033[1m' if sys.stdout.isatty() else ''
    RESET = '\033[0m' if sys.stdout.isatty() else ''

class DualWriter:
    """Menulis output ke layar terminal dan file .txt secara bersamaan."""
    def __init__(self, filepath):
        self.file = open(filepath, 'w', encoding='utf-8', errors='replace', buffering=1)
        self.filepath = filepath
        self.lock = threading.Lock()

    def write(self, text, show_console=True):
        with self.lock:
            # Tulis ke file tanpa ANSI color codes
            clean_text = re.sub(r'\033\[[0-9;]*m', '', text)
            self.file.write(clean_text)
            self.file.flush()
            if show_console:
                sys.stdout.write(text)
                sys.stdout.flush()

    def writeln(self, text='', show_console=True):
        self.write(text + '\n', show_console=show_console)

    def close(self):
        with self.lock:
            if not self.file.closed:
                self.file.close()

def get_script_dir():
    """Mendapatkan folder tempat script ini berada."""
    return os.path.dirname(os.path.abspath(__file__))

def create_log_file():
    """Membuat nama file log baru bertanda waktu di folder script."""
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    fname = f"log_apple_ios18_{ts}.txt"
    full_path = os.path.join(get_script_dir(), fname)
    return full_path

def run_cmd(cmd_list, timeout=10):
    """Menjalankan command shell dengan aman dan mengembalikan stdout."""
    try:
        res = subprocess.run(cmd_list, capture_output=True, text=True, timeout=timeout, encoding='utf-8', errors='replace')
        return res.returncode, res.stdout.strip(), res.stderr.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, Exception) as e:
        return -1, '', str(e)

def run_cmd_bytes(cmd_list, timeout=30):
    """Menjalankan command dan mengembalikan stdout dalam format raw bytes."""
    try:
        res = subprocess.run(cmd_list, capture_output=True, timeout=timeout)
        return res.returncode, res.stdout, res.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError, Exception) as e:
        return -1, b'', str(e).encode('utf-8')

# ==============================================================================
# 1. DECODER SWEETLOG (Persistent UFS Kernel Ring Buffer)
# ==============================================================================
def decode_sweetlog(data_bytes):
    """
    Decode buffer SWEETLOG dari partisi userdata UFS.
    Format Header (4096 bytes pertama):
      magic: 8s ("SWEETLOG")
      version: u32 (1)
      size: u32 (4 MiB)
      total: u64 (total bytes written since boot)
      seq: u64 (flush counter)
    Diikuti data ring buffer sepanjang size.
    """
    if len(data_bytes) < 4096:
        return None, "Ukuran data terlalu kecil (< 4096 bytes)"

    magic, version, size, total, seq = struct.unpack_from('<8sIIQQ', data_bytes, 0)
    if magic != SWEETLOG_MAGIC:
        return None, f"Header bukan SWEETLOG (magic didapat: {magic!r})"

    ring_data = data_bytes[4096:4096 + size]
    if len(ring_data) < size:
        return None, f"Data ring buffer tidak lengkap ({len(ring_data)}/{size} bytes)"

    if total <= size:
        text_bytes = ring_data[:total]
        wrapped = False
    else:
        start = total % size
        text_bytes = ring_data[start:] + ring_data[:start]
        wrapped = True

    decoded_text = text_bytes.decode('utf-8', errors='replace').replace('\r\n', '\n').replace('\r', '\n')
    meta_info = {
        'version': version,
        'size': size,
        'total': total,
        'seq': seq,
        'wrapped': wrapped,
        'length': len(decoded_text)
    }
    return decoded_text, meta_info

# ==============================================================================
# 2. PULL DARI ADB / RECOVERY
# ==============================================================================
def check_adb_devices():
    """Memeriksa apakah ada perangkat ADB yang terdeteksi."""
    rc, out, _ = run_cmd(['adb', 'devices'])
    if rc != 0:
        return []
    devices = []
    for line in out.splitlines()[1:]:
        parts = line.strip().split()
        if len(parts) >= 2:
            devices.append({'serial': parts[0], 'state': parts[1]})
    return devices

def pull_sweetlog_via_adb(serial_id, writer):
    """
    Menarik persistent SWEETLOG dari HP menggunakan ADB (Recovery / Rooted).
    Mengakses 1025 blok terakhir dari partisi userdata UFS.
    """
    adb_base = ['adb']
    if serial_id:
        adb_base.extend(['-s', serial_id])

    writer.writeln(f"{Col.CYAN}[ADB]{Col.RESET} Mencari partisi userdata di perangkat {serial_id}...")

    # Cari path block device userdata
    find_dev_cmd = (
        'for d in /dev/block/by-name/userdata /dev/block/bootdevice/by-name/userdata; do '
        '[ -e $d ] && readlink -f $d && break; done'
    )
    rc, dev, err = run_cmd(adb_base + ['shell', find_dev_cmd])
    if rc != 0 or not dev:
        # Fallback langsung ke symlink umum
        dev = '/dev/block/by-name/userdata'

    writer.writeln(f"{Col.CYAN}[ADB]{Col.RESET} Partisi userdata ditemukan: {dev}")

    # Dapatkan ukuran partisi dalam bytes
    rc, bytes_str, _ = run_cmd(adb_base + ['shell', f'blockdev --getsize64 {dev}'])
    total_bytes = 0
    try:
        total_bytes = int(bytes_str.strip())
    except ValueError:
        # Coba cara alternatif via sysfs
        rc, size_str, _ = run_cmd(adb_base + ['shell', f'cat /sys/class/block/$(basename $(readlink -f {dev}))/size'])
        try:
            total_bytes = int(size_str.strip()) * 512
        except ValueError:
            pass

    if total_bytes <= 0:
        writer.writeln(f"{Col.RED}[ADB Error]{Col.RESET} Gagal membaca ukuran partisi userdata.")
        return False

    skip_blocks = (total_bytes // 4096) - SWEETLOG_BLOCKS
    writer.writeln(f"{Col.CYAN}[ADB]{Col.RESET} Ukuran partisi: {total_bytes:,} bytes (~{total_bytes // (1024*1024*1024)} GB)")
    writer.writeln(f"{Col.CYAN}[ADB]{Col.RESET} Mengambil {SWEETLOG_BLOCKS} blok terakhir (offset blok: {skip_blocks:,})...")

    dd_cmd = f"dd if={dev} bs=4096 skip={skip_blocks} count={SWEETLOG_BLOCKS} 2>/dev/null"
    rc, raw_data, err_bytes = run_cmd_bytes(adb_base + ['exec-out', dd_cmd], timeout=45)
    if rc != 0 or len(raw_data) < 4096:
        # Coba tanpa exec-out (menggunakan shell dd)
        rc, raw_data, _ = run_cmd_bytes(adb_base + ['shell', f"dd if={dev} bs=4096 skip={skip_blocks} count={SWEETLOG_BLOCKS}"], timeout=45)

    if len(raw_data) < 4096:
        writer.writeln(f"{Col.RED}[ADB Error]{Col.RESET} Data yang terbaca terlalu kecil ({len(raw_data)} bytes).")
        return False

    decoded_text, meta = decode_sweetlog(raw_data)
    if not decoded_text:
        writer.writeln(f"{Col.YELLOW}[ADB Warning]{Col.RESET} Gagal decode SWEETLOG: {meta}")
        writer.writeln(f"{Col.YELLOW}[Info]{Col.RESET} Menyimpan raw data UFS ke file...")
        writer.write(raw_data.decode('utf-8', errors='replace'))
        return True

    writer.writeln(f"\n{Col.GREEN}{'='*70}{Col.RESET}")
    writer.writeln(f"{Col.GREEN} BERHASIL MENGEKSTRAK SWEET PERSISTENT LOG!{Col.RESET}")
    writer.writeln(f"{Col.GREEN} Versi: {meta['version']} | Total Output: {meta['total']:,} bytes | Flush: #{meta['seq']}{Col.RESET}")
    if meta['wrapped']:
        writer.writeln(f"{Col.YELLOW} (Log melebihi 4MB - bagian terlama telah ter-wrap){Col.RESET}")
    writer.writeln(f"{Col.GREEN}{'='*70}{Col.RESET}\n")

    writer.writeln("--- [AWAL LOG KERNEL & SYSTEM DAEMONS IOS 18] ---")
    writer.writeln(decoded_text)
    writer.writeln("--- [AKHIR LOG SWEET KERNEL] ---")

    # Ambil juga dmesg dan ramoops jika ada
    writer.writeln(f"\n{Col.CYAN}[ADB]{Col.RESET} Memeriksa log pendukung (ramoops / last_kmsg)...")
    _, ramoops, _ = run_cmd(adb_base + ['shell', 'cat /sys/fs/pstore/console-ramoops 2>/dev/null'])
    if ramoops and len(ramoops) > 20:
        writer.writeln("\n--- [CONSOLE RAMOOPS (PSTORE)] ---")
        writer.writeln(ramoops)

    _, last_kmsg, _ = run_cmd(adb_base + ['shell', 'cat /proc/last_kmsg 2>/dev/null'])
    if last_kmsg and len(last_kmsg) > 20:
        writer.writeln("\n--- [LAST_KMSG] ---")
        writer.writeln(last_kmsg)

    return True

# ==============================================================================
# 3. LIVE SERIAL / COM PORT MONITOR
# ==============================================================================
def list_serial_ports():
    """Mendeteksi daftar COM port yang tersedia di sistem."""
    ports = []
    if HAVE_PYSERIAL:
        try:
            for p in serial.tools.list_ports.comports():
                ports.append((p.device, p.description))
        except Exception:
            pass
    elif platform.system() == "Windows":
        # Deteksi via registry jika pyserial belum diinstal
        try:
            import winreg
            key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DEVICEMAP\SERIALCOMM")
            for i in range(winreg.QueryInfoKey(key)[1]):
                val_name, val_data, _ = winreg.EnumValue(key, i)
                ports.append((val_data, val_name))
        except Exception:
            # Fallback periksa COM1-COM20
            for i in range(1, 21):
                ports.append((f"COM{i}", f"Standard Serial Port COM{i}"))
    else:
        # Linux / macOS / Android
        for dev_pattern in ['/dev/ttyUSB*', '/dev/ttyACM*', '/dev/tty.usb*']:
            import glob
            for d in glob.glob(dev_pattern):
                ports.append((d, d))
    return ports

def monitor_serial_port(port_name, baudrate, writer, stop_event):
    """Mendengarkan data serial dari COM port."""
    if not HAVE_PYSERIAL:
        return False
    try:
        ser = serial.Serial(port_name, baudrate, timeout=1)
        writer.writeln(f"{Col.GREEN}[Serial]{Col.RESET} Terhubung ke {port_name} ({baudrate} baud)!")
        while not stop_event.is_set():
            data = ser.read(ser.in_waiting or 1)
            if data:
                text = data.decode('utf-8', errors='replace')
                writer.write(text)
        ser.close()
        return True
    except Exception as e:
        writer.writeln(f"{Col.YELLOW}[Serial Warning]{Col.RESET} Port {port_name}: {e}")
        return False

# ==============================================================================
# 4. LIVE UDP RECEIVER (PORT 5140)
# ==============================================================================
def listen_udp(writer, stop_event):
    """Mendengarkan live broadcast kernel log melalui port UDP 5140."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("", UDP_PORT))
        sock.settimeout(1.0)
        writer.writeln(f"{Col.CYAN}[UDP Receiver]{Col.RESET} Mendengarkan paket live log di UDP port {UDP_PORT}...")
    except Exception as e:
        writer.writeln(f"{Col.YELLOW}[UDP Warning]{Col.RESET} Tidak dapat membuka port UDP {UDP_PORT}: {e}")
        return

    while not stop_event.is_set():
        try:
            data, addr = sock.recvfrom(65536)
            if data:
                text = data.decode('utf-8', errors='replace')
                writer.write(text)
        except socket.timeout:
            continue
        except Exception as e:
            if not stop_event.is_set():
                writer.writeln(f"{Col.RED}[UDP Error]{Col.RESET} {e}")
            break
    sock.close()

# ==============================================================================
# 5. DIAGNOSTIK USB PERANGKAT
# ==============================================================================
def inspect_connected_usb():
    """Memeriksa perangkat USB yang tercolok ke Laptop."""
    info = []
    os_name = platform.system()
    if os_name == "Windows":
        rc, out, _ = run_cmd(['powershell', '-Command', 
            'Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "*USB*" } | Select-Object FriendlyName, InstanceId | Format-Table -HideTableHeaders'], timeout=5)
        if rc == 0 and out:
            info = [line.strip() for line in out.splitlines() if line.strip()]
    elif os_name == "Linux":
        rc, out, _ = run_cmd(['lsusb'], timeout=5)
        if rc == 0 and out:
            info = [line.strip() for line in out.splitlines() if line.strip()]
    elif os_name == "Darwin":
        rc, out, _ = run_cmd(['system_profiler', 'SPUSBDataType'], timeout=5)
        if rc == 0 and out:
            for l in out.splitlines():
                if "Product ID:" in l or "Vendor ID:" in l or "Serial Number:" in l:
                    info.append(l.strip())
    return info

# ==============================================================================
# MAIN PROGRAM
# ==============================================================================
def main():
    log_file_path = create_log_file()
    writer = DualWriter(log_file_path)

    header = f"""
================================================================================
  PROJECT APPLE / BERGAMOTA - USB LOG CAPTURE TOOL (AUTO-LOGGER)
================================================================================
 File Log Disimpan Di:
 {log_file_path}
 Tanggal/Waktu: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
 OS Laptop: {platform.system()} {platform.release()} ({platform.machine()})
 Python: {sys.version.split()[0]}
================================================================================
"""
    writer.writeln(header)

    writer.writeln(f"{Col.BOLD}Memulai pemindaian perangkat USB & jalur log...{Col.RESET}\n")

    # 1. Periksa USB terhubung di Laptop
    usb_list = inspect_connected_usb()
    if usb_list:
        writer.writeln(f"{Col.CYAN}[Hardware USB]{Col.RESET} Perangkat USB terdeteksi:")
        for u in usb_list[:8]:
            writer.writeln(f"  * {u}")
        writer.writeln("")

    # 2. Cek apakah ada ADB / Recovery
    devices = check_adb_devices()
    adb_handled = False
    if devices:
        writer.writeln(f"{Col.GREEN}[Status]{Col.RESET} Ditemukan perangkat ADB:")
        for d in devices:
            writer.writeln(f"  -> Serial: {d['serial']} | Status: {d['state']}")
            if d['state'] in ['device', 'recovery']:
                success = pull_sweetlog_via_adb(d['serial'], writer)
                if success:
                    adb_handled = True

    # 3. Jalankan Background Listeners (UDP + Serial)
    stop_event = threading.Event()
    threads = []

    # Listener UDP port 5140
    t_udp = threading.Thread(target=listen_udp, args=(writer, stop_event), daemon=True)
    t_udp.start()
    threads.append(t_udp)

    # Deteksi dan buka port serial jika ada
    serial_ports = list_serial_ports()
    if serial_ports:
        writer.writeln(f"{Col.CYAN}[Serial]{Col.RESET} Port serial terdeteksi di laptop:")
        for port, desc in serial_ports:
            writer.writeln(f"  * {port} ({desc})")
            if HAVE_PYSERIAL:
                t_ser = threading.Thread(target=monitor_serial_port, args=(port, SERIAL_BAUDRATE, writer, stop_event), daemon=True)
                t_ser.start()
                threads.append(t_ser)
    else:
        writer.writeln(f"{Col.YELLOW}[Serial]{Col.RESET} Tidak ada serial COM port aktif saat ini.")

    if not HAVE_PYSERIAL:
        writer.writeln(f"{Col.YELLOW}[Tip]{Col.RESET} Jika ingin menangkap serial COM port langsung di laptop, jalankan: {Col.BOLD}pip install pyserial{Col.RESET}")

    # Petunjuk penggunaan untuk pengguna
    writer.writeln(f"""
{Col.BOLD}--------------------------------------------------------------------------------{Col.RESET}
{Col.GREEN}[PANDUAN LOGGING]{Col.RESET}
 1. Script saat ini sedang aktif mendengarkan live log (UDP 5140 & Serial COM).
 2. Jika HP Anda saat ini berada di {Col.BOLD}Logo Apple{Col.RESET}:
    - Hubungkan kabel USB dari HP ke Laptop.
    - Semua data log yang terkirim lewat USB akan langsung tercatat di sini.
 3. {Col.BOLD}UNTUK MENDAPATKAN 100% FULL LOG DARI AWAL BOOT:{Col.RESET}
    - Cukup reboot HP ke {Col.BOLD}Recovery (OrangeFox / TWRP){Col.RESET} atau buka mode ADB.
    - Script ini akan OTOMATIS membaca 4MB persistent log langsung dari partisi UFS
      (semua log sejak detik pertama boot tersimpan aman di partisi UFS).
 4. Tekan {Col.BOLD}Ctrl + C{Col.RESET} kapan saja untuk menyelesaikan dan menutup log.
{Col.BOLD}--------------------------------------------------------------------------------{Col.RESET}
""")

    try:
        while True:
            # Polling berkala jika ada perangkat ADB baru tersambung
            if not adb_handled:
                new_devs = check_adb_devices()
                for d in new_devs:
                    if d['state'] in ['device', 'recovery']:
                        writer.writeln(f"\n{Col.GREEN}[Perangkat Baru]{Col.RESET} Perangkat ADB terdeteksi: {d['serial']} ({d['state']})")
                        if pull_sweetlog_via_adb(d['serial'], writer):
                            adb_handled = True
                            writer.writeln(f"\n{Col.GREEN}[Info]{Col.RESET} Log lengkap berhasil ditarik! File siap dikirimkan.")
            time.sleep(2)
    except KeyboardInterrupt:
        writer.writeln(f"\n{Col.YELLOW}[Stop]{Col.RESET} Pengambilan log dihentikan oleh pengguna.")
    finally:
        stop_event.set()
        writer.writeln(f"""
================================================================================
 {Col.GREEN}SELESAI! LOG TELAH DISIMPAN KE:{Col.RESET}
 {Col.BOLD}{log_file_path}{Col.RESET}
 Silakan kirim file .txt di atas ke chat!
================================================================================
""")
        writer.close()

if __name__ == '__main__':
    main()
