# How it works

> 中文版：[how-it-works.zh-CN.md](how-it-works.zh-CN.md)

A walkthrough of the method, including the dead ends, so you can redo it on your
own firmware instead of trusting a byte offset someone else found.

---

## 1. The problem

You want the firmware TPM off. On many consumer laptops the BIOS Setup UI either
does not show the TPM page, or shows it without an off switch. The settings that
*should* control it are:

| Setting | Typical IFR meaning |
|---|---|
| `Trust Platform Module` | `0 = Disable`, `1 = Discrete TPM`, `2 = Firmware TPM` |
| `TPM Availability` | `Available` / `Hidden` |
| `Current TPM Device` | which device the firmware publishes |

These live in the **`Setup` UEFI variable** (an Insyde variable store, commonly
GUID `A04A27F4-DF00-4D42-B552-39511302113D`), which is exactly what the OS cannot
write — see next section.

### Before you touch it: what depends on the TPM

On the platforms this targets the fTPM is the **only** TPM, so "fTPM off" means
"the OS has no TPM". That is a functional change, not just a hidden setting:

- **BitLocker / device encryption** seals its volume master key to the TPM. With
  no TPM at the next boot the volume has no protector it can satisfy, and it
  comes up in **recovery mode** — hence the hard gate in `apply_patch.ps1`
  (exit code 11). Decrypt (`manage-bde -off C:`) or suspend one boot
  (`manage-bde -protectors -disable C:`) first.
- **Windows Hello** (PIN / fingerprint / face) keys are TPM-sealed and must be
  re-enrolled.
- **Credential Guard / VBS** secrets are sealed to the TPM and are not
  recoverable; HVCI loses its attestation.
- Any third-party app that stores a key in the TPM loses that key.

None of these are firmware hazards — they are *data* hazards — which is why they
are reported separately from the firmware gates. `run.cmd` option 1
prints all of them.

## 2. The routes that do not work

Writing the byte from the OS is the obvious idea. It fails, for reasons worth
understanding:

**The `Setup` variable is write-protected, per variable *name*.** A plain
`SetFirmwareEnvironmentVariable` returns error 19 (`ERROR_WRITE_PROTECT`), and so
does `dmpstore` from the EFI shell. What makes this interesting: the lock is
**per-NAME, not global**. On the platform this was worked out on, `Setup` was
locked but several sibling stores (`Custom`, `AmdSetup`, `AMD_PBS_SETUP`,
`AOD_SETUP`) were writable. So "can I write variables?" is the wrong question —
ask *which* ones.

**The TCG2 physical-presence route is closed by specification.** The TPM2 PPI
interface used to define a "turn off" opcode; it was removed. Submitting
`PPRequest = 2` (DISABLE) results in the firmware consuming the request, judging
the opcode invalid, and booting on. You can confirm this on your own machine: the
`Tcg2PhysicalPresence` variable ends up with `PPRequest = 0` and
`LastPPRequest = 2`, i.e. it was seen and rejected.

**Standard AMD CBS/PBS explorers do not surface the page.** Tools that enumerate
the AMD overclocking pages stop at `AMD CBS` / `AMD PBS`, because the TPM option
is not in those form sets — it is in the OEM's own setup form set. A tool that
only walks those pages reports "no such option" even though the byte exists.

**Loading shared defaults does not help.** It restores the *compiled-in* default,
which for an OEM build is usually `firmware TPM`.

## 3. The route that works: the vendor's SMI editor

Insyde ships a console tool, **H2OUVE** (`H2OUVE-W-CONSOLEx64.exe`), that edits
UEFI variables. Its value here is *how* it edits them:

```
H2OUVE-W-CONSOLEx64.exe
   └─ installs / loads segwindrvx64.sys        (a signed kernel driver)
        └─ issues an Insyde SMI (software interrupt)
             └─ SMM handler  VariableEditSmm     (ring -2)
                  └─ writes the NVRAM variable store
```

The write happens in **SMM**, below the DXE layer where the `SetVariable`
write-protection lives — so the per-name lock that blocks the OS does not apply.
It is not a bypass of a security boundary you own (the firmware is yours, and you
are already root-equivalent); it is just a different, vendor-sanctioned code path.

Two practical notes:

- **H2OUVE installs its own driver on demand.** It creates a root-enumerated
  device and runs a normal device install (`DIF_INSTALLDEVICE`), then removes it
  again. You do **not** need to pre-install anything, and you do not need
  `newdev.dll`. Trying to stage the driver yourself is a rabbit hole: a manually
  created devnode has no HardwareID, so `BuildDriverInfoList` finds nothing and
  the install fails with `SPAPI_E_NO_SUCH_DEVINST` (`0xE000020B`).
- **Only NVRAM changes.** No flash write, so the firmware version string is
  unchanged and there is no reflash risk.

## 4. Locating the byte

Do not trust `0x100`. Find it.

### 4.1 With the tool (recommended)

`tools/ifr_locate.py` does the whole job and needs only Python. You supply the
**Setup module**; everything else is derived.

```
# Get the Setup module body.  In UEFITool, find the PE32 image section whose
# text contains "Trust Platform Module", right-click -> Extract body... and
# save it as Setup.bin.  (A full .fd image, or the Setup_<GUID>.ffs file, also
# works as long as the module is not inside a compressed section.)

python tools\ifr_locate.py scan   Setup.bin
python tools\ifr_locate.py find   Setup.bin "Trust Platform Module"
python tools\ifr_locate.py verify Setup.bin h2ouve\vars_orig.txt "Trust Platform Module"
```

`find` prints the VarStore, its GUID, the **VarOffset**, the size, the option
table, and a ready-to-save **patch file** stub.  `verify` is the part that
matters: it opens your `-gv` dump, matches the VarStore **by GUID** (not by
name), and confirms the live byte at that offset is one of the values the IFR
declares.  On the machine this repository was written on it prints:

```
IFR VarStore : 'SystemConfig'   guid=A04A27F4-DF00-4D42-B552-39511302113D   size=0x2BC
  record Setup      @105   guid=A04A27F4-...   len=700  size_field=0x2BC  size OK
     Trust Platform Module              0x100  = 0x2     -> Enable firmware TPM  (KNOWN value)
  record Custom     @107   guid=A04A27F4-...   len=700  size_field=0x2BC  size OK
     Trust Platform Module              0x100  = 0x0     -> Disable  (KNOWN value)
RESULT: consistent -- the IFR layout explains this dump
```

Three facts line up and **none of them was hard-coded**: the firmware's own IFR
says this offset holds the TPM selector; the dump's GUID and record size match
the VarStore the IFR declares; and the byte there is a value the IFR lists.  That
is the difference between "someone said `0x100`" and "`0x100` is proven".

**Two engines.**  By default the tool walks the HII FORMS/STRINGS packages
itself, so there is nothing to download.  If you already have `IFRExtractor-RS`,
pass `--ifr-extractor IFRExtractor-RS.exe` and it will use that instead -- or run
both and diff them, they should agree.  `from-ifr` parses an IFR text file you
produced earlier, in either the IFRExtractor-RS or the older
`Universal-IFR-Extractor` layout.

### 4.2 Doing it by hand

The tool automates exactly these steps; useful to know if you want to check its
work:

1. **Dump the variable store.**
   ```
   h2ouve\H2OUVE-W-CONSOLEx64.exe -gv vars_orig.txt
   ```
   This is your rollback source. Keep it.

2. **Find where the option is defined.** Decode the firmware's setup module and
   locate the IFR `ONE_OF` question whose prompt is the TPM option. Its
   `VarStore` id resolves to the `Setup` store, and the question carries the byte
   **offset** inside that store's data. That offset is what you want. (On the
   firmware family this repository was written on it is `0x100`.)

3. **Confirm by value, not by hope.** Read the byte in the dump with
   `ve_parse.py`:
   ```
   python ve_parse.py h2ouve\vars_orig.txt 0x100
   ```
   You should see `Setup` and `Custom` agree, and the value should correspond to
   your current BIOS setting (`0x02` = firmware TPM on, in the example layout).

4. **Build the record files.** Normally `apply_patch.ps1` does this for you from
   the patch file. By hand it is:
   ```
   python mkrec.py --change 0x100:0x02:0x00
   ```
   This produces `setup_new.txt` (patched), `vars_new_full.txt` (full dump,
   patched) and `setup_undo.txt` (verbatim original), and re-parses each output
   to assert the requested bytes are in place and the undo file still holds the
   originals.  Repeat `--change` to move several bytes in one pass; `--offset /
   --old / --new` is the single-change spelling.

5. **Know your layout fingerprint.** The `Setup` record's `Attributes` and
   `DataSize` (e.g. `0x07` / `0x2BC`) are a property of the BIOS build. That pair
   is what the *layout gate* compares at write time, so a record file can never
   be written to a build whose layout has changed underneath it.

## 5. What a record file looks like

`-gv` and `-sv` use the same plain-text format: a comment header, then one block
per variable —

```
 [069] "Setup"
      GUID: A04A27F4-DF00-4D42-B552-39511302113D
      Attributes: 0x07
      DataSize: 0x2BC
      Data:
            00000000: 66 00 00 00 ... 
            00000010: ...
```

`mkrec.py` copies these blocks byte-for-byte and rewrites exactly the hex tokens
you asked for — nothing else moves, including line endings. Writing the
**minimal** file (header + `Setup` + `Custom` only) keeps the blast radius to the
records you actually intend to change, which is why the tool writes that rather
than the whole dump.

Two things to get right:

- **GUIDs are given without braces.** `-rd -vn "Setup" -vg A04A27F4-...` works;
  with `{...}` H2OUVE answers `GUID format is incorrect`.
- **Delete/zero semantics.** Per the header it prints, setting `DataSize` or
  `Attributes` to zero deletes a variable. The scripts never do this, but it is
  worth knowing before you hand-edit anything.

## 6. Pitfalls worth remembering

Collected while building this, some of which cost real time:

**A string existing in the firmware does not mean the menu item exists.**
Firmware string pools are shared and full of unmounted entries. On the platform
here, the setup module's string table contained `Load Custom Defaults` and
`Save Custom Defaults` — but decoding every form set showed **no `Exit` form
set**, and nothing referenced those strings. The BIOS's exit page was drawn by
the browser, and the real page had only `Exit Saving Changes` /
`Exit Discarding Changes` / `Load Setup Defaults` / `Discard Changes`. Always
confirm a menu item against a real screenshot or the form/IFR binding — never
against a `strings` hit.

**Never let a generated script carry a non-ASCII path.** The launchers write a
tiny `.bat` to invoke H2OUVE and capture its output. Writing that file with
`Encoding.ASCII` while interpolating an absolute path meant that on a
non-English install directory every accented/CJK character became `?`, the
redirect target became an unopenable path, and cmd reported "path not found"
**without ever launching H2OUVE** — a silent no-op. The fix: keep the batch body
pure ASCII and let cmd expand `%~dp0` at run time, so the path is never encoded
by us at all.

**Keep PowerShell scripts pure ASCII.** PowerShell 5.1 decodes a BOM-less file
using the console code page, so a UTF-8 comment can be mis-decoded and derail the
parser. The `.ps1` and `.cmd` files here are ASCII-only for that reason.

**Verify the write by diffing, not by trusting the success message.** Compare the
pre-write and post-write dumps record by record; assert that exactly one byte
moved. That is the difference between "the tool said OK" and "the firmware
changed the way I intended".

## 7. Reversal, and what re-arms it

The undo file is a byte-for-byte copy of your first dump, so restoring it puts
the store back exactly as it was. Because the fTPM setting is read at power-on,
**fully power off** afterwards — a warm reboot may not re-read it.

The firmware rewrites these variables when you:

- flash/update the BIOS, or clear CMOS;
- pick *Load Setup Defaults* in BIOS Setup and save.

A plain *Save and Exit* is safe: it writes back the value already in `Setup`.

The rescue path for a volume that is *already* stuck in recovery mode is
`run.cmd` option 5 (`restore_original.ps1 -Patch <file>`): it writes the pristine
record back, and the next boot can satisfy the protector again. That is also why
the restore script **reports** BitLocker but does not gate on it — blocking the
fix would be backwards. (The volume may still ask for the recovery key once;
keep it to hand.)

## 8. Scope

This method generalises to any Insyde H2O platform that exposes its variable
stores over the same SMI channel — including other hidden or write-protected
options (CFG Lock, DVMT, Above 4G decoding, and so on).

The **mechanism is generic and so is the scaffolding**:

- `tools/ifr_locate.py` finds the offset for *any* setting on *any* firmware, and
  it emits a patch file for it.
- A patch file names one store, its records, and one or more byte changes; the
  offset is no longer a constant anywhere in the scripts.
- `mkrec.py` patches any offset — "turning something on" is just a `--new` above
  `--old`, or a `TO` above a `FROM`.
- `apply_patch.ps1` / `restore_original.ps1` are one apply path and one rollback
  path for any patch, with the same gates in front of both.
- §2 and §6 are the parts that cost the real time: which routes are dead and why,
  and which traps look like progress but are not.

fTPM is still the only worked example — its walkthrough and the TPM-specific
reporting. No patch ships with the repository (a prebuilt one would be one
firmware family's layout wearing a generic costume); you derive yours from your
own firmware. That narrowness is deliberate: a gate you understand is worth more
than a framework you do not. The honest description of the whole repository is
therefore:

**a proven path, plus a method for putting the risk in a box — with fTPM as its
first and only worked example.**
