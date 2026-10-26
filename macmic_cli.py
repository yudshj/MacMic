"""MacMic CLI: Wi-Fi/USB streaming or bounded, audio-free diagnosis."""

import argparse
import ipaddress
import subprocess
import sys
import time

from macmic_protocol import MacMicClient, ConnectionState, RECOVERY_HINT
from macmic_adb import ADBManager


def diagnose(host, port=8125, timeout=5.0):
    """One TCP session does both reachability and 0x65; no naked TCP probe."""
    try:
        ipaddress.IPv4Address(host)
    except ValueError:
        print("Diagnosis requires an IPv4 address, not a hostname.")
        return 2
    print("Before diagnosis: WO Mic must show Waiting for connection (等待连接).")
    print("This briefly occupies its single client slot; it does not start audio capture.")
    try:
        result = subprocess.run(["ping", "-n", "-c", "2", host],
                                capture_output=True, text=True, timeout=4)
        print("[Ping] " + ("reachable" if result.returncode == 0 else "no reply (ICMP may be blocked)"))
        print(result.stdout.strip())
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"[Ping] inconclusive: {exc}")
    client = MacMicClient(host=host, control_port=port,
                          on_state_change=lambda state, detail: print(f"[{state}] {detail}"))
    try:
        if client.connect(timeout=timeout, attempts=1, handshake_only=True):
            print("[TCP + 0x65] OK. UDP audio/0x66/0x67 have NOT been tested.")
            return 0
        print("[TCP + 0x65] failed. " + RECOVERY_HINT)
        return 1
    finally:
        client.disconnect()
        print("Stop + abortive close sent best-effort. If the phone stays Connected, tap Stop → Start.")


def main():
    parser = argparse.ArgumentParser(description="WO Mic Client for macOS (Apple Silicon)")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--wifi", metavar="IP", help="Connect via Wi-Fi")
    modes.add_argument("--usb", action="store_true", help="Connect via USB cable (ADB)")
    modes.add_argument("--wifidirect", const="192.168.49.1", metavar="IP", nargs="?",
                       help="Connect via Wi-Fi Direct (default 192.168.49.1)")
    modes.add_argument("--diagnose", metavar="IP", help="Check ping/TCP/0x65 without audio capture")
    parser.add_argument("--port", type=int, default=8125, help="Control service port (default 8125)")
    parser.add_argument("--timeout", type=float, default=5.0, help="Whole connection attempt budget, 0..30s (default 5)")
    parser.add_argument("--device", type=int, default=None, help="Audio output device ID")
    parser.add_argument("--gain", type=float, default=1.0, help="Volume gain multiplier")
    parser.add_argument("--list-devices", action="store_true", help="List output audio devices")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not 0 < args.timeout <= 30:
        parser.error("port must be 1..65535; timeout must be >0 and <=30 seconds")
    if args.diagnose:
        return diagnose(args.diagnose, args.port, args.timeout)
    if not (args.list_devices or args.usb or args.wifi or args.wifidirect):
        parser.print_help()
        return 0
    from macmic_audio import AudioOutputEngine
    if args.list_devices:
        for dev in AudioOutputEngine.get_output_devices():
            flag = " [VIRTUAL MIC]" if dev["is_blackhole"] else ""
            print(f"ID {dev['id']}: {dev['name']} ({dev['channels']}ch, {dev['default_samplerate']}Hz){flag}")
        return 0
    serial = None
    forwarded = False
    client = None
    audio = None
    try:
        if args.usb:
            devices = [d for d in ADBManager.list_devices() if d["state"] == "device"]
            if not devices:
                print("No authorized ADB device. Connect USB and allow USB debugging on the phone.")
                return 1
            serial = devices[0]["serial"]
            forwarded = ADBManager.forward_port(args.port, 8125, serial=serial)
            if not forwarded:
                print("Could not create ADB forwarding. Check whether the local port is occupied.")
                return 1
        host = "127.0.0.1" if args.usb else (args.wifi or args.wifidirect)
        audio = AudioOutputEngine(sample_rate=48000, channels=1)
        audio.set_gain(args.gain)
        audio.device_index = args.device
        client = MacMicClient(host=host, control_port=args.port,
                              media_port=args.port if args.usb else 8125,
                              is_tcp_media=args.usb, audio_engine=audio,
                              on_state_change=lambda state, detail: print(f"[{state}] {detail}"))
        if not client.connect(timeout=args.timeout):
            return 1
        print("WO Mic is streaming. Press Ctrl+C to stop.")
        while client.state == ConnectionState.STREAMING:
            time.sleep(0.2)
        return 1 if client.state == ConnectionState.ERROR else 0
    except KeyboardInterrupt:
        print("\nStopping WO Mic client...")
        return 0
    finally:
        if client:
            client.disconnect()
        if audio:
            audio.stop()
        if forwarded:
            ADBManager.remove_forward(args.port, serial=serial)


if __name__ == "__main__":
    sys.exit(main())
