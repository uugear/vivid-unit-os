#!/usr/bin/env python3
"""Create a GPT (with protective MBR) for a raw disk image.

This is intentionally dependency-free (std lib only) so it can be used in CI.

We keep the implementation minimal but correct:
- Protective MBR at LBA0
- Primary GPT header at LBA1 and partition entries at LBA2
- Backup GPT header at last LBA and partition entries right before it

Partition start/end are specified in 512-byte sectors (LBAs).
"""

from __future__ import annotations

import argparse
import os
import struct
import uuid
import zlib

SECTOR = 512


def _crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def _guid_bytes_le(g: uuid.UUID) -> bytes:
    # GPT stores GUIDs in mixed-endian; uuid.bytes_le matches GPT format.
    return g.bytes_le


def _pack_protective_mbr(total_lbas: int) -> bytes:
    # Protective MBR with a single 0xEE partition from LBA1 to end.
    mbr = bytearray(SECTOR)

    # Partition entry starts at offset 446
    # status, chs_first(3), type, chs_last(3), lba_first(u32), lba_count(u32)
    lba_first = 1
    lba_count = min(total_lbas - 1, 0xFFFFFFFF)

    entry = struct.pack(
        "<B3sB3sII",
        0x00,
        b"\x00\x02\x00",  # dummy CHS
        0xEE,
        b"\xFF\xFF\xFF",
        lba_first,
        lba_count,
    )
    mbr[446 : 446 + 16] = entry

    # Signature
    mbr[510:512] = b"\x55\xAA"
    return bytes(mbr)


def _pack_gpt_header(
    *,
    current_lba: int,
    backup_lba: int,
    first_usable_lba: int,
    last_usable_lba: int,
    disk_guid: uuid.UUID,
    part_entry_lba: int,
    num_entries: int,
    entry_size: int,
    part_array_crc: int,
) -> bytes:
    header_size = 92
    # Build header with CRC32 field set to 0 first
    hdr = bytearray(SECTOR)

    struct.pack_into(
        "<8sIIIIQQQQ16sQIII",
        hdr,
        0,
        b"EFI PART",
        0x00010000,  # revision 1.0
        header_size,
        0,  # header CRC (filled later)
        0,  # reserved
        current_lba,
        backup_lba,
        first_usable_lba,
        last_usable_lba,
        _guid_bytes_le(disk_guid),
        part_entry_lba,
        num_entries,
        entry_size,
        part_array_crc,
    )

    crc = _crc32(bytes(hdr[:header_size]))
    struct.pack_into("<I", hdr, 16, crc)
    return bytes(hdr)


def _pack_partition_entries(
    parts: list[dict], num_entries: int, entry_size: int
) -> bytes:
    arr = bytearray(num_entries * entry_size)

    for idx, p in enumerate(parts):
        if idx >= num_entries:
            raise SystemExit(f"Too many partitions (max {num_entries})")

        type_guid = uuid.UUID(p["type_guid"])
        uniq_guid = uuid.UUID(p["uniq_guid"])
        first_lba = int(p["first_lba"])
        last_lba = int(p["last_lba"])
        attrs = int(p.get("attrs", 0))
        name = p["name"]

        name_utf16 = name.encode("utf-16le")
        if len(name_utf16) > 72:
            name_utf16 = name_utf16[:72]
        name_utf16 = name_utf16.ljust(72, b"\x00")

        off = idx * entry_size
        struct.pack_into(
            "<16s16sQQQ72s",
            arr,
            off,
            _guid_bytes_le(type_guid),
            _guid_bytes_le(uniq_guid),
            first_lba,
            last_lba,
            attrs,
            name_utf16,
        )

    return bytes(arr)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True, help="Path to raw disk image")
    ap.add_argument(
        "--size-bytes",
        required=True,
        type=int,
        help="Total disk size in bytes (will truncate/create)",
    )
    ap.add_argument(
        "--part",
        action="append",
        default=[],
        help=(
            "Partition spec: name:first_lba:last_lba (LBAs are 512-byte sectors). "
            "Type GUID defaults to Linux filesystem."
        ),
    )

    args = ap.parse_args()

    if args.size_bytes % SECTOR != 0:
        raise SystemExit("--size-bytes must be a multiple of 512")

    total_lbas = args.size_bytes // SECTOR
    if total_lbas < 4096:
        raise SystemExit("Disk image too small")

    # GPT basics
    num_entries = 128
    entry_size = 128
    primary_entries_lba = 2
    primary_entries_sectors = (num_entries * entry_size + SECTOR - 1) // SECTOR
    primary_header_lba = 1

    backup_header_lba = total_lbas - 1
    backup_entries_lba = backup_header_lba - primary_entries_sectors

    first_usable_lba = primary_entries_lba + primary_entries_sectors
    last_usable_lba = backup_entries_lba - 1

    # Parse partitions
    linux_fs_type = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
    parts: list[dict] = []
    for spec in args.part:
        try:
            name, first_s, last_s = spec.split(":", 2)
        except ValueError:
            raise SystemExit(f"Bad --part: {spec!r}")

        first_lba = int(first_s, 0)
        last_lba = int(last_s, 0)
        if first_lba < first_usable_lba or last_lba > last_usable_lba:
            raise SystemExit(
                f"Partition {name} out of usable range: {first_lba}-{last_lba} "
                f"(usable {first_usable_lba}-{last_usable_lba})"
            )
        if last_lba < first_lba:
            raise SystemExit(f"Partition {name} has last_lba < first_lba")

        parts.append(
            {
                "name": name,
                "first_lba": first_lba,
                "last_lba": last_lba,
                "type_guid": str(linux_fs_type),
                "uniq_guid": str(uuid.uuid4()),
            }
        )

    # Create/truncate image
    os.makedirs(os.path.dirname(os.path.abspath(args.image)) or ".", exist_ok=True)
    with open(args.image, "wb") as f:
        f.truncate(args.size_bytes)

    # Build partition array + headers
    part_array = _pack_partition_entries(parts, num_entries, entry_size)
    part_array_crc = _crc32(part_array)

    disk_guid = uuid.uuid4()

    primary_hdr = _pack_gpt_header(
        current_lba=primary_header_lba,
        backup_lba=backup_header_lba,
        first_usable_lba=first_usable_lba,
        last_usable_lba=last_usable_lba,
        disk_guid=disk_guid,
        part_entry_lba=primary_entries_lba,
        num_entries=num_entries,
        entry_size=entry_size,
        part_array_crc=part_array_crc,
    )

    backup_hdr = _pack_gpt_header(
        current_lba=backup_header_lba,
        backup_lba=primary_header_lba,
        first_usable_lba=first_usable_lba,
        last_usable_lba=last_usable_lba,
        disk_guid=disk_guid,
        part_entry_lba=backup_entries_lba,
        num_entries=num_entries,
        entry_size=entry_size,
        part_array_crc=part_array_crc,
    )

    # Write structures
    with open(args.image, "r+b") as f:
        f.seek(0)
        f.write(_pack_protective_mbr(total_lbas))

        # Primary
        f.seek(primary_header_lba * SECTOR)
        f.write(primary_hdr)
        f.seek(primary_entries_lba * SECTOR)
        f.write(part_array)

        # Backup
        f.seek(backup_entries_lba * SECTOR)
        f.write(part_array)
        f.seek(backup_header_lba * SECTOR)
        f.write(backup_hdr)


if __name__ == "__main__":
    main()
