#!/usr/bin/env python3
"""Extract CodeView S_COMPILE3 records from a 32-bit COFF object."""

import json
import struct
import sys


def u16(data, offset):
    return struct.unpack_from("<H", data, offset)[0]


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def main():
    with open(sys.argv[1], "rb") as source:
        data = source.read()
    if len(data) < 20:
        raise SystemExit("short COFF header")
    machine, section_count = struct.unpack_from("<HH", data, 0)
    optional_size = u16(data, 16)
    sections = 20 + optional_size
    records = []
    for index in range(section_count):
        base = sections + index * 40
        if base + 40 > len(data):
            raise SystemExit("truncated section table")
        name = data[base : base + 8].rstrip(b"\0")
        if name != b".debug$S":
            continue
        size = u32(data, base + 16)
        pointer = u32(data, base + 20)
        section = data[pointer : pointer + size]
        if len(section) < 4 or u32(section, 0) != 4:
            continue
        cursor = 4
        while cursor + 8 <= len(section):
            subsection_kind = u32(section, cursor)
            subsection_size = u32(section, cursor + 4)
            body_start = cursor + 8
            body_end = body_start + subsection_size
            if body_end > len(section):
                raise SystemExit("truncated CodeView subsection")
            if subsection_kind == 0xF1:
                symbol = body_start
                while symbol + 4 <= body_end:
                    record_length = u16(section, symbol)
                    record_end = symbol + 2 + record_length
                    if record_length < 2 or record_end > body_end:
                        raise SystemExit("truncated CodeView symbol record")
                    record_kind = u16(section, symbol + 2)
                    if record_kind == 0x113C:
                        if record_length < 24:
                            raise SystemExit("short S_COMPILE3 record")
                        frontend = [u16(section, symbol + offset) for offset in (10, 12, 14, 16)]
                        backend = [u16(section, symbol + offset) for offset in (18, 20, 22, 24)]
                        raw_name = section[symbol + 26 : record_end]
                        version_name = raw_name.split(b"\0", 1)[0].decode("ascii", "replace")
                        records.append(
                            {
                                "machine": machine,
                                "frontend": ".".join(map(str, frontend)),
                                "backend": ".".join(map(str, backend)),
                                "version_name": version_name,
                            }
                        )
                    symbol = record_end
            cursor = (body_end + 3) & ~3
    if not records:
        raise SystemExit("no S_COMPILE3 record found")
    print(json.dumps(records, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
