# apply_patch.ps1 -- apply ONE patch file: write the byte(s) it describes through
# the H2OUVE SMI channel.  This MODIFIES firmware NVRAM.  Read DISCLAIMER.md and
# docs/how-it-works.md before running it.
#
# A "patch" is a small text file naming a variable store, the records inside it,
# and one or more byte changes (OFFSET / FROM / TO, or CHANGE lines).  Make one
# with run.cmd option 2 (tools\ifr_locate.py) or by hand -- format and safety
# notes in docs/making-a-patch.md.  There are NO built-in patches or offsets:
# a byte change always comes from a patch file you point at with -Patch.
#
#     powershell -ExecutionPolicy Bypass -File apply_patch.ps1 -Patch patches\my.patch
#
# run.cmd is the menu front-end around this script.
#
# Order of operations:
#   G   identity gate  -- refuse to run on a machine/BIOS other than machine.txt
#   P   the patch      -- read and validate the patch file
#   G2  TPM-deps gate  -- refuse to run while BitLocker/device encryption is ON
#   B   bootstrap      -- if the record files are missing, dump NVRAM and build them
#   0   state + pre-write snapshot  (-gv vars_before.txt)   <- undo data
#   0b  layout gate    -- live records must match the patched record file
#   1   read test  -rd -vn "<first record>" -vg <guid>   (GUID WITHOUT braces)
#   2   sanity check of the patched record file
#   3   WRITE      -sv setup_new.txt
#   4   verify     -gv vars_after.txt -> re-read every change
#       fallback   -sv vars_new_full.txt  if step 3 did not take
#   5   tail of setupapi.dev.log
#
# Undo: restore_original.ps1  (writes the pristine record bytes back)
# Keep this file pure ASCII (PowerShell 5.1 mis-decodes BOM-less UTF-8).

param(
    [string]$Patch = '',
    [string]$OutDir = '',
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $PSCommandPath }
$lib = Join-Path $here 'lib\patchfile.ps1'
if (-not (Test-Path -LiteralPath $lib)) { Write-Host ("missing: {0}" -f $lib); exit 2 }
. $lib

$dir = Join-Path $here 'h2ouve'
if (-not (Test-Path $dir)) { $dir = $here }
if (-not $OutDir) { $OutDir = $here }

# Sanitise OutDir: a cmd line ending in "%~dp0" smuggles a literal quote into the
# value (the trailing backslash eats the closing quote), which makes Set-Content
# fail with "illegal characters in path".
$OutDir = $OutDir.Trim('"').Trim()
while ($OutDir.Length -gt 3 -and $OutDir.EndsWith('\')) { $OutDir = $OutDir.Substring(0, $OutDir.Length - 1) }
if (-not $OutDir -or -not (Test-Path -LiteralPath $OutDir)) { $OutDir = $here }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $OutDir ("wr_{0}.txt" -f $stamp)
$L = New-Object System.Collections.Generic.List[string]
function Say([string]$m) { [void]$L.Add($m); Write-Host $m }
function Flush {
    try { $L -join "`r`n" | Set-Content -LiteralPath $logPath -Encoding UTF8 }
    catch { Write-Host ("WARN: could not write log to {0}" -f $logPath) }
}

Say "apply_patch -- write a patch's bytes through H2OUVE"
Say ("log      = {0}" -f $logPath)
Say ("tool dir = {0}" -f $dir)

$isAdmin = $false
try {
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
Say ("elevated = {0}" -f $isAdmin)
if (-not $isAdmin) { Say "NOT elevated -- use run.cmd option 4, or an elevated PowerShell."; Flush; exit 3 }

$exe = Join-Path $dir 'H2OUVE-W-CONSOLEx64.exe'
if (-not (Test-Path $exe)) {
    Say ("missing: {0}" -f $exe)
    Say "Put H2OUVE-W-CONSOLEx64.exe into the h2ouve\ folder -- see h2ouve\README.md."
    Flush; exit 2
}

# ---------------------------------------------------------------- python
$pyr = Resolve-Python
$py = if ($pyr) { $pyr[0] } else { $null }
$pyArgs = if ($pyr) { @($pyr[1]) } else { @() }
if (-not $py) {
    Say "python 3 not found (needed to build/parse record files)."
    Say "The repo ships one at tools\runtime\python -- re-extract the full repo."
    Flush; exit 9
}
$parser = Join-Path $here 've_parse.py'
Say ("python   = {0}" -f $py)

function ReadAny([string]$p) {
    if (-not (Test-Path $p)) { return $null }
    $raw = [System.IO.File]::ReadAllBytes($p)
    if ($raw.Length -eq 0) { return '' }
    if ($raw.Length -ge 2 -and $raw[0] -eq 0xFF -and $raw[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($raw, 2, $raw.Length - 2)
    }
    $nul = 0
    $n = [Math]::Min($raw.Length, 512)
    for ($i = 1; $i -lt $n; $i += 2) { if ($raw[$i] -eq 0) { $nul++ } }
    if ($n -gt 0 -and ($nul * 2) -ge ($n / 2)) { return [System.Text.Encoding]::Unicode.GetString($raw) }
    return [System.Text.Encoding]::UTF8.GetString($raw)
}

function RunH2([string]$argline, [string]$outName) {
    $out = Join-Path $dir $outName
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    $bat = Join-Path $dir '_run_h2.bat'
    # NOTE: keep the batch body PURE ASCII and let cmd expand %~dp0 at run time.
    # Interpolating an absolute path here would mangle a non-ASCII install dir
    # under Encoding.ASCII into '?', so the redirect target would become an
    # unopenable path and cmd would never even launch H2OUVE.  "%~dp0" always
    # means "the folder this .bat sits in", which is exactly $dir.
    $t = "@echo off`r`ncd /d ""%~dp0""`r`n""H2OUVE-W-CONSOLEx64.exe"" $argline > ""%~dp0$outName"" 2>&1`r`n"
    [System.IO.File]::WriteAllText($bat, $t, [System.Text.Encoding]::ASCII)
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', $bat) `
         -WorkingDirectory $dir -NoNewWindow -Wait -PassThru
    return $p.ExitCode
}

# parse a record file and return the byte at $off inside a named record (or -1)
function GetAt([string]$recFile, [string]$name, [int]$off) {
    $o = & $py $parser $recFile ('0x{0:X}' -f $off) $name 2>&1 | Out-String
    $sec = $o -split ("=== " + $name + " ===")
    if ($sec.Count -lt 2) { return -1 }
    $m = [regex]::Match($sec[1], ('@0x{0:X} = 0x([0-9A-Fa-f]{{2}})' -f $off))
    if (-not $m.Success) { return -1 }
    return [Convert]::ToInt32($m.Groups[1].Value, 16)
}

# parse a record file and return @{attr;size} of a named record (or -1/-1)
function GetRecMeta([string]$recFile, [string]$name) {
    $r = @{ attr = -1; size = -1 }
    if (-not (Test-Path -LiteralPath $recFile)) { return $r }
    $o = & $py $parser $recFile '0x0' $name 2>&1 | Out-String
    $sec = $o -split ("=== " + $name + " ===")
    if ($sec.Count -lt 2) { return $r }
    $m = [regex]::Match($sec[1], 'attr=0x([0-9A-Fa-f]{2})\s+size=0x([0-9A-Fa-f]+)')
    if ($m.Success) {
        $r.attr = [Convert]::ToInt32($m.Groups[1].Value, 16)
        $r.size = [Convert]::ToInt32($m.Groups[2].Value, 16)
    }
    return $r
}
function FmtHex([int]$v) { if ($v -lt 0) { return 'n/a' } return ('0x{0:X2}' -f $v) }
function FmtSz([int]$v)  { if ($v -lt 0) { return 'n/a' } return ('0x{0:X}' -f $v) }
function Hx([int]$v)     { if ($v -lt 0) { return '-1' } return ('0x{0:X2}' -f ($v -band 0xFF)) }

# ---------------------------------------------------------------- config
function GetRegStr([string]$name) {
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name $name -ErrorAction Stop).$name
        if ($v -is [array]) { $v = $v[0] }
        return ("$v").Trim()
    } catch { return $null }
}
function GetSysId {
    $b = GetRegStr 'BIOSVersion'
    $d = GetRegStr 'BaseBoardProduct'
    $m = GetRegStr 'SystemProductName'
    if (-not $b) { try { $b = ("$((Get-CimInstance Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion)").Trim() } catch { } }
    if (-not $d) { try { $d = ("$((Get-CimInstance Win32_BaseBoard -ErrorAction Stop).Product)").Trim() } catch { } }
    if (-not $m) { try { $m = ("$((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Model)").Trim() } catch { } }
    return @{ BIOS = $b; BOARD = $d; MODEL = $m }
}
function GetFwMode {
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction Stop).PEFirmwareType
        if ($v -eq 2) { return 'UEFI' }
        if ($v -eq 1) { return 'Legacy/BIOS' }
        return ("PEFirmwareType={0}" -f $v)
    } catch { }
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') {
        try {
            $sb = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name 'UEFISecureBootEnabled' -ErrorAction Stop).UEFISecureBootEnabled
            return ("UEFI (SecureBoot\State present, UEFISecureBootEnabled={0})" -f $sb)
        } catch { return 'UEFI (SecureBoot\State present)' }
    }
    return 'unknown (no PEFirmwareType, no SecureBoot\State)'
}

# Anything that seals data to the TPM breaks the moment the TPM stops being
# published.  BitLocker is the one that can lock you out of the OS volume, so it
# is a HARD GATE (see G2 below).  VBS / Credential Guard / HVCI and Windows
# Hello are collected too, but only REPORTED -- losing them is an inconvenience,
# not a lockout.
function Get-TpmDependents {
    $r = @{ BL = @(); BLKnown = $false; BLTool = ''; VBS = -1; VBSState = ''; CG = $false; HVCI = $false }
    # --- BitLocker / device encryption: cmdlet first, raw WMI as fallback ---
    try {
        $vols = @(Get-BitLockerVolume -ErrorAction Stop)
        $r.BLKnown = $true; $r.BLTool = 'Get-BitLockerVolume'
        foreach ($v in $vols) {
            if ($v.ProtectionStatus -eq 'On') {
                $r.BL += ("{0}  protection=On  encrypted={1}%  {2}" -f $v.MountPoint, $v.EncryptionPercentage, $v.EncryptionMethod)
            }
        }
    } catch {
        try {
            $vols = @(Get-CimInstance -Namespace 'root\cimv2\security\microsoftvolumeencryption' `
                        -ClassName Win32_EncryptableVolume -ErrorAction Stop)
            $r.BLKnown = $true; $r.BLTool = 'Win32_EncryptableVolume'
            foreach ($v in $vols) {
                # ProtectionStatus: 1 = On, 0 = Off   (WMI enum, not the string cmdlet)
                if ($v.ProtectionStatus -eq 1) { $r.BL += ("{0}  protection=On (WMI)" -f $v.DriveLetter) }
            }
        } catch { }
    }
    # --- VBS / Credential Guard / HVCI ---
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' `
                -ClassName Win32_DeviceGuard -ErrorAction Stop
        $r.VBS = [int]$dg.VirtualizationBasedSecurityStatus
        $r.VBSState = switch ($r.VBS) { 0 { 'off' } 1 { 'configured, not running' } 2 { 'running' } default { '?' } }
        foreach ($s in @($dg.SecurityServicesRunning)) {
            if ($s -eq 1) { $r.CG = $true }      # 1 = Credential Guard
            if ($s -eq 2) { $r.HVCI = $true }    # 2 = HVCI / memory integrity
        }
    } catch { }
    return $r
}

$exp = Read-MachineFile $here
$haveCfg = ($exp.BIOS -and $exp.BOARD -and $exp.MODEL)
$id = GetSysId

Say ""
Say "--- G: identity gate (must match the machine the record files came from) ---"
if (-not $haveCfg) {
    Say "   machine.txt is missing or incomplete."
    Say "   These are THIS machine's values (paste them into machine.txt):"
    Say ("     BIOS={0}"  -f $id.BIOS)
    Say ("     BOARD={0}" -f $id.BOARD)
    Say ("     MODEL={0}" -f $id.MODEL)
    if (-not $Force) {
        Say ""
        Say "ABORT: create machine.txt from machine.sample.txt first (see README)."
        Flush; exit 6
    }
    Say "WARNING: no machine.txt, but -Force was given -- continuing."
} else {
    $idOk = ($id.BIOS -eq $exp.BIOS) -and ($id.BOARD -eq $exp.BOARD) -and ($id.MODEL -eq $exp.MODEL)
    Say ("   BIOS  = '{0}'  expected '{1}'  {2}" -f $id.BIOS,  $exp.BIOS,  $(if ($id.BIOS  -eq $exp.BIOS)  { 'OK' } else { 'MISMATCH' }))
    Say ("   board = '{0}'  expected '{1}'  {2}" -f $id.BOARD, $exp.BOARD, $(if ($id.BOARD -eq $exp.BOARD) { 'OK' } else { 'MISMATCH' }))
    Say ("   model = '{0}'  expected '{1}'  {2}" -f $id.MODEL, $exp.MODEL, $(if ($id.MODEL -eq $exp.MODEL) { 'OK' } else { 'MISMATCH' }))
    if (-not $idOk -and -not $Force) {
        Say ""
        Say "ABORT: these values do not match machine.txt."
        Say "       The record files describe ONE BIOS build's Setup layout; writing them"
        Say "       elsewhere could silently corrupt an unrelated setting.  Re-dump this"
        Say "       firmware, re-locate the byte, regenerate the records -- see"
        Say "       docs/how-it-works.md.  (-Force overrides.)"
        Flush; exit 7
    }
}
Say ("   boot  = {0}" -f (GetFwMode))

# ---------------------------------------------------------------- P: the patch
$pdef = $null
if (-not $Patch) {
    Say "patch: no -Patch given."
    Say "       A byte change is described by a patch file -- there are no built-in"
    Say "       offsets.  Make one with run.cmd option 2 or docs/making-a-patch.md,"
    Say "       then:  apply_patch.ps1 -Patch patches\<name>.patch"
    Flush; exit 2
}
$pdef = Read-PatchFile $Patch
if (-not $pdef.Ok) { Say ("patch: {0}" -f $pdef.Err); Flush; exit 2 }

$GUID    = $pdef.Guid
$recs    = @($pdef.Records)
$changes = @($pdef.Changes)
$primary = $recs[0]

Say ""
Say "--- P: patch ---"
Say ("   name    = {0}" -f $pdef.Name)
Say ("   source  = {0}" -f $pdef.Path)
Say ("   store   = {0}   guid={1}" -f $pdef.Varstore, $GUID)
Say ("   records = {0}   (primary: {1})" -f ($recs -join ', '), $primary)
foreach ($c in $changes) {
    Say ("   change  = offset 0x{0:X} : 0x{1:X2} -> 0x{2:X2}" -f $c.Off, $c.From, $c.To)
}

# Secure Boot is REPORTED here, never enforced.  OFF is NOT a precondition for
# an NVRAM byte change (that byte lives in NVRAM, independent of SB) -- it only
# bears on whether the vendor kernel driver loads.  If segwindrv.cat is Microsoft
# WHQL signed, that is the kind Secure Boot accepts, so a write MAY still go
# through with SB on; warn, don't block.
$sbReg = $null
try {
    $sbReg = [int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name 'UEFISecureBootEnabled' -ErrorAction Stop).UEFISecureBootEnabled
} catch { }
if ($sbReg -eq 1) {
    Say "   SB    = Secure Boot is ON."
    Say "           NOT blocked -- but the driver-load step was only ever proven"
    Say "           with Secure Boot OFF.  If this write fails while installing"
    Say "           segwindrv, turn Secure Boot off in BIOS and retry."
} elseif ($sbReg -eq 0) {
    Say "   SB    = OFF"
} else {
    Say "   SB    = (SecureBoot\State unreadable)"
}

# The OS build is RECORDED but deliberately NOT used as a gate: the hazard here
# is the RECORD LAYOUT, which is a function of the BIOS, not of the OS.  OS
# version strings are unreliable in any case -- registry ProductName and the WMI
# Caption routinely disagree.
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Say ("   OS    = {0}  build {1}  ({2})" -f $os.Caption, $os.BuildNumber, $os.OSArchitecture)
} catch { Say "   OS    = (query failed)" }

# ---------------------------------------------------------------- G2: TPM deps
# BitLocker is a HARD GATE.  Turning the fTPM off makes the TPM vanish from the
# OS at the next power-on; a TPM-protected volume then boots straight into
# recovery mode.  That is not a firmware risk, it is a "you cannot get back into
# Windows" risk -- so refuse to write until it is off, unless -Force.
# (A patch that does NOT touch the TPM cannot cause that, but this script cannot
# know what a byte means, so the gate is kept for every patch.)
Say ""
Say "--- G2: TPM-dependent features (BitLocker and friends) ---"
$dep = Get-TpmDependents
if ($dep.BL.Count -gt 0) {
    Say "   BitLocker / device encryption is ON:"
    foreach ($b in $dep.BL) { Say ("     {0}" -f $b) }
    if (-not $Force) {
        Say ""
        Say "ABORT: turn BitLocker OFF (or suspend it) before writing."
        Say "       If this patch removes the TPM from the OS, a TPM-protected volume"
        Say "       comes up in recovery mode within one power cycle.  Either"
        Say "       decrypt it:            manage-bde -off C:"
        Say "       or suspend for one boot: manage-bde -protectors -disable C:"
        Say "       (run 'manage-bde -status' to see every volume).  Then re-run"
        Say "       this script (run.cmd option 4).  If you already hold the"
        Say "       recovery key and accept the recovery prompt, re-run with"
        Say "       -Force instead."
        Flush; exit 11
    }
    Say "WARN: BitLocker is ON, but -Force was given -- continuing."
} elseif ($dep.BLKnown) {
    Say "   BitLocker / device encryption : none protected"
} else {
    Say "   BitLocker / device encryption : COULD NOT BE DETERMINED"
    Say "     Both Get-BitLockerVolume and Win32_EncryptableVolume failed.  The"
    Say "     script will not assume the safe state -- check by hand:"
    Say "           manage-bde -status"
    if (-not $Force) {
        Say ""
        Say "ABORT: unable to confirm that no volume is TPM-protected."
        Say "       Confirm with 'manage-bde -status' that every volume shows"
        Say "       'Protection Off', then re-run.  (-Force skips this check.)"
        Flush; exit 12
    }
    Say "WARN: BitLocker state unknown, but -Force was given -- continuing."
}
if ($dep.VBS -ge 0) {
    Say ("   VBS / core isolation          : {0}" -f $dep.VBSState)
    if ($dep.CG)   { Say "     Credential Guard is RUNNING -- its secrets are sealed to the TPM." }
    if ($dep.HVCI) { Say "     HVCI (memory integrity) is RUNNING." }
}
Say "   Windows Hello (PIN / fingerprint / face) keys live in the TPM; expect to"
Say "   re-enrol it, and to lose TPM-sealed secrets, once the fTPM is off."

# ---------------------------------------------------------------- bootstrap
Say ""
Say "--- B: record files ---"
$need = @('vars_orig.txt', 'setup_new.txt', 'setup_undo.txt')
$missing = @($need | Where-Object { -not (Test-Path (Join-Path $dir $_)) })
# Stale: setup_new.txt is present but does not hold THIS patch's target values
# (it was built for a different patch).  Writing it would carry the wrong bytes,
# so a rebuild is mandatory rather than a suggestion.
$stale = $false
if ($missing.Count -eq 0) {
    foreach ($nm in $recs) {
        foreach ($c in $changes) {
            if ((GetAt (Join-Path $dir 'setup_new.txt') $nm $c.Off) -ne $c.To) { $stale = $true }
        }
    }
}
if ($missing.Count -gt 0 -or $stale) {
    if ($missing.Count -gt 0) { Say ("   missing: {0}" -f ($missing -join ', ')) }
    if ($stale) { Say "   setup_new.txt does not hold this patch's target values -- rebuilding." }
    if (-not (Test-Path (Join-Path $dir 'vars_orig.txt'))) {
        Say "   dumping NVRAM first (-gv vars_orig.txt) ..."
        $rc = RunH2 '-gv vars_orig.txt' '_gv0.txt'
        Say ("   dump exit = {0}" -f $rc)
        if (-not (Test-Path (Join-Path $dir 'vars_orig.txt'))) {
            Say "   dump failed -- review _gv0.txt in the tool dir."
            Flush; exit 9
        }
    }
    Say "   building record files with mkrec.py ..."
    $mk = Join-Path $here 'mkrec.py'
    # remove first, so a failed build cannot leave a stale file that passes the
    # existence check below
    foreach ($f in @('setup_new.txt', 'setup_undo.txt', 'vars_new_full.txt')) {
        Remove-Item -LiteralPath (Join-Path $dir $f) -Force -ErrorAction SilentlyContinue
    }
    $mkArgs = @($mk, '--src', (Join-Path $dir 'vars_orig.txt'), '--outdir', $dir,
                '--records', ($recs -join ','), '--name', $pdef.Slug)
    foreach ($c in $changes) {
        $mkArgs += @('--change', ('0x{0:X}:0x{1:X}:0x{2:X}' -f $c.Off, $c.From, $c.To))
    }
    & $py @pyArgs @mkArgs 2>&1 | ForEach-Object { Say ("   | " + $_) }
    $mkRc = $LASTEXITCODE
    if ($mkRc -ne 0) { Say ("   mkrec.py failed (rc={0}) -- not writing anything." -f $mkRc); Flush; exit 9 }
    foreach ($f in @('setup_new.txt', 'setup_undo.txt')) {
        if (-not (Test-Path (Join-Path $dir $f))) { Say ("   FAILED to build {0}" -f $f); Flush; exit 9 }
    }
    Say "   record files ready."
    Say "   NOTE: records are rebuilt from vars_orig.txt, the PRISTINE first dump,"
    Say "         so this write also undoes any earlier patch that touched these"
    Say "         records.  To change several bytes at once, put them in ONE patch"
    Say "         (repeat the CHANGE line) -- see docs/making-a-patch.md."
} else {
    Say "   present and matching this patch: vars_orig.txt / setup_new.txt / setup_undo.txt"
}

# ---------------------------------------------------------------- pre-checks
foreach ($f in @('vars_orig.txt', 'setup_new.txt', 'setup_undo.txt')) {
    $p = Join-Path $dir $f
    if (-not (Test-Path $p)) { Say ("MISSING required file: {0}" -f $p); Flush; exit 2 }
}

Say ""
Say "--- 0: pre-write snapshot (-gv vars_before.txt) ---"
$rc = RunH2 '-gv vars_before.txt' '_gvb.txt'
Say ("   exit = {0}" -f $rc)
$pre = @{}
foreach ($nm in $recs) {
    $cells = @()
    foreach ($c in $changes) {
        $v = GetAt (Join-Path $dir 'vars_before.txt') $nm $c.Off
        $pre["$nm/$($c.Off)"] = $v
        $cells += ('0x{0:X}={1}' -f $c.Off, (Hx $v))
    }
    Say ("   BEFORE {0,-9}: {1}" -f $nm, ($cells -join '   '))
}
foreach ($c in $changes) {
    if ($pre["$primary/$($c.Off)"] -lt 0) {
        Say ("   cannot read 0x{0:X} in record '{1}' -- aborting (refusing to write blind)" -f $c.Off, $primary)
        Flush; exit 4
    }
}
$allDone = $true
foreach ($c in $changes) { if ($pre["$primary/$($c.Off)"] -ne $c.To) { $allDone = $false } }
if ($allDone) {
    Say "   every change is ALREADY in place in the primary record -- nothing to do."
    Flush; exit 0
}

Say ""
Say "--- 0b: layout gate (live records must match setup_new.txt) ---"
$layoutOk = $true
foreach ($nm in $recs) {
    $expM = GetRecMeta (Join-Path $dir 'setup_new.txt')   $nm
    $actM = GetRecMeta (Join-Path $dir 'vars_before.txt') $nm
    Say ("   setup_new.txt  {0,-9}: attr={1} size={2}" -f $nm, (FmtHex $expM.attr), (FmtSz $expM.size))
    Say ("   live           {0,-9}: attr={1} size={2}" -f $nm, (FmtHex $actM.attr), (FmtSz $actM.size))
    if ($expM.attr -lt 0 -or $actM.attr -lt 0 -or $expM.attr -ne $actM.attr -or $expM.size -ne $actM.size) {
        $layoutOk = $false
    }
}
if (-not $layoutOk) {
    Say "ABORT: the live records do not match setup_new.txt."
    Say "       The record layout changed (BIOS update?), or setup_new.txt was built"
    Say "       for a different variable store.  Regenerate the record files."
    if (-not $Force) { Flush; exit 8 }
    Say "WARNING: layout mismatch, but -Force was given -- writing anyway."
}

Say ""
Say "--- 1: read test (-rd, GUID WITHOUT braces -- braces caused 'GUID format is incorrect') ---"
$rc = RunH2 ('-rd -vn "' + $primary + '" -vg ' + $GUID) '_rd.txt'
Say ("   exit = {0}" -f $rc)
$t = ReadAny (Join-Path $dir '_rd.txt')
if ($t) { foreach ($ln in ($t -replace "`r`n", "`n") -split "`n") { if ($ln.Trim()) { Say ("   | " + $ln) } } }

Say ""
Say "--- 2: sanity check of the patched record file ---"
foreach ($nm in $recs) {
    $cells = @()
    foreach ($c in $changes) { $cells += ('0x{0:X}={1}' -f $c.Off, (Hx (GetAt (Join-Path $dir 'setup_new.txt') $nm $c.Off))) }
    Say ("   setup_new.txt {0,-9}: {1}" -f $nm, ($cells -join '   '))
}
$badNew = 0
foreach ($nm in $recs) { foreach ($c in $changes) { if ((GetAt (Join-Path $dir 'setup_new.txt') $nm $c.Off) -ne $c.To) { $badNew++ } } }
if ($badNew -gt 0) { Say "   setup_new.txt is not what we expect -- aborting"; Flush; exit 5 }

Say ""
Say "--- 3: WRITE  -sv setup_new.txt ---"
foreach ($c in $changes) {
    Say ("   {0}: 0x{1:X}: {2} -> {3}" -f $primary, $c.Off, (Hx $pre["$primary/$($c.Off)"]), (Hx $c.To))
}
$rc = RunH2 '-sv setup_new.txt' '_sv.txt'
Say ("   exit = {0}" -f $rc)
$t = ReadAny (Join-Path $dir '_sv.txt')
if ($t) { foreach ($ln in ($t -replace "`r`n", "`n") -split "`n") { if ($ln.Trim()) { Say ("   | " + $ln) } } }
Start-Sleep -Seconds 2

Say ""
Say "--- 4: verify (-gv vars_after.txt) ---"
$rc = RunH2 '-gv vars_after.txt' '_gva.txt'
Say ("   exit = {0}" -f $rc)
$post = @{}
foreach ($nm in $recs) {
    $cells = @()
    foreach ($c in $changes) {
        $v = GetAt (Join-Path $dir 'vars_after.txt') $nm $c.Off
        $post["$nm/$($c.Off)"] = $v
        $cells += ('0x{0:X}={1}{2}' -f $c.Off, (Hx $v), $(if ($v -eq $c.To) { '' } else { ' <-- want ' + (Hx $c.To) }))
    }
    Say ("   AFTER  {0,-9}: {1}" -f $nm, ($cells -join '   '))
}
$ok = $true
foreach ($c in $changes) { if ($post["$primary/$($c.Off)"] -ne $c.To) { $ok = $false } }

if (-not $ok) {
    Say ""
    Say "--- 4b: minimal file did not take, retry with the FULL record file ---"
    $rc = RunH2 '-sv vars_new_full.txt' '_sv2.txt'
    Say ("   exit = {0}" -f $rc)
    $t = ReadAny (Join-Path $dir '_sv2.txt')
    if ($t) { foreach ($ln in ($t -replace "`r`n", "`n") -split "`n") { if ($ln.Trim()) { Say ("   | " + $ln) } } }
    Start-Sleep -Seconds 2
    $rc = RunH2 '-gv vars_after2.txt' '_gva2.txt'
    Say ("   exit = {0}" -f $rc)
    $ok = $true
    foreach ($nm in $recs) {
        $cells = @()
        foreach ($c in $changes) {
            $v = GetAt (Join-Path $dir 'vars_after2.txt') $nm $c.Off
            $post["$nm/$($c.Off)"] = $v
            $cells += ('0x{0:X}={1}' -f $c.Off, (Hx $v))
            if ($nm -eq $primary -and $v -ne $c.To) { $ok = $false }
        }
        Say ("   AFTER2 {0,-9}: {1}" -f $nm, ($cells -join '   '))
    }
}

# Secondary records that did not land are worth knowing about, but they do not
# decide success -- the primary record is the one the setting is read from.
foreach ($nm in @($recs | Where-Object { $_ -ne $primary })) {
    foreach ($c in $changes) {
        if ($post["$nm/$($c.Off)"] -ne $c.To) {
            Say ("   NOTE: secondary record '{0}' did not take 0x{1:X} (has {2}, want {3})." -f `
                 $nm, $c.Off, (Hx $post["$nm/$($c.Off)"]), (Hx $c.To))
        }
    }
}

Say ""
Say "======================================================================"
if ($ok) {
    Say ("RESULT: SUCCESS  -- {0}" -f $pdef.Name)
    foreach ($c in $changes) { Say ("        {0}[0x{1:X}] = {2}" -f $primary, $c.Off, (Hx $post["$primary/$($c.Off)"])) }
    Say "NEXT  : full power off, then boot.  A firmware setting is read at power-on,"
    Say "        so a warm reboot may not be enough -- shut down fully."
    Say "        After boot run run.cmd option 1 to confirm."
    Say "UNDO  : run run.cmd option 5 (or restore_original.ps1 -Patch <this patch>)"
    Say "        to put the original bytes back."
} else {
    Say "RESULT: FAILED   -- the primary record still does not hold the target value"
    foreach ($c in $changes) { Say ("        {0}[0x{1:X}] = {2}  (want {3})" -f $primary, $c.Off, (Hx $post["$primary/$($c.Off)"]), (Hx $c.To)) }
    Say "        see the -sv output above and the setupapi.dev.log tail below."
}
Say "======================================================================"

Say ""
Say "=== setupapi.dev.log tail (last H2OUVE device installs) ==="
$slog = 'C:\Windows\inf\setupapi.dev.log'
if (Test-Path $slog) {
    $hits = @(Select-String -Path $slog -Pattern 'H2OUVE' -SimpleMatch -ErrorAction SilentlyContinue)
    Say ("   H2OUVE sections = {0}" -f $hits.Count)
    $st = [Math]::Max(0, $hits.Count - 25)
    for ($i = $st; $i -lt $hits.Count; $i++) { Say ("   L{0}: {1}" -f $hits[$i].LineNumber, $hits[$i].Line.Trim()) }
} else { Say "   no setupapi.dev.log" }

Say ""
Say "=== files ==="
foreach ($f in @('vars_orig.txt', 'vars_before.txt', 'vars_after.txt', 'vars_after2.txt', '_gvb.txt', '_rd.txt', '_sv.txt', '_sv2.txt', '_gva.txt')) {
    $p = Join-Path $dir $f
    if (Test-Path $p) { Say ("   {0,10}  {1}" -f (Get-Item $p).Length, $f) } else { Say ("   {0,10}  {1}" -f '-', $f) }
}

Flush
Say ""
Say ("log written to: {0}" -f $logPath)
# non-zero on a failed write, so a wrapper script can tell without parsing text
if ($ok) { exit 0 } else { exit 1 }
