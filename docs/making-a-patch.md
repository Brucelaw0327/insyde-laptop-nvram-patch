# Making a patch

> 中文版：[making-a-patch.zh-CN.md](making-a-patch.zh-CN.md)

A **patch** is a small text file that says: *in this variable store, in these
records, change this byte from A to B*. It is the only thing that differs between
one use of this tool and another — the gate logic, the snapshot, the write, the
read-back and the undo are all the same.

That is the whole point: the offset and the values live in a file you can read,
edit and review, instead of being buried in a script.

---

## 1. The format

```
NAME     = fTPM -> Disable
VARSTORE = SystemConfig
GUID     = A04A27F4-DF00-4D42-B552-39511302113D
RECORDS  = Setup,Custom

OFFSET   = 0x100          # one change, written as three keys
FROM     = 0x02
TO       = 0x00
```

Or, for several bytes in one patch:

```
CHANGE   = 0x100 0x02 0x00     # OFFSET FROM TO
CHANGE   = 0x2A0 0x01 0x00
```

Rules:

- `#` starts a comment — whole-line, or after whitespace on a line.
- Keys are case-insensitive; values are hex, with or without the `0x`.
- `GUID` may be written with or without braces.
- `VARSTORE` is free text used in log lines; `GUID` is what actually identifies
  the store, because a name alone is not unique across vendors.
- `RECORDS` is required: it names the records **inside** that store. The H2OUVE
  dumps in this project use `Setup,Custom` for the SystemConfig store; other
  stores use other names.
- `OFFSET/FROM/TO` and `CHANGE` are **mutually exclusive**. Mixing them is an
  error, not a guess.

The parser refuses, loudly, on: a missing GUID; a malformed GUID; a missing
RECORDS; a non-hex value; a `CHANGE` line that is not three tokens; the same
offset twice; and `FROM == TO` (a patch that changes nothing).

## 2. Where the numbers come from

`tools/ifr_locate.py` derives them from your own firmware and prints a
ready-to-save patch stub:

```
> python tools\ifr_locate.py find Setup.bin "Trust Platform Module"
  ...
# --- candidate patch file (verify by eye before use) ---
# Advanced / Trust Platform Module
NAME     = Trust Platform Module -> Disable
VARSTORE = SystemConfig
GUID     = A04A27F4-DF00-4D42-B552-39511302113D
RECORDS  = Setup,Custom
OFFSET   = 0x100
FROM     = 0x2
TO       = 0x0
```

The stub is a **suggestion**. Read it before you save it — in particular check
that the option it labelled `TO` is the one you actually want. Then prove it
against a real dump before writing anything:

```
> python tools\ifr_locate.py verify Setup.bin h2ouve\vars_orig.txt "Trust Platform Module"
RESULT: consistent -- the IFR layout explains this dump
```

A `verify` that fails means the offset is not the one you think it is. Do not
write.

## 3. Running a patch

```
powershell -ExecutionPolicy Bypass -File apply_patch.ps1 -Patch patches\<name>.patch
```

`run.cmd` option 4 is the menu way to run exactly that command, with a patch
picker, a typed confirmation and self-elevation.

Before writing, `apply_patch.ps1` runs the same gates whatever the patch says:

| Gate | Checks | Exit |
|---|---|---|
| identity | BIOS / board / model match `machine.txt` | 7 (6 if `machine.txt` is absent) |
| BitLocker | no volume is TPM-protected | 11, or 12 if it cannot tell |
| layout | the live records' `Attributes`/`DataSize` match the patched record file | 8 |
| sanity | the record file really holds this patch's target values | 5 |
| blind-write | the current value is readable before writing | 4 |

`-Force` skips **all** of them at once. It exists for an operator who is already
locked out of a volume; it is not a convenience flag.

Check what a patch will do before applying it:

```
powershell -ExecutionPolicy Bypass -File check_status.ps1 -Patch patches\<name>.patch
```

`run.cmd` option 3 does the same through the menu, so the read-only report
explains the same byte the writer will touch.

## 4. Undo

```
run.cmd option 5                             # or:
powershell -ExecutionPolicy Bypass -File restore_original.ps1 -Patch patches\<name>.patch
```

`restore_original.ps1` writes back `h2ouve\undo_<slug>.txt` — the pristine bytes
of the records this patch touched, taken from the very first dump. If that file
is missing it falls back to `h2ouve\setup_undo.txt`, the generic rollback copy.

Rollback **reports** BitLocker but does not gate on it: if a volume is already
sitting in recovery mode, putting the TPM back is the fix.

## 5. One patch at a time — and why

`setup_new.txt` is rebuilt from `h2ouve\vars_orig.txt`, the **pristine** first
dump. If a record file is present but does not hold the current patch's target
values, `apply_patch.ps1` rebuilds it automatically rather than writing stale
bytes.

The consequence is worth stating plainly: a write carries only *this* patch's
changes, so applying patch B after patch A **reverts A** if both touch the same
records. That is deliberate — the record file always means "the pristine state,
with exactly these bytes changed", which is the only thing that can be verified
and rolled back safely.

To change several bytes together, put them in **one** patch:

```
CHANGE   = 0x100 0x02 0x00
CHANGE   = 0x2A0 0x01 0x00
```

`mkrec.py` (called by the script) applies all of them in one pass and verifies
each one afterwards.

## 6. The removed legacy path

Older releases read the offset from `machine.txt` (`TARGET_OFFSET/FROM/TO`, or
`FTPM_OFFSET/ON/OFF`), with a built-in last-resort hint. That path is **gone**:
a byte change is described by a patch file, full stop. `machine.txt` is now the
identity gate only. The reasons: an offset visible only inside a git-ignored
local file cannot be diffed or reviewed, and a built-in hint was one firmware
family's layout wearing a generic costume.

## 7. Earlier versions of this repository

Before patch files, the offset lived in `machine.txt` as `FTPM_OFFSET/ON/OFF` and
the two engines were `disable_ftpm.ps1` / `restore_ftpm.ps1`. Both of those are
gone in this version; the scripts grew generic names (`apply_patch.ps1` /
`restore_original.ps1`) and take `-Patch`, and prebuilt `patches\ftpm-*.patch`
files shipped by intermediate releases have been removed too -- derive the
offset from your own firmware instead.
