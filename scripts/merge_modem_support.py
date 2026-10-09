#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Merge out-of-tree modem definitions into QModem's support library, at build time.

Why this runs in the build rather than on the device
----------------------------------------------------
QModem's ``modem_scand`` reads ``/usr/share/qmodem/modem_support.json`` exactly
once, when it starts, and keeps that copy in memory for its whole lifetime.
The library shipped by the QModem package does not know about every modem this
board can carry (Quectel RG520N-CN is the one that matters here); that entry
arrives in a *separate* package (``luci-app-qmodem-generic``) and is merged at
runtime by ``/usr/sbin/qmodem-modem-support``.

Merging at runtime races the daemon and loses:

* 13.6 s — the USB modem binds; ``/etc/hotplug.d/usb/20-modem-usb`` fires
* 14.5 s — ``modem_scan.sh``'s ``scanc`` fallback sees rc=2 ("no daemon"),
           runs ``/etc/init.d/qmodem_init start`` and the daemon starts here,
           reading the **unmerged** library
* 15.6 s — rc.d finally reaches the merge service and the file gains the entry
* forever — the daemon still holds the old library, so every scan reports
           ``slot=2-1 type=usb modem profile not matched``, and the retry
           budget (5 attempts) is spent before anything can change

Moving the merge into rc.d (``START=78``, ahead of ``qmodem_init``'s ``80``)
does **not** help, because the hotplug path starts the daemon without ever
going through rc.d.  Measured on hardware, 2026-10-09: daemon at 14.52 s,
merge at 15.62 s — a 1.1 s loss that costs the modem entirely.

Baking the merged library into the image removes the race instead of trying to
win it: whoever starts the daemon, and whenever, the file it reads is already
correct.  The runtime service stays in place as a no-op safety net for modems
whose definitions are added after this mirror was assembled.

The merge is byte-for-byte the same as the runtime one; that equivalence is
checked against real hardware output in
``_过程脚本/_merge_modem_support.py --verify`` (77722 B + extra -> 78356 B).

Usage:
    merge_modem_support.py <library.json> <extra.json> [--require MODEL]...
"""

from __future__ import annotations

import argparse
import json
import re
import sys

# In the target file a group header sits at 8 spaces; a model entry is nested
# one level deeper.  The runtime implementation matches these with awk regexes
# anchored to those exact widths, so this has to agree with it character for
# character.
GROUP_RE = r'^        "(usb|pcie)": \{[ \t]*$'
MODEL_RE = r'^            "([^"]+)": \{[ \t]*$'


def list_models(extra_text: str):
    """Yield (group, model) for everything the extra file defines."""
    out = []
    group = None
    for line in extra_text.split("\n"):
        m = re.match(r'^        "(usb|pcie)": \{[ \t]*$', line)
        if m:
            group = m.group(1)
            continue
        if group:
            m2 = re.match(r'^            "([^"]+)": \{[ \t]*$', line)
            if m2:
                out.append((group, m2.group(1)))
    return out


def model_block(extra_lines, model: str):
    """Return the model's own block, braces included, indentation preserved."""
    start = indent = None
    for i, line in enumerate(extra_lines):
        pos = line.find(f'"{model}": {{')
        if pos > 0:
            start, indent = i, pos
            break
    if start is None:
        return None
    block = [extra_lines[start]]
    for line in extra_lines[start + 1:]:
        block.append(line)
        if line[:indent].strip() == "" and line[indent:].startswith("}"):
            break
    return block


def group_has_model(target_text: str, group: str, model: str) -> bool:
    """Look for the model inside its own group only, never across groups."""
    inside = False
    for line in target_text.split("\n"):
        if re.match(GROUP_RE, line):
            inside = bool(re.match(rf'^        "{group}": \{{[ \t]*$', line))
            continue
        if inside:
            if re.match(r'^        \}[,]?[ \t]*$', line):
                inside = False
                continue
            if re.search(rf'"{re.escape(model)}"[ \t]*:[ \t]*\{{', line):
                return True
    return False


def merge(target_text: str, extra_text: str):
    """Return (merged_text, added, skipped). Added models go first in the group."""
    lines = target_text.split("\n")
    extra_lines = extra_text.split("\n")
    added, skipped = [], []

    for group, model in list_models(extra_text):
        if group_has_model("\n".join(lines), group, model):
            skipped.append((group, model))
            continue
        block = model_block(extra_lines, model)
        if not block:
            continue
        placed = False
        for i, line in enumerate(lines):
            if re.match(rf'^        "{group}": \{{[ \t]*$', line):
                block = list(block)
                block[-1] += ","
                lines[i + 1:i + 1] = block
                placed = True
                break
        if not placed:
            raise RuntimeError(f"group {group!r} not found in the target library")
        added.append((group, model))

    return "\n".join(lines), added, skipped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("library", help="QModem's modem_support.json to patch in place")
    ap.add_argument("extra", help="modem definitions to merge in")
    ap.add_argument("--require", action="append", default=[],
                    help="model that must be present in the result; repeatable")
    ap.add_argument("--check", action="store_true",
                    help="report what would change without writing")
    args = ap.parse_args()

    try:
        with open(args.library, encoding="utf-8") as fh:
            target = fh.read()
        with open(args.extra, encoding="utf-8") as fh:
            extra = fh.read()
    except OSError as exc:
        print(f"merge_modem_support: cannot read input: {exc}", file=sys.stderr)
        return 1

    try:
        parsed = json.loads(target)
    except ValueError as exc:
        print(f"merge_modem_support: {args.library} is not valid JSON: {exc}", file=sys.stderr)
        return 1
    if "modem_support" not in parsed:
        print(f"merge_modem_support: {args.library} has no modem_support key", file=sys.stderr)
        return 1

    try:
        merged, added, skipped = merge(target, extra)
    except RuntimeError as exc:
        print(f"merge_modem_support: {exc}", file=sys.stderr)
        return 1

    # The result has to be parseable before it replaces anything, otherwise the
    # image would carry a library no QModem version can read -- and the failure
    # would only show up as "modem not recognised" on the device.
    try:
        json.loads(merged)
    except ValueError as exc:
        print(f"merge_modem_support: merged result is not valid JSON: {exc}", file=sys.stderr)
        return 1

    for model in args.require:
        if f'"{model}"' not in merged:
            print(f"merge_modem_support: required model {model!r} is absent from the result",
                  file=sys.stderr)
            return 1

    for group, model in added:
        print(f"  + {group}/{model}")
    for group, model in skipped:
        print(f"  = {group}/{model} (already present)")

    if not added:
        print("merge_modem_support: nothing to add; the library already carries every entry")
        return 0

    if args.check:
        print("merge_modem_support: --check, not writing")
        return 0

    with open(args.library, "w", encoding="utf-8", newline="") as fh:
        fh.write(merged)
    print(f"merge_modem_support: patched {args.library} "
          f"({len(target.encode())} B -> {len(merged.encode())} B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
