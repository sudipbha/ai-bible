#!/usr/bin/env python3
"""Checks that a pinned simulator device type and runtime exist, are available, and are
compatible, using `xcrun simctl list devicetypes -j` and `xcrun simctl list runtimes -j` output.

It never downloads a runtime and never substitutes another device. Exit 0 and a one-line
summary when the pair can be created; exit 1 with the reason otherwise.

  python3 ci/simulator_preflight.py --device-type <id> --runtime <id> \
      --devicetypes-json <file> --runtimes-json <file>
"""

import argparse
import json
import sys


def check(devicetypes, runtimes, device_type, runtime):
    types = {t.get("identifier"): t for t in devicetypes.get("devicetypes", [])}
    if device_type not in types:
        return False, f"device type {device_type} is not installed with this Xcode"
    found = [r for r in runtimes.get("runtimes", []) if r.get("identifier") == runtime]
    if not found:
        return False, f"runtime {runtime} is not installed"
    entry = found[0]
    if not entry.get("isAvailable"):
        return False, f"runtime {runtime} is installed but unavailable: {entry.get('availabilityError', 'no reason given')}"
    supported = entry.get("supportedDeviceTypes")
    if supported is None:
        return False, f"runtime {runtime} does not list supported device types, so support can't be confirmed"
    if device_type not in {s.get("identifier") for s in supported}:
        return False, f"runtime {runtime} does not support device type {device_type}"
    return True, f"{types[device_type].get('name', device_type)} on {entry.get('name', runtime)} ({entry.get('buildversion', 'build unknown')})"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device-type", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--devicetypes-json", required=True)
    parser.add_argument("--runtimes-json", required=True)
    args = parser.parse_args(argv)
    with open(args.devicetypes_json, encoding="utf-8") as f:
        devicetypes = json.load(f)
    with open(args.runtimes_json, encoding="utf-8") as f:
        runtimes = json.load(f)
    ok, message = check(devicetypes, runtimes, args.device_type, args.runtime)
    print(message, file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
