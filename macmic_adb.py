"""
WO Mic ADB helper for USB connection on macOS.
Manages device discovery and ADB port forwarding.
"""

import subprocess
import shutil
import re


class ADBManager:
    """Helper to detect connected Android devices and forward ports via ADB."""

    @staticmethod
    def get_adb_path():
        """Finds the adb binary path."""
        adb = shutil.which("adb")
        if adb:
            return adb
        common_paths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/Users/luanyufei/Library/Android/sdk/platform-tools/adb",
        ]
        for p in common_paths:
            if shutil.which(p):
                return p
        return "adb"

    @staticmethod
    def list_devices():
        """Returns a list of connected ADB devices."""
        adb = ADBManager.get_adb_path()
        try:
            res = subprocess.run([adb, "devices"], capture_output=True, text=True, timeout=5)
            lines = res.stdout.strip().splitlines()
            devices = []
            for line in lines[1:]:  # skip "List of devices attached"
                line = line.strip()
                if not line:
                    continue
                parts = re.split(r"\s+", line)
                if len(parts) >= 2:
                    serial, state = parts[0], parts[1]
                    devices.append({"serial": serial, "state": state})
            return devices
        except Exception as e:
            print(f"ADB list devices error: {e}")
            return []

    @staticmethod
    def forward_port(local_port: int = 8125, remote_port: int = 8125, serial: str = None) -> bool:
        """Executes `adb forward tcp:<local_port> tcp:<remote_port>`."""
        adb = ADBManager.get_adb_path()
        cmd = [adb]
        if serial:
            cmd.extend(["-s", serial])
        # Never replace another running client's forwarding rule.
        cmd.extend(["forward", "--no-rebind", f"tcp:{local_port}", f"tcp:{remote_port}"])
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            return res.returncode == 0
        except Exception as e:
            print(f"ADB forward error: {e}")
            return False

    @staticmethod
    def remove_forward(local_port: int = 8125, serial: str = None) -> bool:
        """Removes port forwarding."""
        adb = ADBManager.get_adb_path()
        cmd = [adb]
        if serial:
            cmd.extend(["-s", serial])
        cmd.extend(["forward", "--remove", f"tcp:{local_port}"])
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            return res.returncode == 0
        except Exception:
            return False
