#!/usr/bin/env python3
"""Verify ELF PT_LOAD alignment of the native libraries.

Google Play requires 16 KB page-size support for 64-bit native code. This checks that
every 64-bit `.so` has PT_LOAD segments aligned to >= 16384 bytes (32-bit: >= 4096).
Run: python3 tools/check_alignment.py <jniLibs-dir>
"""
import struct
import sys
from pathlib import Path


def pt_load_alignments(path: Path):
    data = path.read_bytes()
    if data[:4] != b"\x7fELF":
        raise ValueError(f"{path}: not an ELF file")
    is64 = data[4] == 2
    endian = "<" if data[5] == 1 else ">"
    if is64:
        e_phoff = struct.unpack_from(endian + "Q", data, 0x20)[0]
        e_phentsize = struct.unpack_from(endian + "H", data, 0x36)[0]
        e_phnum = struct.unpack_from(endian + "H", data, 0x38)[0]
    else:
        e_phoff = struct.unpack_from(endian + "I", data, 0x1C)[0]
        e_phentsize = struct.unpack_from(endian + "H", data, 0x2A)[0]
        e_phnum = struct.unpack_from(endian + "H", data, 0x2C)[0]

    aligns = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from(endian + "I", data, off)[0]
        if p_type == 1:  # PT_LOAD
            if is64:
                p_align = struct.unpack_from(endian + "Q", data, off + 0x30)[0]
            else:
                p_align = struct.unpack_from(endian + "I", data, off + 0x1C)[0]
            aligns.append(p_align)
    return is64, aligns


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_alignment.py <jniLibs-dir>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    libs = sorted(root.rglob("*.so"))
    if not libs:
        print(f"ERROR: no .so files under {root}", file=sys.stderr)
        return 1

    ok = True
    for lib in libs:
        is64, aligns = pt_load_alignments(lib)
        required = 16384 if is64 else 4096
        min_align = min(aligns) if aligns else 0
        status = "OK" if min_align >= required else "FAIL"
        if min_align < required:
            ok = False
        bits = "64-bit" if is64 else "32-bit"
        print(f"[{status}] {lib} ({bits}) min PT_LOAD align = {min_align} (need >= {required})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
