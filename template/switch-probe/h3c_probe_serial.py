#!/usr/bin/env python3
"""
H3C Comware7 Switch Probe — runs on Mac, talks over USB-serial console cable.
No platformtools dependency, no flash upload. Sends CLI cmds over serial,
captures output, saves to local file.

Requires: pip3 install pyserial

Usage:
    python3 h3c_probe_serial.py --port /dev/tty.usbserial-XXXX --name SW-CORE-01
    python3 h3c_probe_serial.py --port /dev/tty.usbserial-XXXX --name SW-CORE-01 --user admin --password xxxx

List available ports:
    python3 h3c_probe_serial.py --list-ports
"""
import argparse
import re
import sys
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("Missing pyserial. Run: pip3 install pyserial --break-system-packages")
    sys.exit(1)

SECTIONS = [
    ("IDENTITY & HEALTH", [
        "display version",
        "display device",
        "display environment",
        "display power",
        "display cpu-usage",
        "display memory",
        "display clock",
    ]),
    ("IRF STACK", [
        "display irf",
        "display irf topology",
        "display irf link",
    ]),
    ("INTERFACES", [
        "display interface brief",
        "display ip interface brief",
        "display transceiver interface brief",
    ]),
    ("VLANS", [
        "display vlan all",
    ]),
    ("LLDP NEIGHBORS", [
        "display lldp neighbor-information list",
        "display lldp neighbor-information verbose",
        "display lldp local-information",
    ]),
    ("LINK AGGREGATION", [
        "display link-aggregation summary",
    ]),
    ("ARP & MAC TABLE", [
        "display arp",
        "display mac-address",
    ]),
    ("ROUTING", [
        "display ip routing-table",
    ]),
    ("SPANNING TREE", [
        "display stp brief",
    ]),
    ("SNMP", [
        "display snmp-agent sys-info",
        "display snmp-agent community",
        "display snmp-agent statistics",
    ]),
    ("SECURITY & ACCESS", [
        "display ssh server status",
        "display telnet server status",
        "display local-user",
        "display password-control",
        "display acl all",
    ]),
    ("NTP", [
        "display ntp-service status",
        "display ntp-service sessions",
    ]),
    ("LOGGING", [
        "display logbuffer",
        "display info-center",
    ]),
    ("FULL CONFIGURATION", [
        "display current-configuration",
        "display saved-configuration",
    ]),
]

PROMPT_RE = re.compile(rb'[\]>]\s*$')
LOGIN_RE = re.compile(rb'(Username|Login)\s*:?\s*$', re.IGNORECASE)
PASS_RE = re.compile(rb'Password\s*:?\s*$', re.IGNORECASE)
MORE_RE = re.compile(rb'---- More ----')


def list_ports():
    ports = serial.tools.list_ports.comports()
    if not ports:
        print("No serial ports found.")
        return
    for p in ports:
        print(f"{p.device}  -  {p.description}")


def read_until_prompt(ser, timeout=20, idle_gap=0.4):
    """Read from serial until switch prompt settles, or timeout."""
    buf = b""
    last_read = time.time()
    deadline = time.time() + timeout
    while time.time() < deadline:
        chunk = ser.read(4096)
        if chunk:
            buf += chunk
            last_read = time.time()
            if MORE_RE.search(buf):
                ser.write(b' ')  # send space to page through
                buf = MORE_RE.sub(b'', buf)
                continue
            if PROMPT_RE.search(buf) and (time.time() - last_read) > idle_gap:
                # give buffer a moment to make sure nothing else trailing
                time.sleep(idle_gap)
                more = ser.read(4096)
                if more:
                    buf += more
                    continue
                break
        else:
            if buf and PROMPT_RE.search(buf) and (time.time() - last_read) > idle_gap:
                break
            time.sleep(0.05)
    return buf.decode(errors='replace')


def send_line(ser, line):
    ser.write(line.encode() + b'\r')


def do_login(ser, user, password, timeout=15):
    buf = b""
    deadline = time.time() + timeout
    sent_user = sent_pass = False
    while time.time() < deadline:
        chunk = ser.read(4096)
        if chunk:
            buf += chunk
            if LOGIN_RE.search(buf) and not sent_user:
                send_line(ser, user)
                sent_user = True
                buf = b""
                continue
            if PASS_RE.search(buf) and not sent_pass:
                send_line(ser, password)
                sent_pass = True
                buf = b""
                continue
            if PROMPT_RE.search(buf) and sent_pass:
                return True
        else:
            time.sleep(0.05)
    return sent_pass  # best-effort


def run_probe(port, baudrate, switch_name, user, password, out_path):
    ser = serial.Serial(port, baudrate=baudrate, timeout=1)
    time.sleep(0.3)
    ser.write(b'\r')
    time.sleep(0.5)
    ser.reset_input_buffer()

    if user:
        print(">>> Attempting login...")
        # nudge for login prompt
        ser.write(b'\r')
        do_login(ser, user, password or "")

    ser.reset_input_buffer()
    send_line(ser, 'screen-length disable')
    read_until_prompt(ser, timeout=5)

    lines = []
    header = [
        "=" * 64,
        "H3C SWITCH PROBE REPORT (via serial console)",
        f"Switch: {switch_name}",
        f"Time: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"Port: {port} @ {baudrate}bps",
        "=" * 64,
    ]
    for h in header:
        print(h)
    lines.extend(header)
    lines.append("")

    for section_name, cmds in SECTIONS:
        block = f"\n{'='*64}\n=== {section_name}\n{'='*64}\n"
        print(block)
        lines.append(block)
        for cmd in cmds:
            cmd_header = f"\n--- {cmd} ---"
            print(cmd_header)
            lines.append(cmd_header)
            send_line(ser, cmd)
            output = read_until_prompt(ser, timeout=25)
            # strip echoed command from first line if present
            cleaned = output
            print(cleaned)
            lines.append(cleaned)

    ser.close()

    content = '\n'.join(lines)
    with open(out_path, 'w') as f:
        f.write(content)
    print(f"\n>>> Saved to {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', help='Serial device, e.g. /dev/tty.usbserial-XXXX')
    ap.add_argument('--baud', type=int, default=9600, help='Baud rate (Comware default 9600)')
    ap.add_argument('--name', default='UNKNOWN', help='Switch name label for report')
    ap.add_argument('--user', default=None, help='Login username (skip if already at CLI prompt)')
    ap.add_argument('--password', default=None, help='Login password')
    ap.add_argument('--out', default='probe_output.txt', help='Output file path')
    ap.add_argument('--list-ports', action='store_true', help='List serial ports and exit')
    args = ap.parse_args()

    if args.list_ports:
        list_ports()
        return

    if not args.port:
        print("Need --port. Use --list-ports to see options.")
        sys.exit(1)

    run_probe(args.port, args.baud, args.name, args.user, args.password, args.out)


if __name__ == '__main__':
    main()
