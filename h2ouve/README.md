# h2ouve/ -- bring your own H2OUVE

中文版：[README.zh-CN.md](README.zh-CN.md)

This folder is where the H2OUVE tool goes. **The binaries are not shipped with
this repository** -- they are Insyde proprietary software and redistributing
them is not ours to do.

Place these files here before applying a patch (`run.cmd` option 4):

| File | What it is |
|---|---|
| `H2OUVE-W-CONSOLEx64.exe` | the variable editor (console, x64) |
| `segwindrvx64.sys` | the kernel driver it installs on demand |
| `segwindrv.cat` | the driver's catalog / signature |
| `segwindrv.inf` | the driver's INF |
| `WDFInst.exe` | its bundled WDF installer helper (optional) |

Everything else in this folder is **generated locally** and is git-ignored:

- `vars_orig.txt` -- your first full NVRAM dump (`-gv`), the rollback source
- `vars_before.txt` / `vars_after.txt` -- pre/post snapshots of a write run
- `setup_new.txt` -- the patched record file that gets written
- `vars_new_full.txt` -- the full dump with the single byte patched
- `setup_undo.txt` -- verbatim original record, the generic rollback copy
- `undo_<slug>.txt` -- same bytes, named after the patch that built it
  (`run.cmd` option 5 prefers this one)

If the last three are missing, the apply step (run.cmd option 4 /
`apply_patch.ps1`) creates them for you, by dumping NVRAM and calling
`mkrec.py`.

## Where to obtain H2OUVE

Insyde does not publish it. Two public mirrors were checked while writing this
repository; both were live and carry the tool exactly as an OEM image ships it
(neither is affiliated with Insyde):

| Source | Contents | Notes |
|---|---|---|
| [`babybluue/insyde-h2o`](https://github.com/babybluue/insyde-h2o) | the full kit: console + GUI exes, driver, cat/inf, WDFInst, release notes | most complete copy found (2025) |
| [`xiaoMGitHub/LEGION_Y7000Series_Insyde_Advanced_Settings_Tools`](https://github.com/xiaoMGitHub/LEGION_Y7000Series_Insyde_Advanced_Settings_Tools) | console exe, driver, cat/inf, WDFInst, plus Legion-specific batch scripts | long-lived (2021); ignore its `Execute.bat` -- use this repository's `.cmd` files |

Linking is not redistributing: the binaries stay out of this repository on
purpose -- they are Insyde's property. Download, verify, keep local.

### Verify before use

This tool talks to your firmware through SMM, so a tampered copy is a serious
risk. Verify in this order:

**1. The driver is the real anchor.** Whatever exe you run, it is
`segwindrvx64.sys` that touches your firmware. It must carry a **Valid**
Authenticode signature from *Insyde Software Corp.* (Taipei, TW), and
`segwindrv.cat` a **Valid** signature from *Microsoft Windows Hardware
Compatibility Publisher* (WHQL):

```powershell
Get-AuthenticodeSignature .\segwindrvx64.sys, .\segwindrv.cat
```

**2. The exes are unsigned** (at least the builds this method was developed
against are) -- no signature to check, so compare hashes instead. The copy
this method was developed and verified against:

```
H2OUVE-W-CONSOLEx64.exe   3592192 bytes
  SHA256  15ABA3D30DB28C784C7F8D5563196F7E22CB2BC7B97741DF17ECA07397ABE791
WDFInst.exe                246272 bytes
  SHA256  E36764851124EE882FCDF2BD9405C7086ECEE74FB7628A42BCAEE758477251E2
segwindrvx64.sys            93600 bytes
  SHA256  C3325ABAAE268555FB249DF4CBB6596E1FB74EC73EFFD451989A44C474D0B592
segwindrv.cat                9000 bytes
  SHA256  EAFBF94FA4206C66A4B6DDB3595CABADA49D7B28463B938DB0BDB74A3F24A417
segwindrv.inf                4036 bytes
  SHA256  F19FE4A6B630789085B47BC1558E24F9D275168874B9C0AA112448CDFE0AD589
```

```powershell
Get-FileHash .\* -Algorithm SHA256
```

A differing hash is not automatically hostile -- Insyde shipped many H2OUVE
builds -- but it is a difference nobody has verified. Match the driver hashes
or read the binary; an unsigned **and** unmatched driver is hostile, full
stop.

## A note on legitimacy

Editing UEFI variables with a vendor service tool is a normal
administration/repair activity. Reverse-engineering *how* it works, and
documenting the method (which is what this repository is) is fine. Re-hosting
Insyde's binaries is not -- hence this folder ships documentation only.
