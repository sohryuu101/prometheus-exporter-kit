#!/usr/bin/env python3
"""
Huawei Switch Discovery Script (Verbose)
Connects via USB serial console, runs all discovery commands, logs everything.
Shows all console I/O in real-time.

Adapted for Huawei VRP (S-series / AR-series / CloudEngine).
Differences vs H3C Comware:
    - Pagination disable: 'screen-length 0 temporary' (not 'screen-length disable')
    - Stacking: iStack 'display stack' / CSS 'display css status' (not IRF)
    - Link aggregation: 'display eth-trunk' (not 'display link-aggregation summary')
    - Memory: 'display memory-usage' (not 'display memory')
    - LLDP: 'display lldp neighbor[ brief]' (not 'display lldp neighbor-information ...')
    - VLAN: 'display vlan' (not 'display vlan all')
    Prompt format <name> / [name] is identical, so connection/login logic is unchanged.

Requirements (Mac):
    pip3 install pyserial

Usage:
    python3 huawei_switch_probe.py
"""

import sys
import os
import time
import getpass
import glob
from datetime import datetime

try:
    import serial
except ImportError:
    print("Missing pyserial. Install with: pip3 install pyserial")
    sys.exit(1)


# ─── CONFIG ───────────────────────────────────────────────────────────
SERIAL_PORT = "/dev/tty.usbserial-XXXX"   # change to your adapter; macOS shows /dev/tty.usb*
BAUD_RATE   = 9600
TIMEOUT     = 5

# ─── DISCOVERY COMMANDS (Huawei VRP) ──────────────────────────────────
COMMANDS = [
    ("=== IDENTITY & HEALTH ===",          None),
    ("display version",                     "Firmware (VRP), uptime, hardware model"),
    ("display device",                      "Board/slot status"),
    ("display device manuinfo",             "Serial numbers / manufacture info"),
    ("display esn",                         "Equipment serial number"),
    ("display environment",                 "Temperature (model dependent)"),
    ("display fan",                         "Fan status"),
    ("display power",                       "Power supply status"),
    ("display cpu-usage",                   "CPU load"),
    ("display memory-usage",                "Memory utilization"),
    ("display clock",                       "Current time (NTP check)"),

    ("=== STACKING (iStack / CSS) ===",     None),
    ("display stack",                       "iStack members, roles"),
    ("display stack configuration",         "iStack config / priority"),
    ("display css status",                  "CSS (chassis) status — ignore if not chassis"),

    ("=== INTERFACES ===",                  None),
    ("display interface brief",             "All ports — up/down, speed, duplex"),
    ("display ip interface brief",          "L3 interfaces with IP addresses"),
    ("display transceiver",                 "SFP module presence"),
    ("display transceiver verbose",         "SFP module detail (DOM, type)"),

    ("=== VLANS ===",                       None),
    ("display vlan",                        "All VLANs and member ports"),
    ("display port vlan",                   "Per-port VLAN / link-type / PVID"),

    ("=== LLDP NEIGHBORS ===",              None),
    ("display lldp neighbor brief",         "LLDP neighbor summary"),
    ("display lldp neighbor",               "LLDP neighbor detail"),
    ("display lldp local",                  "What this switch advertises"),

    ("=== LINK AGGREGATION ===",            None),
    ("display eth-trunk",                   "All Eth-Trunk (LAG) groups"),

    ("=== ARP & MAC TABLE ===",             None),
    ("display arp",                         "Full ARP table"),
    ("display mac-address",                 "MAC address table"),

    ("=== ROUTING ===",                     None),
    ("display ip routing-table",            "Routing table"),

    ("=== SPANNING TREE ===",               None),
    ("display stp brief",                   "STP port states"),

    ("=== SNMP ===",                        None),
    ("display snmp-agent sys-info",         "SNMP version, contact, location"),
    ("display snmp-agent community",        "SNMP community strings (v1/v2c)"),
    ("display snmp-agent usm-user",         "SNMPv3 users"),
    ("display snmp-agent statistics",       "SNMP packet counters"),

    ("=== SECURITY & ACCESS ===",           None),
    ("display ssh server status",           "SSH (STelnet) enabled?"),
    ("display ssh server session",          "Active SSH sessions"),
    ("display telnet server status",        "Telnet enabled?"),
    ("display local-user",                  "Local user accounts"),
    ("display aaa configuration",           "AAA scheme / domains"),
    ("display acl all",                     "Access control lists"),

    ("=== NTP ===",                         None),
    ("display ntp-service status",          "NTP sync status"),
    ("display ntp-service sessions",        "NTP server connections"),

    ("=== LOGGING ===",                     None),
    ("display logbuffer",                   "Recent system logs"),
    ("display info-center",                 "Log destinations"),

    ("=== FULL CONFIGURATION ===",          None),
    ("display current-configuration",       "Complete running config"),
    ("display saved-configuration",         "Saved config (compare with running)"),
]


class SwitchConsole:
    """Direct serial connection to Huawei switch with verbose output."""

    def __init__(self, port, baud, logfile=None):
        self.port = port
        self.baud = baud
        self.ser = None
        self.logfile = logfile
        self.log_fh = None

    def log(self, text):
        """Write to log file if open."""
        if self.log_fh:
            self.log_fh.write(text)
            self.log_fh.flush()

    def verbose(self, label, text):
        """Print verbose console I/O with direction indicator."""
        if not text.strip():
            return
        for line in text.split('\n'):
            print(f"  {label} {line}")

    def connect(self):
        """Open serial port."""
        print(f"\n[*] Opening {self.port} at {self.baud}...")
        try:
            self.ser = serial.Serial(
                port=self.port,
                baudrate=self.baud,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=TIMEOUT,
                xonxoff=False,
                rtscts=False,
                dsrdtr=False
            )
            time.sleep(0.5)

            # Flush any stale data
            self.ser.reset_input_buffer()
            self.ser.reset_output_buffer()

            print(f"[*] Serial port opened: {self.ser.name}")
            print(f"[*] DSR={self.ser.dsr}, CTS={self.ser.cts}, RI={self.ser.ri}, CD={self.ser.cd}")
            return True

        except serial.SerialException as e:
            print(f"[ERROR] Cannot open serial port: {e}")
            return False

    def send(self, text):
        """Send text to switch and show it."""
        self.verbose("TX >>>", text)
        self.log(f"{text}\n")
        self.ser.write((text + "\r\n").encode('ascii', errors='replace'))
        self.ser.flush()

    def read_until_prompt(self, timeout=15, extra_wait=0.5):
        """
        Read all output until we see a Huawei prompt like <SwitchName> or [SwitchName].
        Handles ---- More ---- pagination automatically.
        Returns the collected output.
        """
        output = ""
        deadline = time.time() + timeout
        idle_since = time.time()

        while time.time() < deadline:
            # Read available bytes
            waiting = self.ser.in_waiting
            if waiting > 0:
                chunk = self.ser.read(waiting).decode('utf-8', errors='replace')
                output += chunk
                idle_since = time.time()

                # Show in real-time
                for line in chunk.split('\n'):
                    if line.strip():
                        print(f"  RX <<< {line.rstrip()}")

                self.log(chunk)

                # Handle ---- More ---- (Huawei shows "  ---- More ----")
                last = output.split('\n')[-1]
                if '---- More ----' in last or '--More--' in last:
                    time.sleep(0.2)
                    self.ser.write(b" ")  # space to continue
                    self.ser.flush()
                    output = output.replace('---- More ----', '').replace('--More--', '')
                    continue

                # Check for Huawei prompt at end of output
                last_line = output.strip().split('\n')[-1].strip() if output.strip() else ""
                if (last_line.startswith('<') and last_line.endswith('>')) or \
                   (last_line.startswith('[') and last_line.endswith(']')):
                    # Wait a tiny bit more to make sure nothing else is coming
                    time.sleep(extra_wait)
                    remaining = self.ser.in_waiting
                    if remaining > 0:
                        continue  # more data coming
                    break

            else:
                # No data — check idle timeout
                if time.time() - idle_since > 3:
                    break
                time.sleep(0.1)

        return output

    def test_connection(self):
        """
        Send Enter and verify we get a Huawei prompt back.
        This confirms we're actually connected to a switch.
        """
        print("\n[*] Testing connection — sending Enter...")

        # Clear any buffered data
        self.ser.reset_input_buffer()
        time.sleep(0.3)

        # Send a blank line
        self.ser.write(b"\r\n")
        self.ser.flush()

        # Wait and read response
        time.sleep(2)
        response = ""
        for _ in range(10):
            waiting = self.ser.in_waiting
            if waiting > 0:
                chunk = self.ser.read(waiting).decode('utf-8', errors='replace')
                response += chunk
                for line in chunk.split('\n'):
                    if line.strip():
                        print(f"  RX <<< {line.rstrip()}")
                time.sleep(0.3)
            else:
                time.sleep(0.5)

        if not response.strip():
            print()
            print("[WARNING] No response from switch!")
            print("         Check that:")
            print("         1. The console cable is plugged into BOTH the laptop and the switch")
            print("         2. The switch is powered on")
            print("         3. You're using the correct serial port")
            print()
            answer = input("Continue anyway? (y/N): ").strip().lower()
            return answer == 'y', response

        # Check if we see a login prompt or a switch prompt
        has_prompt = False
        needs_login = False

        if 'Username' in response or 'login' in response.lower():
            needs_login = True
            has_prompt = True
            print("\n[*] Login prompt detected — switch is connected!")
        elif '<' in response and '>' in response:
            has_prompt = True
            print("\n[*] Switch prompt detected — already logged in!")
        elif '[' in response and ']' in response:
            has_prompt = True
            print("\n[*] Switch config prompt detected — already in system-view!")
        elif 'Password' in response:
            needs_login = True
            has_prompt = True
            print("\n[*] Password prompt detected — switch is connected!")
        else:
            print(f"\n[WARNING] Got response but doesn't look like a Huawei prompt:")
            print(f"          '{response.strip()[:100]}'")
            answer = input("Continue anyway? (y/N): ").strip().lower()
            return answer == 'y', response

        return has_prompt, response

    def login(self, username, password):
        """Send credentials to the switch."""
        print("\n[*] Attempting login...")

        # Clear buffer
        self.ser.reset_input_buffer()

        # Send Enter to trigger prompt
        self.ser.write(b"\r\n")
        self.ser.flush()
        time.sleep(2)

        response = ""
        for _ in range(5):
            waiting = self.ser.in_waiting
            if waiting > 0:
                chunk = self.ser.read(waiting).decode('utf-8', errors='replace')
                response += chunk
                for line in chunk.split('\n'):
                    if line.strip():
                        print(f"  RX <<< {line.rstrip()}")
                time.sleep(0.3)
            else:
                time.sleep(0.5)

        # Already at prompt?
        last_line = response.strip().split('\n')[-1].strip() if response.strip() else ""
        if (last_line.startswith('<') and last_line.endswith('>')) or \
           (last_line.startswith('[') and last_line.endswith(']')):
            print("[*] Already logged in!")
            return True

        # Need to send username?
        if 'Username' in response or 'login' in response.lower():
            print(f"  TX >>> {username}")
            self.ser.write((username + "\r\n").encode('ascii'))
            self.ser.flush()
            time.sleep(2)

            # Read password prompt
            response = ""
            for _ in range(5):
                waiting = self.ser.in_waiting
                if waiting > 0:
                    chunk = self.ser.read(waiting).decode('utf-8', errors='replace')
                    response += chunk
                    for line in chunk.split('\n'):
                        if line.strip():
                            print(f"  RX <<< {line.rstrip()}")
                    time.sleep(0.3)
                else:
                    time.sleep(0.5)

        # Send password
        if 'Password' in response or 'assword' in response:
            print(f"  TX >>> ********")
            self.ser.write((password + "\r\n").encode('ascii'))
            self.ser.flush()
            time.sleep(3)

            # Read result
            response = ""
            for _ in range(10):
                waiting = self.ser.in_waiting
                if waiting > 0:
                    chunk = self.ser.read(waiting).decode('utf-8', errors='replace')
                    response += chunk
                    for line in chunk.split('\n'):
                        if line.strip():
                            print(f"  RX <<< {line.rstrip()}")
                    time.sleep(0.3)
                else:
                    time.sleep(0.5)

            if '<' in response or '[' in response:
                print("\n[*] Login successful!")
                return True
            else:
                print("\n[ERROR] Login failed — check username/password")
                return False

        print("[WARNING] Could not detect login flow")
        return False

    def disable_paging(self):
        """Disable ---- More ---- pagination (Huawei: screen-length 0 temporary)."""
        print("\n[*] Disabling pagination...")
        self.send("screen-length 0 temporary")
        time.sleep(1)
        self.read_until_prompt(timeout=5)

    def run_command(self, cmd, description=""):
        """Run a command and return output."""
        self.send(cmd)
        time.sleep(0.5)
        output = self.read_until_prompt(timeout=30)
        return output

    def close(self):
        """Close serial port."""
        if self.ser and self.ser.is_open:
            self.ser.close()
            print("[*] Serial port closed.")


def banner():
    print("""
╔══════════════════════════════════════════════════════════╗
║    Huawei Switch Discovery Script (Verbose)              ║
║    Shows all console I/O in real-time                    ║
╚══════════════════════════════════════════════════════════╝
""")


def check_serial_port():
    if not os.path.exists(SERIAL_PORT):
        print(f"[ERROR] Serial port not found: {SERIAL_PORT}")
        print()
        print("Available ports:")
        ports = glob.glob("/dev/tty.usb*") + glob.glob("/dev/tty.serial*")
        if ports:
            for p in ports:
                print(f"  {p}")
        else:
            print("  (none found — is your USB console cable plugged in?)")
        sys.exit(1)
    else:
        print(f"[OK] Serial port found: {SERIAL_PORT}")


def get_credentials():
    print(f"\nSerial port: {SERIAL_PORT}")
    print(f"Baud rate:   {BAUD_RATE}")
    print()

    switch_name = input("Switch name (for log filename, e.g. CBS01 or Core): ").strip()
    if not switch_name:
        switch_name = "unknown_switch"
    switch_name = switch_name.replace(" ", "_").replace("/", "_")

    username = input("Username [admin]: ").strip()
    if not username:
        username = "admin"

    password = getpass.getpass("Password: ")

    return switch_name, username, password


def main():
    banner()
    check_serial_port()

    switch_name, username, password = get_credentials()

    # Create log directory
    log_dir = os.path.expanduser("~/huawei_switch_logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_file = os.path.join(log_dir, f"HUAWEI_{switch_name}_{timestamp}.log")

    console = SwitchConsole(SERIAL_PORT, BAUD_RATE)

    try:
        # Connect
        if not console.connect():
            sys.exit(1)

        # Test connection
        connected, initial_response = console.test_connection()
        if not connected:
            print("[ERROR] No switch detected. Exiting.")
            console.close()
            sys.exit(1)

        # Login
        if not console.login(username, password):
            console.close()
            sys.exit(1)

        # Open log file
        console.log_fh = open(log_file, "w")
        console.log(f"{'='*70}\n")
        console.log(f" Huawei Switch Discovery Log\n")
        console.log(f" Switch:    {switch_name}\n")
        console.log(f" Port:      {SERIAL_PORT}\n")
        console.log(f" Date:      {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        console.log(f"{'='*70}\n\n")

        # Disable paging
        console.disable_paging()

        # Run all commands
        total_cmds = sum(1 for c, d in COMMANDS if d is not None)
        cmd_count = 0

        print(f"\n[*] Running {total_cmds} commands...\n")

        for cmd, description in COMMANDS:
            if description is None:
                section = f"\n{'#'*70}\n# {cmd}\n{'#'*70}\n"
                console.log(section)
                print(f"\n{'─'*60}")
                print(f"  {cmd}")
                print(f"{'─'*60}")
                continue

            cmd_count += 1
            print(f"\n[{cmd_count}/{total_cmds}] {cmd} — {description}")
            print(f"{'·'*50}")

            console.log(f"\n{'─'*70}\n")
            console.log(f"[{cmd_count}/{total_cmds}] {cmd}\n")
            console.log(f"# {description}\n")
            console.log(f"{'─'*70}\n")

            try:
                output = console.run_command(cmd, description)
            except Exception as e:
                print(f"  ⚠ Command failed: {e}")
                console.log(f"[ERROR] {e}\n")

            time.sleep(0.3)

        # Done
        console.log(f"\n\n{'='*70}\n")
        console.log(f" Discovery complete: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        console.log(f"{'='*70}\n")

        print(f"""
╔══════════════════════════════════════════════════════════╗
║  Discovery complete!                                     ║
║                                                          ║
║  Log: ~/huawei_switch_logs/                             ║
║  {os.path.basename(log_file):<55s} ║
║  Size: {os.path.getsize(log_file):>10,} bytes                              ║
║                                                          ║
║  Unplug → plug into next switch → run again              ║
╚══════════════════════════════════════════════════════════╝
""")

    except KeyboardInterrupt:
        print("\n\n[*] Interrupted. Saving and exiting...")
    except Exception as e:
        print(f"\n[ERROR] {e}")
        import traceback
        traceback.print_exc()
    finally:
        if console.log_fh:
            console.log_fh.close()
        console.close()


if __name__ == "__main__":
    main()
