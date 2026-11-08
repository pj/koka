#!/usr/bin/env python3
"""Generate lib/std/text/unicode-tables.kk from the Unicode Character Database.

  python3 util/gen-unicode-tables.py <ucd-dir> > lib/std/text/unicode-tables.kk

<ucd-dir> holds UnicodeData.txt, auxiliary/GraphemeBreakProperty.txt, ... (for
example `nix build nixpkgs#unicode-character-database`, then
`<out>/share/unicode`). The tables are written as compact strings that
std/text/unicode decodes on first use.
"""
import sys, os, re

ucd = sys.argv[1]

def path(*p): return os.path.join(ucd, *p)

def parse_ranges(fname, want=None):
    """Yield (lo, hi, value) from a `cp..cp ; value # comment` property file."""
    for line in open(fname, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if not line: continue
        fields = [f.strip() for f in line.split(";")]
        cps = fields[0]
        lo, hi = (cps.split("..") + [None])[:2]
        lo = int(lo, 16); hi = int(hi, 16) if hi else lo
        if want is None or fields[1] in want:
            yield lo, hi, fields[1:] if len(fields) > 2 else fields[1]

def version():
    for line in open(path("DerivedAge.txt"), encoding="utf-8"):
        m = re.match(r"# DerivedAge-(\d+\.\d+\.\d+)\.txt", line)
        if m: return m.group(1)
    return "?"

MAX = 0x110000

def table_from(assign):
    """`assign` is a dict cp -> value (nonzero); merge into ranges."""
    out = []
    for cp in sorted(assign):
        v = assign[cp]
        if out and out[-1][1] == cp - 1 and out[-1][2] == v:
            out[-1][1] = cp
        else:
            out.append([cp, cp, v])
    return out

def encode_ranges(rs):
    # `lo.hi.v` in hex (hi as a length when shorter), separated by commas
    parts = []
    for lo, hi, v in rs:
        parts.append("%x.%x.%x" % (lo, hi - lo, v))
    return wrap(",".join(parts))

def wrap(s, width=100):
    lines = [s[i:i+width] for i in range(0, len(s), width)]
    return "\n".join(lines)

def emit(name, comment, s):
    print("// " + comment)
    print("pub val %s : string = r#\"%s\"#" % (name, s))
    print()

# --- general categories and decompositions from UnicodeData.txt
gc = {}
ccc = {}
decomp = {}
ranges_open = None
for line in open(path("UnicodeData.txt"), encoding="utf-8"):
    f = line.rstrip("\n").split(";")
    cp = int(f[0], 16)
    name = f[1]
    if name.endswith(", First>"):
        ranges_open = cp
        continue
    if name.endswith(", Last>"):
        for c in range(ranges_open, cp + 1): gc[c] = f[2]
        ranges_open = None
        continue
    gc[cp] = f[2]
    if int(f[3]) != 0: ccc[cp] = int(f[3])
    if f[5]:
        d = f[5].split()
        compat = d[0].startswith("<")
        if compat: d = d[1:]
        decomp[cp] = (compat, [int(x, 16) for x in d])

# --- grapheme cluster break, with Extended_Pictographic and InCB folded in
GCB = ["Other", "CR", "LF", "Control", "Extend", "ZWJ", "Regional_Indicator", "Prepend", "SpacingMark", "L", "V", "T", "LV", "LVT"]
gcb = {}
for lo, hi, v in parse_ranges(path("auxiliary", "GraphemeBreakProperty.txt")):
    for c in range(lo, hi + 1): gcb[c] = GCB.index(v)
extpict = set()
for lo, hi, v in parse_ranges(path("emoji", "emoji-data.txt")):
    if v == "Extended_Pictographic":
        for c in range(lo, hi + 1): extpict.add(c)
INCB = {"Linker": 1, "Consonant": 2, "Extend": 3}
incb = {}
for line in open(path("DerivedCoreProperties.txt"), encoding="utf-8"):
    line = line.split("#", 1)[0].strip()
    if not line: continue
    fields = [x.strip() for x in line.split(";")]
    if fields[1] != "InCB": continue
    lo, hi = (fields[0].split("..") + [None])[:2]
    lo = int(lo, 16); hi = int(hi, 16) if hi else lo
    for c in range(lo, hi + 1): incb[c] = INCB[fields[2]]
g = {}
for c in set(gcb) | extpict | set(incb):
    v = gcb.get(c, 0) | (16 if c in extpict else 0) | (incb.get(c, 0) << 5)
    if v: g[c] = v

# --- word break
WB = ["Other", "CR", "LF", "Newline", "Extend", "ZWJ", "Regional_Indicator", "Format", "Katakana", "Hebrew_Letter",
      "ALetter", "Single_Quote", "Double_Quote", "MidNumLet", "MidLetter", "MidNum", "Numeric", "ExtendNumLet", "WSegSpace"]
wb = {}
for lo, hi, v in parse_ranges(path("auxiliary", "WordBreakProperty.txt")):
    for c in range(lo, hi + 1): wb[c] = WB.index(v)
letnum = set(c for c, cat in gc.items() if cat[0] in "LN")
w = {}
for c in set(wb) | extpict | letnum:
    v = wb.get(c, 0) | (32 if c in extpict else 0) | (64 if c in letnum else 0)
    if v: w[c] = v

# --- display widths: 2 for East Asian Wide/Fullwidth, 0 for marks and format characters
width = {}
for lo, hi, v in parse_ranges(path("EastAsianWidth.txt")):
    if v in ("W", "F"):
        for c in range(lo, hi + 1): width[c] = 2
for c, cat in gc.items():
    if cat in ("Mn", "Me", "Cf") and c != 0x00AD: width[c] = 1   # 1 encodes zero width here
for c in list(range(0x1160, 0x1200)) + list(range(0xD7B0, 0xD800)) + [0x200B]:
    width[c] = 1
for c in range(0, 0x20): width[c] = 1
for c in range(0x7F, 0xA0): width[c] = 1

# --- case folding (full: C and F)
fold = []
for line in open(path("CaseFolding.txt"), encoding="utf-8"):
    line = line.split("#", 1)[0].strip()
    if not line: continue
    f = [x.strip() for x in line.split(";")]
    if f[1] in ("C", "F"):
        fold.append((int(f[0], 16), [int(x, 16) for x in f[2].split()]))
fold.sort()

# --- normalization: combining classes, decompositions, composition exclusions
excl = set()
for lo, hi, v in parse_ranges(path("DerivedNormalizationProps.txt")):
    if v == "Full_Composition_Exclusion":
        for c in range(lo, hi + 1): excl.add(c)

print("""/*---------------------------------------------------------------------------
  Copyright 2026, Koka contributors.

  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the LICENSE file at the root of this distribution.

  Generated by util/gen-unicode-tables.py from the Unicode Character
  Database %s (Copyright Unicode, Inc., under the Unicode License v3).
  Do not edit.
---------------------------------------------------------------------------*/

// Internal: Unicode property tables for `std/text/unicode`.
module std/text/unicode-tables

pub val unicode-version : string = "%s"
""" % (version(), version()))

emit("grapheme-props", "Ranges `lo.len.value` (hex): bits 0-3 Grapheme_Cluster_Break, 4 Extended_Pictographic, 5-6 InCB", encode_ranges(table_from(g)))
emit("word-props", "Ranges `lo.len.value` (hex): bits 0-4 Word_Break, 5 Extended_Pictographic, 6 a letter or number (L*, N*)", encode_ranges(table_from(w)))
emit("width-props", "Ranges `lo.len.value` (hex): 1 is zero width, 2 is double width", encode_ranges(table_from(width)))
emit("ccc-props", "Ranges `lo.len.value` (hex): canonical combining classes", encode_ranges(table_from(ccc)))
emit("case-folds", "`cp=cp cp` (hex): full case folding",
     wrap(",".join("%x=%s" % (c, " ".join("%x" % t for t in ts)) for c, ts in fold)))
emit("decompositions", "`cp=cp cp` (hex), `cp~cp cp` for compatibility decompositions, `!` after `=` if excluded from composition",
     wrap(",".join("%x%s%s%s" % (c, "~" if compat else "=", "!" if (not compat and c in excl) else "", " ".join("%x" % t for t in ds))
                   for c, (compat, ds) in sorted(decomp.items()))))
