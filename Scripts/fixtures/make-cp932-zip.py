#!/usr/bin/env python3
"""メンバー名を CP932 byte 列とし、bit 11 を立てない deflate ZIP を作る。"""

import argparse
import os
import struct
import sys
import zipfile


UTF8_FLAG = 0x0800
LOCAL_HEADER = b"PK\x03\x04"
CENTRAL_HEADER = b"PK\x01\x02"
END_OF_CENTRAL_DIRECTORY = b"PK\x05\x06"


class CP932ZipInfo(zipfile.ZipInfo):
    """元のメンバー名を CP932 で出力する ZipInfo 派生型。"""

    # zipfile の私的フックへの依存は、生成後の全ヘッダ検証で検出する。
    def _encodeFilenameFlags(self):  # noqa: N802 - zipfile 側で定義された綴り
        return self.filename.encode("cp932"), self.flag_bits & ~UTF8_FLAG


class VerificationError(Exception):
    pass


def checked_slice(data, offset, size, label):
    end = offset + size
    if offset < 0 or size < 0 or end < offset or end > len(data):
        raise VerificationError(f"{label} lies outside the archive")
    return data[offset:end]


def input_members(source_directory):
    members = []
    for root, directories, files in os.walk(source_directory):
        directories.sort()
        files.sort()
        for filename in files:
            path = os.path.join(root, filename)
            relative = os.path.relpath(path, source_directory).replace(os.sep, "/")
            members.append((relative, path))
    if not members:
        raise VerificationError("the source directory contains no files")
    return members


def verify_archive(path, expected_names):
    with open(path, "rb") as archive:
        data = archive.read()

    search_start = max(0, len(data) - (65_535 + 22))
    eocd_offset = data.rfind(END_OF_CENTRAL_DIRECTORY, search_start)
    if eocd_offset < 0:
        raise VerificationError("end-of-central-directory record is missing")
    checked_slice(data, eocd_offset, 22, "end-of-central-directory record")
    (
        disk,
        central_disk,
        disk_entries,
        total_entries,
        central_size,
        central_offset,
        comment_length,
    ) = struct.unpack_from("<4H2IH", data, eocd_offset + 4)
    if disk != 0 or central_disk != 0 or disk_entries != total_entries:
        raise VerificationError("unexpected multi-disk metadata")
    if eocd_offset + 22 + comment_length != len(data):
        raise VerificationError("end-of-central-directory length is inconsistent")
    if total_entries != len(expected_names):
        raise VerificationError(
            f"entry count differs: {total_entries} != {len(expected_names)}"
        )
    if central_offset + central_size != eocd_offset:
        raise VerificationError("central-directory range is inconsistent")

    cursor = central_offset
    saw_non_ascii = False
    for index, expected_name in enumerate(expected_names):
        header = checked_slice(data, cursor, 46, f"central header {index}")
        if header[:4] != CENTRAL_HEADER:
            raise VerificationError(f"central header {index} has a bad signature")
        central_flags = struct.unpack_from("<H", header, 8)[0]
        name_length, extra_length, entry_comment_length = struct.unpack_from(
            "<3H", header, 28
        )
        local_offset = struct.unpack_from("<I", header, 42)[0]
        name_offset = cursor + 46
        raw_name = checked_slice(data, name_offset, name_length, f"central name {index}")

        local = checked_slice(data, local_offset, 30, f"local header {index}")
        if local[:4] != LOCAL_HEADER:
            raise VerificationError(f"local header {index} has a bad signature")
        local_flags = struct.unpack_from("<H", local, 6)[0]
        local_name_length = struct.unpack_from("<H", local, 26)[0]
        local_name = checked_slice(
            data, local_offset + 30, local_name_length, f"local name {index}"
        )

        if local_flags & UTF8_FLAG or central_flags & UTF8_FLAG:
            raise VerificationError(f"entry {index} unexpectedly sets UTF-8 bit 11")
        if local_name != raw_name:
            raise VerificationError(f"entry {index} has different local and central names")
        try:
            decoded = raw_name.decode("cp932")
        except UnicodeDecodeError as error:
            raise VerificationError(f"entry {index} is not valid CP932: {error}") from error
        if decoded != expected_name or raw_name != expected_name.encode("cp932"):
            raise VerificationError(f"entry {index} does not round-trip through CP932")
        saw_non_ascii = saw_non_ascii or any(byte >= 0x80 for byte in raw_name)

        cursor = name_offset + name_length + extra_length + entry_comment_length

    if cursor != central_offset + central_size:
        raise VerificationError("central-directory parser did not consume its full range")
    if not saw_non_ascii:
        raise VerificationError("at least one member name must contain non-ASCII CP932 bytes")


def create_archive(source_directory, destination):
    members = input_members(source_directory)
    expected_names = [name for name, _ in members]
    with zipfile.ZipFile(
        destination,
        mode="w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=6,
    ) as archive:
        for member_name, source_path in members:
            info = CP932ZipInfo(member_name, date_time=(2020, 1, 2, 3, 4, 6))
            info.compress_type = zipfile.ZIP_DEFLATED
            # host OS 0 は DOS/Windows の OEM 名として検出器へ伝わる。
            info.create_system = 0
            info.external_attr = 0
            with open(source_path, "rb") as source:
                archive.writestr(info, source.read())
    verify_archive(destination, expected_names)
    return len(members)


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_directory")
    parser.add_argument("destination")
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    try:
        count = create_archive(arguments.source_directory, arguments.destination)
    except (OSError, UnicodeError, VerificationError, zipfile.BadZipFile) as error:
        print(f"CP932 ZIP fixture generation failed: {error}", file=sys.stderr)
        return 1
    print(f"verified CP932 ZIP fixture: {count} entries, bit 11 clear")
    return 0


if __name__ == "__main__":
    sys.exit(main())
