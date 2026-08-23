#!/usr/bin/env python3
"""Dump exported dynamic symbols from an ELF shared object.

Written to settle a concrete question: does a given liblibtorrent_flutter.so
export the bridge-ABI-2 entry points that ffi_bindings.dart looks up? `strings`
and ripgrep both give false negatives here (rg skips binaries; the symbol names
live in .dynstr, which strings does surface but not as whole lines matching -x),
so this parses the real .dynsym/.dynstr tables instead of guessing.

Usage:
  python tool/probe_elf_symbols.py <file.so> [<file.so> ...] [--prefix lt_]
"""

import struct
import sys


def parse_elf_dynsyms(path):
    """Return the set of symbol names in an ELF file's symbol tables."""
    with open(path, "rb") as fh:
        data = fh.read()

    if data[:4] != b"\x7fELF":
        raise ValueError(f"{path}: not an ELF file")

    is64 = data[4] == 2
    little = data[5] == 1
    end = "<" if little else ">"

    # Section header table location differs between ELF32 and ELF64.
    if is64:
        e_shoff = struct.unpack_from(end + "Q", data, 0x28)[0]
        e_shentsize = struct.unpack_from(end + "H", data, 0x3A)[0]
        e_shnum = struct.unpack_from(end + "H", data, 0x3C)[0]
    else:
        e_shoff = struct.unpack_from(end + "I", data, 0x20)[0]
        e_shentsize = struct.unpack_from(end + "H", data, 0x2E)[0]
        e_shnum = struct.unpack_from(end + "H", data, 0x30)[0]

    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        if is64:
            sh_type = struct.unpack_from(end + "I", data, off + 0x04)[0]
            sh_offset = struct.unpack_from(end + "Q", data, off + 0x18)[0]
            sh_size = struct.unpack_from(end + "Q", data, off + 0x20)[0]
            sh_link = struct.unpack_from(end + "I", data, off + 0x28)[0]
            sh_entsize = struct.unpack_from(end + "Q", data, off + 0x38)[0]
        else:
            sh_type = struct.unpack_from(end + "I", data, off + 0x04)[0]
            sh_offset = struct.unpack_from(end + "I", data, off + 0x10)[0]
            sh_size = struct.unpack_from(end + "I", data, off + 0x14)[0]
            sh_link = struct.unpack_from(end + "I", data, off + 0x18)[0]
            sh_entsize = struct.unpack_from(end + "I", data, off + 0x24)[0]
        sections.append((sh_type, sh_offset, sh_size, sh_link, sh_entsize))

    SHT_SYMTAB, SHT_DYNSYM = 2, 11
    names = set()
    for sh_type, sh_offset, sh_size, sh_link, sh_entsize in sections:
        if sh_type not in (SHT_SYMTAB, SHT_DYNSYM) or not sh_entsize:
            continue
        # sh_link points at the associated string table section.
        if sh_link >= len(sections):
            continue
        _, str_off, str_size, _, _ = sections[sh_link]
        strtab = data[str_off:str_off + str_size]
        for j in range(sh_size // sh_entsize):
            sym = sh_offset + j * sh_entsize
            st_name = struct.unpack_from(end + "I", data, sym)[0]
            if st_name == 0 or st_name >= len(strtab):
                continue
            nul = strtab.find(b"\x00", st_name)
            names.add(strtab[st_name:nul].decode("utf-8", "replace"))
    return names


def main():
    args = [a for a in sys.argv[1:]]
    prefix = "lt_"
    if "--prefix" in args:
        i = args.index("--prefix")
        prefix = args[i + 1]
        del args[i:i + 2]

    if not args:
        print(__doc__)
        return 1

    for path in args:
        try:
            syms = parse_elf_dynsyms(path)
        except (OSError, ValueError, struct.error) as exc:
            print(f"{path}: ERROR {exc}")
            continue
        matching = sorted(s for s in syms if s.startswith(prefix))
        print(f"\n=== {path}")
        print(f"    total symbols: {len(syms)}, matching {prefix!r}: {len(matching)}")
        for s in matching:
            print(f"    {s}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
