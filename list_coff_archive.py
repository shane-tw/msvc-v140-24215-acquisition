#!/usr/bin/env python3
"""List physical members of a Microsoft COFF archive without librarian semantics."""

from __future__ import print_function

import argparse
import json
import ntpath
import sys


MAGIC = b"!<arch>\n"
HEADER_SIZE = 60


def parse_decimal(field, label):
    value = field.decode("ascii").strip()
    if not value.isdigit():
        raise ValueError("invalid %s field: %r" % (label, value))
    return int(value)


def resolve_name(raw_name, payload, longnames):
    token = raw_name.decode("ascii").rstrip()
    if token in ("/", "//"):
        return token, payload
    if token.startswith("#1/"):
        length = int(token[3:])
        if length > len(payload):
            raise ValueError("BSD extended name exceeds member payload")
        return payload[:length].decode("utf-8"), payload[length:]
    if token.startswith("/"):
        if longnames is None:
            raise ValueError("long-name reference precedes // table")
        offset = int(token[1:])
        if offset < 0 or offset >= len(longnames):
            raise ValueError("long-name offset outside // table: %d" % offset)
        endings = [
            position
            for position in (
                longnames.find(b"\0", offset),
                longnames.find(b"\n", offset),
            )
            if position >= 0
        ]
        end = min(endings) if endings else len(longnames)
        name = longnames[offset:end].rstrip(b"/\r").decode("utf-8")
        return name, payload
    return token.rstrip("/"), payload


def parse_archive(path):
    data = open(path, "rb").read()
    if not data.startswith(MAGIC):
        raise ValueError("not a COFF archive")
    offset = len(MAGIC)
    longnames = None
    members = []
    physical_index = 0
    while offset < len(data):
        if offset + HEADER_SIZE > len(data):
            raise ValueError("truncated archive member header at %d" % offset)
        header = data[offset : offset + HEADER_SIZE]
        if header[58:60] != b"`\n":
            raise ValueError("invalid archive member trailer at %d" % offset)
        size = parse_decimal(header[48:58], "size")
        payload_start = offset + HEADER_SIZE
        payload_end = payload_start + size
        if payload_end > len(data):
            raise ValueError("truncated archive member payload at %d" % offset)
        payload = data[payload_start:payload_end]
        name, content = resolve_name(header[:16], payload, longnames)
        if name == "//":
            longnames = content
        elif name != "/":
            physical_index += 1
            members.append(
                {
                    "index": physical_index,
                    "name": name,
                    "basename": ntpath.basename(name),
                    "archive_header_offset": offset,
                    "payload_size": len(content),
                }
            )
        offset = payload_end + (size & 1)
    if offset != len(data):
        raise ValueError("archive alignment ended outside file")
    return {"archive": path, "size": len(data), "members": members}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    result = parse_archive(args.archive)
    if args.json:
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        for member in result["members"]:
            print(member["name"])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        sys.stderr.write("error: %s\n" % error)
        sys.exit(1)
