#!/usr/bin/env python3
"""Patch only Armbian firstlogin's fragile Wi-Fi connection block."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys


MARKER = "# AIC image customizer: robust first-login Wi-Fi"
HELPER = "/usr/local/sbin/armbian-firstlogin-wifi-connect"

BRING_UP_OLD = """\
\t\t\t\t# bring up wifi device (not done by networkd, only by NetworkManager)
\t\t\t\tip link set ${WIFI_DEVICE} up
"""

BRING_UP_NEW = """\
\t\t\t\t# Unblock the adapter before scanning. AIC firmware can expose the
\t\t\t\t# interface while rfkill still reports it as soft-blocked.
\t\t\t\tif command -v rfkill >/dev/null 2>&1; then
\t\t\t\t\trfkill unblock wifi >/dev/null 2>&1 || rfkill unblock all >/dev/null 2>&1 || true
\t\t\t\tfi
\t\t\t\tip link set dev "$WIFI_DEVICE" up
"""

START = "\t\t\t\t\t\t# generate config\n"
END = "\n\t\t\t\tfi # detected or not detected wireless network\n"

CONNECTION_NEW = f"""\
\t\t\t\t\t\t{MARKER}
\t\t\t\t\t\tif printf '%s' "$password" | {HELPER} "$WIFI_DEVICE" "$SSID"; then
\t\t\t\t\t\t\tbroken=0
\t\t\t\t\t\t\t# Public IP is optional and is used only for locale detection.
\t\t\t\t\t\t\t# Never discard a valid local Wi-Fi link when this service is down.
\t\t\t\t\t\t\tPUBLIC_IP=$(curl --max-time 5 -s https://ipinfo.io/ip || true)
\t\t\t\t\t\t\tbreak
\t\t\t\t\t\tfi
\t\t\t\t\t\tbroken=1
\t\t\t\t\t\techo -e "\\n\\x1B[91mUnable to connect to Access Point\\x1B[0m.\\n"
\t\t\t\t\tdone
"""

SSID_OLD = "\t\t\t\t\t\t\tSSID=$(echo ${ARRAY[$input-1]} | cut -d\",\" -f2-)\n"
SSID_NEW = "\t\t\t\t\t\t\tSSID=$(printf '%s\\n' \"${ARRAY[$((input - 1))]}\" | cut -d, -f2-)\n"


def is_patched(text: str) -> bool:
    return BRING_UP_NEW in text and CONNECTION_NEW in text and SSID_NEW in text


def patch(text: str) -> str:
    if is_patched(text):
        return text

    if text.count(BRING_UP_OLD) != 1:
        raise ValueError("expected exactly one original Wi-Fi bring-up block")
    if text.count(SSID_OLD) != 1:
        raise ValueError("expected exactly one original SSID selection line")

    start = text.find(START)
    if start < 0:
        raise ValueError("original Wi-Fi configuration block start was not found")
    end = text.find(END, start)
    if end < 0:
        raise ValueError("original Wi-Fi configuration block end was not found")

    text = text.replace(BRING_UP_OLD, BRING_UP_NEW, 1)
    text = text.replace(SSID_OLD, SSID_NEW, 1)
    start = text.find(START)
    end = text.find(END, start)
    return text[:start] + CONNECTION_NEW + text[end:]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("firstlogin", type=Path)
    args = parser.parse_args()

    text = args.firstlogin.read_text(encoding="utf-8")
    if args.check:
        if not is_patched(text):
            print(f"{args.firstlogin}: robust Wi-Fi patch is missing", file=sys.stderr)
            return 1
        return 0

    try:
        patched = patch(text)
    except ValueError as error:
        print(f"{args.firstlogin}: {error}", file=sys.stderr)
        return 1
    args.firstlogin.write_text(patched, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
