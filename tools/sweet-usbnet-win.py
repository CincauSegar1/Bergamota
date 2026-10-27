import socket
import sys

print("=" * 65)
print("  Bergamota / Apple XNU Live Kernel Log Receiver (sweetusb=2)")
print("=" * 65)
print("Listening on UDP port 5140...")
print("If no logs appear, ensure the USB Ethernet adapter has IP: 192.168.7.1")
print("=" * 65 + "\n")

try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", 5140))
except Exception as e:
    print(f"Error binding socket: {e}")
    sys.exit(1)

while True:
    try:
        data, addr = s.recvfrom(65536)
        sys.stdout.write(data.decode("utf-8", errors="replace"))
        sys.stdout.flush()
    except KeyboardInterrupt:
        break
    except Exception as e:
        sys.stderr.write(f"\n[Error: {e}]\n")
