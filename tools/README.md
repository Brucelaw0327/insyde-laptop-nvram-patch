# tools/

## `ifr_locate.py`

Finds **which byte of which NVRAM variable** backs a firmware setting, and then
**proves** it against a real dump. This is the `§4` procedure from
[`../docs/how-it-works.md`](../docs/how-it-works.md) turned into a program.

Nothing in this file writes to firmware. Nothing in it writes to disk except an
optional temporary file for the external engine.

### Why it exists

The rest of this repository refuses to hard-code `0x100`. That is the right
call — an offset is a property of one BIOS build — but it leaves the reader with
"go decode your firmware's setup module". This tool does that, so the answer is
derived rather than trusted.

### Getting an input

The easiest input is the **official BIOS upgrade package** — `extract` unwraps
it for you:

```
python ifr_locate.py extract <package>            # .zip / .exe (7z SFX) / .fd / .bin / .rom / .cap
```

It walks the whole chain (zip -> SFX exe -> .fd -> FFS volume -> LZMA section ->
DXE volume), carves out the Insyde SetupUtility FFS (`FE3542FE-...`), and writes
`Setup_<GUID>.ffs` to `<repo>\bios_cache\`. Then feed that file to `find`.
zip and raw images are pure stdlib. For the 7z SFX step the tool tries, in
order: a built-in stdlib 7z reader (plain LZMA archives), `py7zr` (pip), then a
7-Zip console binary. A portable **`bin\7za.exe`** ships with the repository
(7-Zip 26.04, sha256 `15d4c788c148e3677e2fc1c4a01f191fb6669eba4f6acf8a465f0f1a6f1e1260`,
same bytes as the official `7z2604-extra.7z` on github.com/ip7z/7zip and
7-zip.org; license text in `bin\7za-LICENSE.txt`) — with it present the whole
chain needs nothing else installed.
Drag the package onto the `run.cmd` window and option 2 does all of this.

Any of these also work directly as the `image` argument:

| Input | Notes |
|---|---|
| `Setup_<GUID>.ffs` | the Setup module FFS, if your firmware ships one |
| the PE32 section **body** | what UEFITool's *Extract body...* produces — the usual choice |
| a full `.fd` / `.bin` / `.cap` image | works, **unless** the Setup module sits inside a compressed section, in which case use `extract` instead |

To find the module in UEFITool: search the image for the option text (e.g.
`Trust Platform Module`, Unicode), jump to it, and the enclosing *PE32 image
section* is your module. Right-click it, *Extract body...*.

### Commands

```
python ifr_locate.py extract  <package>
python ifr_locate.py scan     <image> [keyword ...]
python ifr_locate.py find     <image> [keyword ...]   # no keyword = list all
python ifr_locate.py from-ifr <ifr.txt> <keyword ...>
python ifr_locate.py verify   <image> <h2ouve_dump.txt> [keyword ...]
```

| Command | What it does |
|---|---|
| `extract` | unwrap a BIOS **upgrade package** down to the Setup FFS (see above) |
| `scan` | every FORMS package found: form set, GUID, VarStores, question count |
| `find` | locate settings by keyword; prints the VarStore, GUID, **VarOffset**, size, option table, and a candidate **patch file**. With **no keyword** it lists every locatable setting (use `--json` for a machine-readable list) |
| `from-ifr` | same, but reads an IFR **text** file you produced earlier |
| `verify` | the proof step: match the IFR layout against a `H2OUVE -gv` dump |

Options (accepted before or after the subcommand): `--varstore NAME`,
`--limit N`, `--json`, `--out FILE` (with `find`/`from-ifr`: save the first
candidate patch to FILE instead of only printing it), `--ifr-extractor PATH`.

### Worked example

```
> python ifr_locate.py find Setup.bin "Trust Platform Module"

  Trust Platform Module  [OneOf]
    formset='Advanced'  form='Peripheral Configuration'
    varstore = SystemConfig (id 0x1234)
    guid     = A04A27F4-DF00-4D42-B552-39511302113D
    VarOffset= 0x100   size = 1 byte(s)
        Disable                        = 0x0
        Enable discrete TPM            = 0x1
        Enable firmware TPM            = 0x2

# --- candidate patch file (verify by eye before use) ---
# Advanced / Trust Platform Module
# save as patches\trust-platform-module.patch  and run it with:
#   powershell -ExecutionPolicy Bypass -File apply_patch.ps1 -Patch patches\trust-platform-module.patch
# RECORDS: the record names inside that store.  "Setup,Custom" is the
# SystemConfig pair; other stores use other names.
NAME     = Trust Platform Module -> Disable
VARSTORE = SystemConfig
GUID     = A04A27F4-DF00-4D42-B552-39511302113D
RECORDS  = Setup,Custom
OFFSET   = 0x100
FROM     = 0x2
TO       = 0x0
```

The stub is a **suggestion**. Read it before you save it — in particular check
that `FROM`/`TO` landed on the pair you want. `FROM` prefers the live NVRAM
value; when the Setup and Custom records disagree it takes **Custom**, which on
Insyde stores carries the effective (BIOS/user-made) value while Setup is the
factory image the firmware may rewrite at boot (confirmed on a machine where
the TPM on/off state tracked Custom across a BIOS-defaults restore). `TO`
prefers the meaningful direction: off when `FROM` is an "on" flavour, the
firmware-TPM / enabled flavour otherwise. The option table is only the last
fallback, and every guess prints a `# NOTE:` line.

`--out` removes the copy-paste:
`python ifr_locate.py find Setup.bin "Trust Platform Module" --out ..\patches\my.patch`
writes the first candidate straight to a file. The by-eye check does not
disappear — re-read what it wrote before applying.

Then prove it:

```
> python ifr_locate.py verify Setup.bin h2ouve\vars_orig.txt "Trust Platform Module"

IFR VarStore : 'SystemConfig'   guid=A04A27F4-DF00-4D42-B552-39511302113D   size=0x2BC
  record Setup      @105   guid=A04A27F4-...   len=700  size_field=0x2BC  size OK
     Trust Platform Module              0x100  = 0x2     -> Enable firmware TPM  (KNOWN value)
  record Custom     @107   guid=A04A27F4-...   len=700  size_field=0x2BC  size OK
     Trust Platform Module              0x100  = 0x0     -> Disable  (KNOWN value)

RESULT: consistent -- the IFR layout explains this dump
```

`verify` fails loudly (`RESULT: INCONSISTENT`) when:

- no record in the dump carries the GUID the IFR declares — wrong dump, or wrong
  firmware;
- the record's real length disagrees with the size the IFR declares;
- the live byte is **not** one of the values the option table lists;
- the offset is past the end of the record.

Any of those means the offset you are about to write is not the one you think it
is. Do not write.

### Two engines

**Native (default).** Parses the HII `FORMS` / `STRINGS` packages directly and
walks the IFR opcode stream. No download, no dependency beyond the standard
library. It pairs each `FORMS` package with the `STRINGS` package that actually
explains it (scored by how many referenced string ids resolve), because the
package ordering differs between vendors.

**External (optional).** `--ifr-extractor PATH/IFRExtractor-RS.exe` runs that
tool and parses its text output instead. `from-ifr` does the parsing half alone,
and accepts both the IFRExtractor-RS layout and the older
`Universal-IFR-Extractor` one.

Running both and diffing the results is a reasonable sanity check; they should
agree on the offset, the size and the option values.

### A note on IFR parsing

The `EFI_IFR_TYPE_VALUE` inside an option is **not** a bare integer: it is a
one-byte type tag followed by a value of that type. Tag `0x00` means "the next
byte is a u8", so the bytes `00 02` are the number **2**, not `0x0200`. Reading
it as a plain little-endian integer makes every single option parse as zero —
which is a silent, plausible-looking wrong answer. This tool parses the tag.

Likewise the `Flags` byte sits at `+13`, not `+12` (`+12` is `QuestionFlags`),
which shifts `Min`/`Max`/`Step` by one. Both were confirmed against real bytes
*and* against the IFRExtractor-RS reference parser before being written down.

### Interoperating with the rest of the repository

`find` emits a candidate **patch file** — the same format `apply_patch.ps1`
consumes. Save it as `patches\<slug>.patch` (or let `--out` write it), and the
standard workflow (status probe, `run.cmd` option 4 apply, option 5 rollback)
works on your setting unchanged; `apply_patch.ps1` passes the `OFFSET` through
to `mkrec.py` for you.

`run.cmd` option 2 wraps this whole step: it asks for the firmware image (or
keyword, and writes the candidate patch into `patches\` for you.
