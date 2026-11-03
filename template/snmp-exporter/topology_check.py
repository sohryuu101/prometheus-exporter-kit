#!/usr/bin/env python3
"""Check that a site produces the data network_get_topology needs.

Three checks, so the same topology comes out of every site:

  modules    Compare a site's snmp.yml with the template's. The standard topology
             modules must be present and byte-identical, because a module that
             differs by one label changes what Prometheus holds. The vendor modules
             checked follow --vendor (h3c by default).

  conflicts  Before loading an extra module file next to a live snmp.yml, list the
             modules both define. snmp_exporter refuses to start on a duplicate.

  data       Ask Prometheus, per monitored switch, whether every metric and label
             the topology tool reads is present.

Usage:
  topology_check.py modules --template template/snmp-exporter/snmp.yml [--vendor h3c|huawei] SITE_SNMP_YML...
  topology_check.py conflicts --live SITE_SNMP_YML EXTRA_YML
  topology_check.py data --prometheus URL --station site-a [--label station_name]

Exit status is 0 only when everything required is present. Standard library only.
"""
import argparse
import json
import re
import sys
import urllib.parse
import urllib.request

# The standard topology modules: one per MIB, named after the MIB. They are the
# same for every vendor.
STANDARD_MODULES = [
    "lldp_mib",                   # LLDP-MIB: neighbours
    "q_bridge_mib",               # Q-BRIDGE-MIB: MAC table
    "bridge_mib",                 # BRIDGE-MIB: spanning tree
    "etherlike_mib",              # EtherLike-MIB: duplex, FCS errors
]

# The vendor modules, which a site needs only for the vendor of its switches.
VENDOR_MODULES = {
    "h3c": [
        "hh3c_entity_ext_mib",        # HH3C-ENTITY-EXT-MIB: CPU, memory, temperature
        "hh3c_lsw_devm_mib",          # HH3C-LswDEVM-MIB: fan, power
        "hh3c_transceiver_info_mib",  # HH3C-TRANSCEIVER-INFO-MIB: optics
    ],
    "huawei": [
        "huawei_entity_extent_mib",   # HUAWEI-ENTITY-EXTENT-MIB: CPU, memory, temperature, optics
    ],
}

# Modules the topology also reads from, which each site keeps in its own fast job.
# Only their metric names are checked: the sites define them differently.
SITE_MODULES = {
    "if_mib": ["ifOperStatus", "ifAdminStatus", "ifHighSpeed"],
    "fdb": ["dot1dBasePortIfIndex"],
    "arp_table": ["arp_entry"],
}


def module_blocks(path):
    text = open(path).read()
    _, _, body = text.partition("\nmodules:\n")
    parts = [p for p in re.split(r"^(?=  \S+:\n)", body, flags=re.M) if p]
    return {re.match(r"  (\S+):\n", p).group(1): p for p in parts}


def check_conflicts(live, extra):
    both = sorted(set(module_blocks(live)) & set(module_blocks(extra)))
    for name in both:
        print(f"  CONFLICT   {name}  (defined in both files)")
    if not both:
        print("  no module is defined in both files")
    return len(both)


def check_modules(template, sites, vendor="h3c"):
    canonical = module_blocks(template)
    bad = 0
    required = STANDARD_MODULES + VENDOR_MODULES[vendor]
    for name in required:
        if name not in canonical:
            print(f"TEMPLATE is missing the standard module {name}")
            bad += 1
    for site in sites:
        blocks = module_blocks(site)
        print(f"\n{site}")
        for name in required:
            if name not in blocks:
                print(f"  MISSING    {name}")
                bad += 1
            elif blocks[name] != canonical.get(name):
                print(f"  DIFFERENT  {name}  (not byte-identical to the template)")
                bad += 1
            else:
                print(f"  ok         {name}")
        for name, metrics in SITE_MODULES.items():
            block = blocks.get(name)
            if block is None:
                print(f"  MISSING    {name}  (the topology joins on it)")
                bad += 1
                continue
            lost = [m for m in metrics if f"name: {m}\n" not in block]
            if lost:
                print(f"  INCOMPLETE {name}  lacks {', '.join(lost)}")
                bad += 1
            else:
                print(f"  ok         {name}  ({', '.join(metrics)})")
    return bad


def query(base, expr):
    url = base.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.load(resp)["data"]["result"]


def check_data(base, station, label):
    sel = "{%s=%s}" % (label, json.dumps(station))
    series = {}

    def get(metric):
        if metric not in series:
            series[metric] = query(base, metric + sel)
        return series[metric]

    def devices(metric):
        return {r["metric"].get("instance", "?") for r in get(metric)}

    instances = sorted(devices("lldpLocChassisId") | devices("ifOperStatus"))
    if not instances:
        print(f"no LLDP or interface data for {label}={station} at {base}")
        return 1

    # (description, metric alternatives, required labels per alternative, required?)
    needs = [
        ("LLDP identity", [("lldpLocChassisId", ["lldpLocChassisId"])], True),
        ("LLDP neighbours", [("lldpRemChassisIdSubtype", ["lldpRemLocalPortNum", "lldpRemChassisId", "lldpRemPortId"])], False),
        # Names each local LLDP port. Needed where the number a neighbour is reported
        # against is not the ifIndex (Huawei: it is the bridge port number).
        ("LLDP ports", [("lldpLocPortIdSubtype", ["lldpLocPortNum", "lldpLocPortId"])], False),
        ("link state", [("ifOperStatus", ["ifIndex", "ifName"])], True),
        ("admin state", [("ifAdminStatus", ["ifIndex", "ifName"])], True),
        ("speed", [("ifHighSpeed", ["ifIndex", "ifName"])], True),
        ("bridge ports", [("dot1dBasePortIfIndex", ["dot1dBasePort"])], True),
        ("MAC table", [("dot1qTpFdbPort", ["dot1qTpFdbAddress"]),
                       ("dot1dTpFdbPort", ["dot1dTpFdbAddress"]),
                       ("dot1dTpFdbPort", ["dot1dMac"])], True),
        ("ARP", [("arp_entry", ["arp_entry", "ipNetToMediaNetAddress"]),
                 ("arp_entry", ["arp_entry", "ipAddress"])], False),
        # Health and optics come from the vendor's MIB: H3C or Huawei, either one.
        ("health", [("hh3cEntityExtCpuUsage", ["entPhysicalName"]),
                    ("hwEntityCpuUsage", ["entPhysicalName"])], False),
        ("optics", [("hh3cTransceiverCurRXPower", ["ifIndex"]),
                    ("hwEntityOpticalRxPower", ["entPhysicalName"])], False),
    ]

    bad = 0
    width = max(len(n) for n, _, _ in needs)
    print(f"{label}={station}: {len(instances)} devices\n")
    print("  " + "device".ljust(26) + "".join(n.ljust(width + 2) for n, _, _ in needs))
    for inst in instances:
        cells = []
        for _, alternatives, required in needs:
            status = "-"
            for metric, labels in alternatives:
                rows = [r for r in get(metric) if r["metric"].get("instance") == inst]
                if rows and all(all(l in r["metric"] for l in labels) for r in rows):
                    status = "ok"
                    break
                if rows:
                    status = "LABELS"  # present, but a label the tool reads is missing
            if status != "ok" and required:
                bad += 1
                status = status if status == "LABELS" else "MISSING"
            elif status == "-":
                status = "(none)"
            cells.append(status.ljust(width + 2))
        print("  " + inst[:25].ljust(26) + "".join(cells))
    print("\nMISSING/LABELS = required and absent; (none) = optional and absent, the result is less detailed")
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("modules")
    m.add_argument("--template", default="template/snmp-exporter/snmp.yml")
    m.add_argument("--vendor", choices=sorted(VENDOR_MODULES), default="h3c")
    m.add_argument("sites", nargs="+")
    c = sub.add_parser("conflicts")
    c.add_argument("--live", required=True)
    c.add_argument("extra")
    d = sub.add_parser("data")
    d.add_argument("--prometheus", required=True)
    d.add_argument("--station", required=True)
    d.add_argument("--label", default="station_name")
    args = ap.parse_args()
    if args.cmd == "modules":
        bad = check_modules(args.template, args.sites, args.vendor)
    elif args.cmd == "conflicts":
        bad = check_conflicts(args.live, args.extra)
    else:
        bad = check_data(args.prometheus, args.station, args.label)
    print("\nOK" if not bad else f"\n{bad} problem(s)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
