#!/usr/bin/env python3
"""Print one available iOS simulator UDID; never select a physical device.

Without --udid, exactly one booted iOS simulator is required. With --udid,
the selected simulator may be shut down unless --booted is also supplied.
"""
import argparse
import json
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", help="Explicit iOS simulator UDID")
    parser.add_argument("--booted", action="store_true", help="Require a booted device")
    args = parser.parse_args()
    state = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
    devices = [device for runtime, group in state["devices"].items()
               if ".iOS-" in runtime for device in group
               if device.get("isAvailable", True)]
    if args.udid:
        devices = [device for device in devices if device["udid"] == args.udid]
        if args.booted:
            devices = [device for device in devices if device["state"] == "Booted"]
    else:
        devices = [device for device in devices if device["state"] == "Booted"]
    if len(devices) != 1:
        parser.exit(2, "Select exactly one available iOS simulator: boot one device, "
                    "or pass an explicit simulator UDID. Use xcrun simctl list devices available "
                    "to inspect devices; physical iPhones are never selected.\n")
    print(devices[0]["udid"])


if __name__ == "__main__":
    main()
