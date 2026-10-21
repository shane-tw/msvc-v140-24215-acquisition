#!/usr/bin/env python
"""Tally @comp.id compiler builds across members of Microsoft COFF archives."""

from __future__ import print_function

import io
import json
import struct
import sys


MAGIC = b"!<arch>\n"
HEADER_SIZE = 60
BIGOBJ_CLASSID = b"\xc7\xa1\xba\xd1\xee\xba\xa9\x4b\xaf\x20\xfa\xf6\x6a\xa4\xdc\xb8"


def members(data):
    offset = len(MAGIC)
    while offset + HEADER_SIZE <= len(data):
        header = data[offset : offset + HEADER_SIZE]
        if header[58:60] != b"`\n":
            raise ValueError("invalid archive member trailer at %d" % offset)
        size = int(header[48:58].decode("ascii").strip())
        name = header[:16].decode("ascii", "replace").rstrip()
        start = offset + HEADER_SIZE
        if start + size > len(data):
            raise ValueError("truncated archive member payload at %d" % offset)
        yield name, start, size
        offset = start + size + (size & 1)


def scan_symbols(data, start, size, pointer, count, record):
    index = 0
    while index < count:
        offset = pointer + index * record
        if offset + record > size:
            return "truncated", None
        if data[start + offset : start + offset + 8] == b"@comp.id":
            return "object", struct.unpack_from("<I", data, start + offset + 8)[0]
        index += 1 + bytearray(data[start + offset + record - 1 : start + offset + record])[0]
    return "object", None


def comp_id(data, start, size):
    if size < 20:
        return "short", None
    sig1, sig2, version = struct.unpack_from("<HHH", data, start)
    if sig1 == 0 and sig2 == 0xFFFF:
        if version == 0:
            return "import", None
        if size >= 56 and data[start + 12 : start + 28] == BIGOBJ_CLASSID:
            pointer, count = struct.unpack_from("<II", data, start + 48)
            return scan_symbols(data, start, size, pointer, count, 20)
        return "anonymous", None
    pointer, count = struct.unpack_from("<II", data, start + 8)
    return scan_symbols(data, start, size, pointer, count, 18)


def tally(path, target):
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(MAGIC):
        return {"path": path, "size": len(data), "error": "not a COFF archive"}
    kinds = {}
    builds = {}
    totals = {}
    member_count = 0
    for name, start, size in members(data):
        if name in ("/", "//"):
            continue
        member_count += 1
        kind, value = comp_id(data, start, size)
        kinds[kind] = kinds.get(kind, 0) + 1
        if value is not None:
            key = "%d:%d" % (value >> 16, value & 0xFFFF)
            builds[key] = builds.get(key, 0) + 1
            build = str(value & 0xFFFF)
            totals[build] = totals.get(build, 0) + 1
    dominant = max(totals, key=totals.get) if totals else None
    return {
        "path": path,
        "size": len(data),
        "members": member_count,
        "kinds": kinds,
        "prodid_builds": builds,
        "build_totals": totals,
        "dominant_build": dominant,
        "target_objects": totals.get(str(target), 0),
    }


def main():
    if len(sys.argv) != 4:
        sys.stderr.write("usage: mfc_lib_builds.py <path-list> <target-build> <out.json>\n")
        return 2
    with io.open(sys.argv[1], encoding="utf-8-sig") as handle:
        paths = [line.strip() for line in handle if line.strip()]
    target = int(sys.argv[2])
    rows = []
    for path in paths:
        try:
            rows.append(tally(path, target))
        except Exception as error:
            rows.append({"path": path, "error": str(error)})
    with io.open(sys.argv[3], "w", encoding="utf-8") as handle:
        handle.write(json.dumps(rows, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
