"""Reads `xcrun simctl list devices available -j` from stdin and prints the
UDID of an iPhone on the newest iOS runtime."""
import json
import re
import sys

data = json.load(sys.stdin)
best = None
for runtime, devices in data["devices"].items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            if best is None or version > best[0]:
                best = (version, device["udid"])
            break

if best is None:
    sys.exit("No iPhone simulator found")
print(best[1])
