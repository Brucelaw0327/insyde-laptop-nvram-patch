"""mkrec.py -- build H2OUVE variable-record files that differ from the original
by exactly the bytes you ask for, at chosen offsets inside chosen records.

Input : h2ouve/vars_orig.txt    (produced by  `H2OUVE -gv vars_orig.txt`)
Output: h2ouve/setup_new.txt    (minimal: H2OUVE comment header + the chosen
                                 records, with the bytes patched)
        h2ouve/vars_new_full.txt (full copy -- byte-for-byte identical to the
                                  source dump except the patched tokens)
        h2ouve/setup_undo.txt    (the same records, ORIGINAL bytes, verbatim)
        h2ouve/undo_<slug>.txt   (the same undo content, named after the patch)

Usage:
    python mkrec.py                                       # legacy single change
    python mkrec.py --offset 0x100 --old 0x02 --new 0x00
    python mkrec.py --change 0x100:0x02:0x00 --change 0x2A0:0x01:0x00
    python mkrec.py --change 0x100:0x02:0x00 --records Setup --name mypatch

--change may be repeated to patch several bytes in one run; each one is
OFFSET:FROM:TO, all hex.  --offset/--old/--new is the single-change spelling,
and mixing the two forms is an error rather than a guess.

Defaults target the fTPM selector on this firmware family:
    Setup data offset 0x100  0x02 -> 0x00      (firmware TPM -> Disable)
Locate YOUR own offset before changing anything -- see docs/how-it-works.md,
or let tools/ifr_locate.py derive it from your own firmware.

The undo file is the safety net: it is a byte-for-byte copy of the FIRST dump,
so restoring it puts the firmware back exactly as it was.

Output is produced by editing the source bytes in place, never by re-serialising
the parsed text, so line endings and file tails are preserved exactly.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN_RE = re.compile(rb'[0-9A-Fa-f]{2}')
HDR_RE = re.compile(r'^\s*\[([0-9A-Fa-f]{3,})\]\s+"(.*)"\s*$')


def build_parser():
    p = argparse.ArgumentParser(description='Build patched H2OUVE variable-record files.')
    p.add_argument('--src', default=os.path.join(HERE, 'h2ouve', 'vars_orig.txt'),
                   help='source dump (default: h2ouve/vars_orig.txt)')
    p.add_argument('--outdir', default=os.path.join(HERE, 'h2ouve'),
                   help='output directory (default: h2ouve/)')
    p.add_argument('--offset', default=None, help='byte offset to patch (single-change form)')
    p.add_argument('--old', default=None, help='expected current value (single-change form)')
    p.add_argument('--new', default=None, help='value to write (single-change form)')
    p.add_argument('--change', action='append', default=[], metavar='OFF:FROM:TO',
                   help='one byte change, hex; repeat for several.  '
                        'Alternative to --offset/--old/--new.')
    p.add_argument('--records', default='Setup,Custom',
                   help='comma-separated record names (default Setup,Custom)')
    p.add_argument('--name', default=None,
                   help='patch slug; also writes h2ouve/undo_<slug>.txt')
    return p


def parse_changes(args):
    """Resolve --change / --offset,old,new into [(off, old, new), ...]."""
    if args.change:
        if args.offset or args.old or args.new:
            raise SystemExit('use --change OR --offset/--old/--new, not both')
        out = []
        for spec in args.change:
            parts = spec.replace(':', ' ').replace(',', ' ').split()
            if len(parts) != 3:
                raise SystemExit('--change needs OFFSET:FROM:TO, got %r' % spec)
            try:
                out.append(tuple(int(x, 16) for x in parts))
            except ValueError:
                raise SystemExit('--change values must be hex, got %r' % spec)
    else:
        # The pre-patch-file defaults are kept: `python mkrec.py` alone still
        # means "fTPM selector 0x100 0x02 -> 0x00" for this firmware family.
        out = [(int(args.offset or '0x100', 16),
                int(args.old or '0x02', 16),
                int(args.new or '0x00', 16))]
    seen = set()
    for (off, old, new) in out:
        if off in seen:
            raise SystemExit('offset 0x%X appears in more than one change' % off)
        seen.add(off)
        if old == new:
            raise SystemExit('offset 0x%X: FROM and TO are both 0x%02X' % (off, old))
    return out


def load(path):
    raw = open(path, 'rb').read()
    crlf = b'\r\n' in raw
    raw_lines = raw.split(b'\n')
    lines = [l.decode('utf-8', 'replace').rstrip('\r') for l in raw_lines]
    return raw, raw_lines, lines, crlf


def heading(ln):
    s = ln.lstrip()
    return s.startswith('[') and '] "' in s


def locate(lines, name):
    """return (start, end) line indices of the record for `name`"""
    starts = [i for i, l in enumerate(lines) if heading(l)]
    for n, i in enumerate(starts):
        if '"%s"' % name in lines[i]:
            end = starts[n + 1] if n + 1 < len(starts) else len(lines)
            return i, end
    raise SystemExit('record %r not found' % name)


def hexline_idx(lines, a, b, off):
    # hexdump rows hold 16 bytes each, so the row label is the offset rounded
    # DOWN to a multiple of 0x10 -- searching for '%08X' % off only works when
    # off happens to be 16-aligned (which 0x100 is, and most offsets are not).
    base = off - (off % 16)
    tag = '%08X:' % base
    for i in range(a, b):
        if lines[i].strip().startswith(tag):
            return i
    raise SystemExit('hex row 0x%X (for offset 0x%X) not found in record' % (base, off))


def get_bytes(lines, a, b):
    out = bytearray()
    for i in range(a, b):
        t = lines[i].strip()
        if len(t) > 9 and t[8] == ':' and all(c in '0123456789ABCDEF ' for c in t[:8] + t[9:]):
            try:
                out += bytes.fromhex(t[9:].replace(' ', ''))
            except ValueError:
                pass
    return out


def patch_raw_line(rl, col, new):
    """Return `rl` (a raw, \r-included hexdump line) with hex token `col` replaced.
    Only that token's bytes change -- every space and the line ending are kept."""
    ci = rl.index(b':')
    prefix, tail = rl[:ci + 1], rl[ci + 1:]
    spans = [m.span() for m in TOKEN_RE.finditer(tail)]
    if col >= len(spans):
        raise SystemExit('offset column %d is past the data on this hex row' % col)
    a, b = spans[col]
    return prefix + tail[:a] + (b'%02X' % new) + tail[b:]


def trim_blank_tail(lines):
    out = list(lines)
    while out and out[-1].strip() == b'':
        out.pop()
    return out


def record_bytes(txt, nm):
    """Return the data bytes of record `nm` in an H2OUVE dump text, or None."""
    m = re.search(r'\[[0-9A-Fa-f]+\] "%s"\s*\n\s*GUID: ([0-9A-Fa-f\-]+)\s*\n\s*'
                  r'Attributes: (0x[0-9A-Fa-f]+)\s*\n\s*DataSize: (0x[0-9A-Fa-f]+)' % nm, txt)
    if not m:
        return None, None
    blk = txt[txt.index('"%s"' % nm):]
    nxt = re.search(r'\n\s*\[[0-9A-Fa-f]+\] "', blk)
    blk = blk[:nxt.start()] if nxt else blk
    data = bytearray()
    for ln in blk.split('\n'):
        t = ln.strip()
        if len(t) > 9 and t[8] == ':' and all(c in '0123456789ABCDEF ' for c in t[:8] + t[9:]):
            try:
                data += bytes.fromhex(t[9:].replace(' ', ''))
            except ValueError:
                pass
    return data, m


def verify(path, names, changes, was, expect):
    """Assert every requested change landed (expect='new') or is untouched
    (expect='was').  Returns the number of mismatches."""
    txt = open(path, encoding='utf-8', errors='replace').read()
    bad = 0
    for nm in names:
        data, m = record_bytes(txt, nm)
        if data is None:
            print('  VERIFY FAIL: %s not parseable in %s' % (nm, os.path.basename(path)))
            bad += 1
            continue
        cells = []
        for (off, old, new) in changes:
            got = data[off] if off < len(data) else None
            want = new if expect == 'new' else was.get((nm, off))
            ok = (got is not None and want is not None and got == want)
            if not ok:
                bad += 1
            cells.append('[0x%X]=%s %s' % (off, '0x%02X' % got if got is not None else 'n/a',
                                           'OK' if ok else 'MISMATCH(want %s)'
                                           % ('0x%02X' % want if want is not None else '?')))
        print('  %-8s %-18s guid=%s size=%s len=%d  %s'
              % (nm, os.path.basename(path), m.group(1), m.group(3), len(data),
                 '  '.join(cells)))
    return bad


def main():
    args = build_parser().parse_args()
    changes = parse_changes(args)
    recs = [r.strip() for r in args.records.split(',') if r.strip()]
    if not recs:
        raise SystemExit('--records is empty')

    if not os.path.exists(args.src):
        raise SystemExit('source dump not found: %s\n'
                         'Dump it first:\n'
                         '  h2ouve\\H2OUVE-W-CONSOLEx64.exe -gv vars_orig.txt' % args.src)
    os.makedirs(args.outdir, exist_ok=True)

    raw, raw_lines, lines, crlf = load(args.src)
    full = list(raw_lines)

    print('source  : %s' % args.src)
    print('records : %s' % ', '.join(recs))
    for (off, old, new) in changes:
        print('change  : 0x%X   %02X -> %02X' % (off, old, new))
    print()

    # `was` records what each byte held in the SOURCE, so the undo file can be
    # verified against it exactly (rather than against an assumed value).
    was = {}
    applied = 0
    for name in recs:
        a, b = locate(lines, name)
        data = get_bytes(lines, a, b)
        for (off, old, new) in changes:
            if len(data) <= off:
                raise SystemExit('%s too short (%d) for offset 0x%X' % (name, len(data), off))
            cur = data[off]
            was[(name, off)] = cur
            print('%-8s len=%d  [0x%X] = 0x%02X  ->  0x%02X' % (name, len(data), off, cur, new))
            if cur == new:
                print('        already 0x%02X, nothing to patch' % new)
                continue
            if cur != old:
                print('        WARNING: value is 0x%02X, not the expected 0x%02X' % (cur, old))
            i = hexline_idx(lines, a, b, off)
            # patch the WORKING line, not the original: two offsets can share a
            # hexdump row, and re-reading raw_lines would drop the earlier edit.
            full[i] = patch_raw_line(full[i], off % 16, new)
            applied += 1
            print('        patched line %d: %s' % (i, full[i].decode('utf-8', 'replace').strip()))

    head_end = min(i for i, l in enumerate(lines) if heading(l))
    hdr = list(raw_lines[:head_end])

    mini = list(hdr)
    for name in recs:
        a, b = locate(lines, name)
        mini += trim_blank_tail(full[a:b]) + [b'']

    undo = list(hdr)
    for name in recs:
        a, b = locate(lines, name)
        undo += trim_blank_tail(raw_lines[a:b]) + [b'']

    out_mini = os.path.join(args.outdir, 'setup_new.txt')
    out_full = os.path.join(args.outdir, 'vars_new_full.txt')
    out_undo = os.path.join(args.outdir, 'setup_undo.txt')

    with open(out_mini, 'wb') as f:
        f.write(b'\n'.join(mini) + b'\n')
    with open(out_full, 'wb') as f:
        f.write(b'\n'.join(full))
    undo_blob = b'\n'.join(undo) + b'\n'
    with open(out_undo, 'wb') as f:
        f.write(undo_blob)

    out_undo_named = None
    if args.name:
        slug = re.sub(r'[^A-Za-z0-9_.-]+', '_', args.name).strip('_').lower() or 'default'
        out_undo_named = os.path.join(args.outdir, 'undo_%s.txt' % slug)
        with open(out_undo_named, 'wb') as f:
            f.write(undo_blob)

    delta = os.path.getsize(out_full) - len(raw)
    print()
    print('eol =', 'CRLF' if crlf else 'LF')
    print('patched tokens = %d of %d requested' % (applied, len(changes) * len(recs)))
    print('wrote %s  (%d bytes)' % (out_mini, os.path.getsize(out_mini)))
    print('wrote %s  (%d bytes; source %d, delta %+d)'
          % (out_full, os.path.getsize(out_full), len(raw), delta))
    print('wrote %s  (%d bytes)' % (out_undo, os.path.getsize(out_undo)))
    if out_undo_named:
        print('wrote %s  (%d bytes)' % (out_undo_named, os.path.getsize(out_undo_named)))

    print()
    print('=== verify ===')
    bad = 0
    bad += verify(out_mini, recs, changes, was, 'new')
    bad += verify(out_full, recs, changes, was, 'new')
    bad += verify(out_undo, recs, changes, was, 'was')
    print()
    if bad:
        print('VERIFY: %d MISMATCH -- do not write these files' % bad)
        return 1
    print('VERIFY: OK -- every requested byte is in place, undo holds the originals')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
