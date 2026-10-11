# insyde-laptop-nvram-patch

English | [简体中文](README.zh-CN.md)

Change firmware settings that the BIOS Setup UI hides, on **Insyde H2O**
machines — from Windows, by editing the UEFI variable that backs the setting,
through the vendor's own SMI service channel (H2OUVE). No BIOS flash, no CMOS
clear, no BIOS-menu archaeology. Built for **laptops**: OEM notebook Setup UIs
hide most of these toggles, while desktop boards usually expose them and rarely
need any of this.

The unit of work is a small text file — a **patch** — naming the variable
store, the records inside it, and the byte(s) to move. `apply_patch.ps1`
applies one patch behind identity / layout / BitLocker gates, verifies the
write, and drops an undo file; `restore_original.ps1` rolls it back.

The **worked example used throughout the docs turns off an AMD firmware TPM
(fTPM)**. On many consumer laptops that item is absent from the BIOS Setup UI
and the usual escapes are dead ends: the `Setup` variable is write-protected
for the OS, `dmpstore` fails, and tools that only enumerate standard AMD
CBS/PBS pages do not surface the TPM page at all. Any other setting is the
same three steps with a patch of your own — see
[`docs/making-a-patch.md`](docs/making-a-patch.md). No patches ship with the
repository: a patch describes one firmware build's layout, so a prebuilt one
is a confidently-labelled wrong answer on anyone else's machine.

> **This edits firmware NVRAM. It can brick a machine.**
> Read [`DISCLAIMER.md`](DISCLAIMER.md) and [`docs/how-it-works.md`](docs/how-it-works.md)
> before running anything.
>
> **Turn BitLocker and other TPM-dependent features off first** — see
> [Before you start](#before-you-start). Without a TPM the OS volume goes into
> recovery mode at the next boot.

---

## Before you start

The fTPM is the only TPM on this platform. **When it is off, the OS sees no TPM
at all**, so anything that seals keys to the TPM stops working. Do this part
first, or apply_patch.ps1 will refuse to run.

**1. Get BitLocker / device encryption out of the way (mandatory).**

```powershell
manage-bde -status                    # is anything protected?
manage-bde -off C:                    # decrypt (slow, but safest)
# or, to keep the volume encrypted and only lift the TPM lock for one boot:
manage-bde -protectors -disable C:    # then re-enable after you boot
```

A TPM-protected volume that loses its TPM comes up in **recovery mode**. If you
already hold the recovery key and are willing to type it, you may skip this and
run apply_patch.ps1 with `-Force` — but the script will not decide that for
you.

**2. Know what else depends on the TPM.** These do not lock you out, so the
scripts only report them, but you should expect to lose their state:

| Feature | What happens | Where |
|---|---|---|
| Windows Hello (PIN / fingerprint / face) | Sign-in key is TPM-sealed — you re-enrol it | Sign-in options |
| Credential Guard / VBS secrets | Sealed to the TPM — they are gone | `Win32_DeviceGuard` |
| HVCI (memory integrity) | Reported; attestation has no TPM | `Win32_DeviceGuard` |
| Any app storing a key in the TPM | That key is unrecoverable | app-specific |

Run `run.cmd` option 1 to see all of the
above before deciding.

**3. Have a rollback path.** `run.cmd` option 5 puts the original bytes back;
keep the `h2ouve/undo_<slug>.txt` file(s) the first apply wrote (see
[Rollback](#rollback)).

**A note on `-Force`.** `apply_patch.ps1 -Force` overrides **all** the gates at
once — identity, layout, and BitLocker. It exists because an operator who is
already locked out of a volume still needs a way to act on a machine whose
fingerprint no longer matches; it is not a convenience flag. If a gate fires and
your instinct is to add `-Force`, that is the moment to stop and read the gate's
message instead.

---

## One menu, three engines

Double-click **`run.cmd`**; everything funnels through its menu:

| Menu option | What it really runs | Effect |
|---|---|---|
| 1 — status probe | `check_status.ps1` | read-only: identity, BitLocker, TPM dependents. Seeds `machine.txt` on first run. **Safe any time.** |
| 2 — locate a setting | `tools\ifr_locate.py extract` + `find --out` | read-only: unwraps your BIOS update package to the Setup module, decodes the IFR, writes a candidate patch. Blank keyword = list EVERY setting (with live/default values), pick by number |
| 3 — status probe for a patch | `check_status.ps1 -Patch <file>` | adds the live byte(s) a chosen patch would change. **Safe any time.** |
| 4 — apply a patch | `apply_patch.ps1 -Patch <file>` | **MODIFIES NVRAM** — asks which `patches\*.patch`, demands a typed `YES`, relaunches elevated |
| 5 — restore (undo) | `restore_original.ps1 -Patch <file>` | **MODIFIES NVRAM** — writes the original records back |

Or run the engines directly:

```powershell
powershell -ExecutionPolicy Bypass -File apply_patch.ps1 -Patch patches\my-setting.patch
```

## What a run does

`apply_patch.ps1` applies **one patch** and refuses to guess. In order:

1. **G — identity gate**: this machine's BIOS / board / model must match
   `machine.txt` (exit 7; exit 6 when the file is missing — the read-only probe
   seeds it, the writer never does).
2. **P — the patch**: parsed by `lib/patchfile.ps1`, the one parser everything
   shares (exit 2 on a malformed file).
3. **G2 — BitLocker gate**: no volume may be TPM-protected (exit 11), and the
   state must be knowable at all (exit 12).
4. **B — bootstrap**: if the record files are missing or were built for a
   different patch, dump NVRAM and rebuild them from the pristine first dump.
5. **0 / 0b — snapshot + layout gate**: pre-write snapshot, then the live
   records must match the layout the patch was built for.
6. **1–4 — write and prove**: read test, write, re-dump, verify every byte; if
   the minimal record does not take, the full dump is retried automatically.

Then it tells you to **fully power off** — the setting is consumed at power-on,
so a warm reboot is not enough.

## What it is **not**

- Not a BIOS flash. The firmware image is untouched; only the NVRAM variable
  store changes, so the BIOS version string stays the same.
- Not vendor-specific magic. It is a documented method plus scripts; the
  interesting part is *how the offset is found* — `tools/ifr_locate.py` derives
  it from your own firmware rather than trusting a constant.
- Not a TPM "clear". Nothing is wiped; the TPM simply stops being published to
  the OS.
- Not a general-purpose UEFI variable editor. It moves the specific bytes you
  name, and refuses to run when it cannot confirm it is on the machine and the
  record layout the patch was built for.

## Requirements

- Windows, booted in **UEFI** mode (not legacy).
- An **Insyde H2O** firmware that exposes the variable store over the same SMI
  channel. The fTPM example additionally needs an **AMD** platform with an
  fTPM; its offset (`0x100`) is the layout of one particular firmware family —
  **derive yours** from your own firmware (see *Locating your own offset*).
- **Administrator** rights (the launchers self-elevate).
- **No active TPM protection** — BitLocker / device encryption is off (or
  suspended). The script refuses to write otherwise; see
  [Before you start](#before-you-start).
- Python 3 -- **bundled** at `tools\runtime\python` (embeddable 3.13.16,
  PSF license, see `tools\runtime\python\LICENSE.txt`); nothing to install.
  A working `python`/`py -3` on `PATH` is used as fallback if you delete it.
- The **H2OUVE** tool — **not included**; where to get it and how to verify
  it: [`h2ouve/README.md`](h2ouve/README.md).

---

## Quick start

The fTPM flip, start to finish (any other setting is identical once its patch
exists):

1. **Check status first — read-only, writes nothing.**

   Run `run.cmd` → option 1.
   It writes `stat_<timestamp>.txt` next to the script and prints, among other
   things:

   ```
   --- machine identity (machine.txt seeded automatically from this machine) ---
     BIOS  = '<yours>'  expected '<yours>'  OK
     board = '<yours>'  expected '<yours>'  OK
     model = '<yours>'  expected '<yours>'  OK
   --- TPM-dependent features ---
     BitLocker / device encryption : none protected
   ```

   Without a patch there is no "records a patch would touch" section — there
   are no built-in offsets to explain.

2. **`machine.txt` — created for you.** If it does not exist, step 1 seeds it
   with this machine's identity (`BIOS` / `BOARD` / `MODEL`, read from the
   registry). Open it once and check the three values. This is the identity
   gate: it stops a record file built for one BIOS from ever being written to
   another. (Preparing the folder on a different PC? Copy `machine.sample.txt`
   instead — the writers never invent this file themselves.)

3. **Put H2OUVE in `h2ouve/`** — see [`h2ouve/README.md`](h2ouve/README.md).

4. **Make the patch.** Run `run.cmd` → option 2, point it at your firmware's
   Setup module (`Setup_FE3542FE-….ffs`, extracted with UEFITool — see
   [`tools/README.md`](tools/README.md)), and search for `Trust Platform
   Module`. It writes `patches\trust-platform-module.patch`. Open it and check
   `FROM`/`TO` by eye (`0x02` = firmware TPM on → `0x00` = disable).

5. **Apply it.** Run `run.cmd` → option 4, pick the patch, type `YES`. It will:
   - refuse to run if BitLocker is still protecting a volume (exit code 11), or
     if it cannot read the BitLocker state at all (exit code 12);
   - refuse to run if the identity or layout does not match;
   - dump NVRAM and build the record files on first run;
   - snapshot the current value, then write, then re-read to verify;
   - tell you to **fully power off** afterwards.

6. **Confirm.** Power off, boot, `run.cmd` → option 1 again. With the fTPM
   patch the byte should now read `0x00`, and the TPM should be gone from the
   OS side (`Win32_Tpm : no instance`, the `ACPI\MSFT0101` device absent).

## Files

```
run.cmd / run.ps1             menu front-end around everything below

check_status.ps1              the read-only probe
apply_patch.ps1              the write engine -- applies any patches\*.patch
restore_original.ps1         the rollback engine -- undoes a patch
lib/patchfile.ps1            the one parser machine.txt and *.patch both go through
ve_parse.py                  parse an H2OUVE -gv dump
mkrec.py                     build patched record files / the undo file
machine.sample.txt           template for the local, git-ignored machine.txt

patches/                     your patch files go here (none are shipped)
tools/ifr_locate.py          find ANY setting's VarStore + byte offset (and prove it)
tools/README.md              how to use it

h2ouve/                      bring your own H2OUVE; dumps are generated here
docs/how-it-works.md         the method, in detail
docs/making-a-patch.md       the patch format, and writing your own
```

## Reading the value

| Byte | Meaning |
|---|---|
| `0x00` | Disable — fTPM off |
| `0x01` | Enable discrete TPM |
| `0x02` | Enable firmware TPM — fTPM on |

(The exact byte is the `OFFSET` key of the patch you are applying — for the
fTPM example, `0x100`.)

## Rollback

`run.cmd` option 4 (`restore_original.ps1 -Patch <file>`) re-writes the original
record from `h2ouve/undo_<slug>.txt` — a byte-for-byte copy of your pre-patch
dump, written by `apply_patch.ps1` on the first write (`<slug>` is the patch
file's name; the restore engine also accepts the older `setup_undo.txt` name).
Because that file **is** your only record of the original bytes, keep it: the
tool never deletes it, but do not move or edit it either. Then **fully power
off** and boot.

## What resets the setting

The variable is rewritten by the firmware in these cases, which will bring the
fTPM back:

- flashing / updating the BIOS, or clearing CMOS;
- choosing *Load Setup Defaults* in BIOS Setup and saving.

Note that a plain *Save and Exit* is harmless — it writes back whatever the
`Setup` variable already holds.

## Secure Boot

Secure Boot is **reported, not enforced**, on purpose. Turning the fTPM off only
touches an NVRAM byte that is independent of Secure Boot; Secure Boot only bears
on whether the vendor kernel driver loads. The driver's catalog carries a
Microsoft WHQL signature, so a write may well succeed with Secure Boot on — but
that combination is **unverified**, so the scripts warn and continue rather than
block. If installing `segwindrv` fails, turn Secure Boot off in BIOS and retry.

## Locating your own offset

Nothing ships with a built-in offset, and none should: an offset is one
firmware family's layout, and the same number on a different build means
something else entirely. Derive yours — do not take anyone's word for it,
including this file's.

`tools/ifr_locate.py` does the work:

```
python tools\ifr_locate.py find   Setup.bin "Trust Platform Module"
python tools\ifr_locate.py verify Setup.bin h2ouve\vars_orig.txt "Trust Platform Module"
```

`find` decodes your firmware's own IFR and prints the `VarStore`, its GUID, the
byte **offset**, the size and the value table. `verify` then matches that layout
against your `-gv` dump **by GUID** and checks the live byte really is one of the
declared values — so the offset is derived and proven, not assumed.

`find` also prints a candidate **patch file** — and `--out` writes it straight
to disk (`... find Setup.bin "Trust Platform Module" --out patches\my.patch`).
Check it by eye — which value is `FROM`, which is `TO` — and the whole workflow
(status check, apply, rollback) works on your setting exactly as it does on the
shipped fTPM one. Full usage: [`tools/README.md`](tools/README.md); the
by-hand version: [`docs/how-it-works.md`](docs/how-it-works.md) §4.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `ABORT: turn BitLocker OFF` (exit 11) | A volume is still TPM-protected. `manage-bde -off C:` (or `-protectors -disable C:`), or re-run with `-Force` if you hold the recovery key. |
| `unable to confirm that no volume is TPM-protected` (exit 12) | Neither BitLocker API answered. Run `manage-bde -status` yourself; if every volume says *Protection Off*, re-run with `-Force`. |
| Boot lands in **recovery mode** | BitLocker was still active when the TPM went away. Type the recovery key, or run `run.cmd` option 5 to put the TPM back, then `manage-bde -off C:`. |
| Windows Hello / PIN stopped working | Expected — its key was TPM-sealed. Re-enrol it under Sign-in options. |
| `GUID format is incorrect` | H2OUVE wants the GUID **without** braces. The scripts already do this. |
| Write reports success but nothing changes | The minimal record did not take; the script retries with the full dump automatically. Check the `-sv` output. |
| Driver install fails | Secure Boot on, or a locked-down driver policy. See *Secure Boot* above. |
| `setupapi.dev.log` shows the device install | Expected — H2OUVE installs and removes its driver per run; the script prints the tail. |
| Byte still `0x02` after a warm reboot | Power off fully, then boot. The setting is consumed at power-on. |

## Credits and legal

- The method was worked out against an Insyde H2O / AMD platform; the analysis
  scripts (`ve_parse.py`, `mkrec.py`, `tools/ifr_locate.py`) are original.
- `tools/ifr_locate.py` parses UEFI HII/IFR itself and needs no external tool;
  it can *optionally* drive LongSoft's **IFRExtractor-RS** if you have it, and it
  understands that tool's text output as well as the older
  **Universal-IFR-Extractor** layout. Neither is bundled or required.
- **H2OUVE and segwindrv are Insyde Software products** and are deliberately not
  distributed here. See [`h2ouve/README.md`](h2ouve/README.md).
- Code and docs are MIT — see [`LICENSE`](LICENSE). Not affiliated with Insyde or
  any OEM.
