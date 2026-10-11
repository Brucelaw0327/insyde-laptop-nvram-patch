# restore_original.ps1 -- roll back: write the ORIGINAL records back.
#
# The undo data is a byte-for-byte copy of the FIRST dump, taken before anything
# was written.  -Patch is required: it names the records and offsets to verify.
# Which undo FILE is used:
#
#   h2ouve\undo_<slug>.txt   when it exists (the undo file for that patch)
#   h2ouve\setup_undo.txt    otherwise (the generic rollback copy)
#
# Either way the content is pristine original bytes, so restoring is the way
# back to "before any patch was applied at all".
#
# run.cmd option 4 asks for the patch and runs this.  Log: undo_<timestamp>.txt
#
# Like apply_patch.ps1 this refuses to run on a machine/BIOS other than
# machine.txt: the record is a snapshot of ONE BIOS build's layout, and pushing
# it into a different build could scramble an unrelated setting.  -Force
# overrides.  Keep this file pure ASCII.
#
# BitLocker: reported, NOT gated here.  This is the rescue path -- if a
# TPM-protected volume is currently sitting in recovery mode, putting the TPM
# back is exactly how you fix it, so blocking on BitLocker would be backwards.

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

# Sanitise OutDir -- see apply_patch.ps1 for the "%~dp0" quote-escaping trap.
$OutDir = $OutDir.Trim('"').Trim()
while ($OutDir.Length -gt 3 -and $OutDir.EndsWith('\')) { $OutDir = $OutDir.Substring(0, $OutDir.Length - 1) }
if (-not $OutDir -or -not (Test-Path -LiteralPath $OutDir)) { $OutDir = $here }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $OutDir ("undo_{0}.txt" -f $stamp)
$L = New-Object System.Collections.Generic.List[string]
function Say([string]$m) { [void]$L.Add($m); Write-Host $m }
function Flush {
    try { $L -join "`r`n" | Set-Content -LiteralPath $logPath -Encoding UTF8 }
    catch { Write-Host ("WARN: could not write log to {0}" -f $logPath) }
}

Say "restore_original -- write the ORIGINAL records back (undo a patch)"
Say ("log = {0}" -f $logPath)
Say ("tool dir = {0}" -f $dir)

$isAdmin = $false
try {
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
if (-not $isAdmin) { Say "NOT elevated -- use run.cmd option 4, or an elevated PowerShell."; Flush; exit 3 }

$exe = Join-Path $dir 'H2OUVE-W-CONSOLEx64.exe'
if (-not (Test-Path $exe)) {
    Say ("missing: {0}" -f $exe)
    Say "Put H2OUVE-W-CONSOLEx64.exe into the h2ouve\ folder -- see h2ouve\README.md."
    Flush; exit 2
}

# ---------------------------------------------------------------- the undo file
$pdef = $null
if (-not $Patch) {
    Say "patch: no -Patch given."
    Say "       The patch file names the records and offsets to verify the rollback"
    Say "       against.  run.cmd option 4 asks for it."
    Flush; exit 2
}
$pdef = Read-PatchFile $Patch
if (-not $pdef.Ok) { Say ("patch: {0}" -f $pdef.Err); Flush; exit 2 }
$recs = @($pdef.Records)
$changes = @($pdef.Changes)
$primary = $recs[0]

$undo = $null
if ($pdef.Path) {
    $cand = Join-Path $dir ('undo_{0}.txt' -f $pdef.Slug)
    if (Test-Path -LiteralPath $cand) { $undo = $cand }
}
if (-not $undo) { $undo = Join-Path $dir 'setup_undo.txt' }

Say ""
Say "--- undo source ---"
Say ("   patch   = {0}" -f $pdef.Name)
Say ("   records = {0}" -f ($recs -join ', '))
if (-not (Test-Path -LiteralPath $undo)) {
    Say ("missing: {0}" -f $undo)
    Say "The undo file is the byte-for-byte copy of the FIRST dump, i.e. the state"
    Say "before anything was written.  Without it there is nothing to roll back to."
    Say "If you still have that dump as h2ouve\vars_orig.txt, rebuild with:"
    Say "    python mkrec.py --src h2ouve\vars_orig.txt --outdir h2ouve --name <slug>"
    Flush; exit 2
}
Say ("   file    = {0}" -f $undo)

$pyr = Resolve-Python
$py = if ($pyr) { $pyr[0] } else { $null }
$pyArgs = if ($pyr) { @($pyr[1]) } else { @() }
if (-not $py) {
    Say "python 3 not found (needed to parse record files)."
    Say "The repo ships one at tools\runtime\python -- re-extract the full repo."
    Flush; exit 9
}
$parser = Join-Path $here 've_parse.py'
Say ("python   = {0}" -f $py)

function ReadAny([string]$p) {
    if (-not (Test-Path $p)) { return $null }
    $raw = [System.IO.File]::ReadAllBytes($p)
    if ($raw.Length -eq 0) { return '' }
    return [System.Text.Encoding]::UTF8.GetString($raw)
}
function RunH2([string]$argline, [string]$outName) {
    $out = Join-Path $dir $outName
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    $bat = Join-Path $dir '_run_h2.bat'
    # Keep the batch body PURE ASCII -- see apply_patch.ps1 for the full reason.
    $t = "@echo off`r`ncd /d ""%~dp0""`r`n""H2OUVE-W-CONSOLEx64.exe"" $argline > ""%~dp0$outName"" 2>&1`r`n"
    [System.IO.File]::WriteAllText($bat, $t, [System.Text.Encoding]::ASCII)
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', $bat) `
         -WorkingDirectory $dir -NoNewWindow -Wait -PassThru
    return $p.ExitCode
}
function GetAt([string]$recFile, [string]$name, [int]$off) {
    $o = & $py @pyArgs $parser $recFile ('0x{0:X}' -f $off) $name 2>&1 | Out-String
    $sec = $o -split ("=== " + $name + " ===")
    if ($sec.Count -lt 2) { return -1 }
    $m = [regex]::Match($sec[1], ('@0x{0:X} = 0x([0-9A-Fa-f]{{2}})' -f $off))
    if (-not $m.Success) { return -1 }
    return [Convert]::ToInt32($m.Groups[1].Value, 16)
}
function Hx([int]$v) { if ($v -lt 0) { return '-1' } return ('0x{0:X2}' -f ($v -band 0xFF)) }

# Same collection as apply_patch.ps1 -- kept in sync on purpose (no shared
# module, so each script stays copy-pasteable on its own).
function Get-TpmDependents {
    $r = @{ BL = @(); BLKnown = $false; BLTool = ''; VBS = -1; VBSState = ''; CG = $false; HVCI = $false }
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
                if ($v.ProtectionStatus -eq 1) { $r.BL += ("{0}  protection=On (WMI)" -f $v.DriveLetter) }
            }
        } catch { }
    }
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' `
                -ClassName Win32_DeviceGuard -ErrorAction Stop
        $r.VBS = [int]$dg.VirtualizationBasedSecurityStatus
        $r.VBSState = switch ($r.VBS) { 0 { 'off' } 1 { 'configured, not running' } 2 { 'running' } default { '?' } }
        foreach ($s in @($dg.SecurityServicesRunning)) {
            if ($s -eq 1) { $r.CG = $true }
            if ($s -eq 2) { $r.HVCI = $true }
        }
    } catch { }
    return $r
}

# ---------------------------------------------------------------- config + gate
function GetRegStr([string]$name) {
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name $name -ErrorAction Stop).$name
        if ($v -is [array]) { $v = $v[0] }
        return ("$v").Trim()
    } catch { return $null }
}
$exp = Read-MachineFile $here
$haveCfg = ($exp.BIOS -and $exp.BOARD -and $exp.MODEL)

$idBios  = GetRegStr 'BIOSVersion'
$idBoard = GetRegStr 'BaseBoardProduct'
$idModel = GetRegStr 'SystemProductName'
if (-not $idBios)  { try { $idBios  = ("$((Get-CimInstance Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion)").Trim() } catch { } }
if (-not $idBoard) { try { $idBoard = ("$((Get-CimInstance Win32_BaseBoard -ErrorAction Stop).Product)").Trim() } catch { } }
if (-not $idModel) { try { $idModel = ("$((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Model)").Trim() } catch { } }

Say ""
Say "--- identity gate (must match the machine the undo file came from) ---"
if (-not $haveCfg) {
    Say "   machine.txt is missing or incomplete."
    Say "   These are THIS machine's values (paste them into machine.txt):"
    Say ("     BIOS={0}"  -f $idBios)
    Say ("     BOARD={0}" -f $idBoard)
    Say ("     MODEL={0}" -f $idModel)
    if (-not $Force) {
        Say ""
        Say "ABORT: create machine.txt from machine.sample.txt first (see README)."
        Flush; exit 6
    }
    Say "WARNING: no machine.txt, but -Force was given -- continuing."
} else {
    Say ("   BIOS  = '{0}'  expected '{1}'  {2}" -f $idBios,  $exp.BIOS,  $(if ($idBios  -eq $exp.BIOS)  { 'OK' } else { 'MISMATCH' }))
    Say ("   board = '{0}'  expected '{1}'  {2}" -f $idBoard, $exp.BOARD, $(if ($idBoard -eq $exp.BOARD) { 'OK' } else { 'MISMATCH' }))
    Say ("   model = '{0}'  expected '{1}'  {2}" -f $idModel, $exp.MODEL, $(if ($idModel -eq $exp.MODEL) { 'OK' } else { 'MISMATCH' }))
    $idOk = ($idBios -eq $exp.BIOS) -and ($idBoard -eq $exp.BOARD) -and ($idModel -eq $exp.MODEL)
    if (-not $idOk -and -not $Force) {
        Say ""
        Say "ABORT: the undo file was generated on a DIFFERENT machine / BIOS."
        Say "       Restoring it here could scramble an unrelated NVRAM setting."
        Say "       Re-dump this BIOS and regenerate the record files first."
        Say "       (-Force overrides if you are certain.)"
        Flush; exit 7
    }
}
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Say ("   OS    = {0}  build {1}" -f $os.Caption, $os.BuildNumber)
} catch { }

# Secure Boot: reported, not enforced (same reasoning as apply_patch.ps1).  The
# rescue path in particular must never be blocked by it.
$sbReg = $null
try {
    $sbReg = [int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name 'UEFISecureBootEnabled' -ErrorAction Stop).UEFISecureBootEnabled
} catch { }
if ($sbReg -eq 1) {
    Say "   SB    = Secure Boot is ON."
    Say "           NOT blocked -- if this rollback fails while installing segwindrv,"
    Say "           turn Secure Boot off in BIOS and retry."
} elseif ($sbReg -eq 0) {
    Say "   SB    = OFF"
} else {
    Say "   SB    = (SecureBoot\State unreadable)"
}

# Reported, not gated -- see the note at the top of this file.
$dep = Get-TpmDependents
if ($dep.BL.Count -gt 0) {
    Say "   BL    = BitLocker / device encryption is ON:"
    foreach ($b in $dep.BL) { Say ("             {0}" -f $b) }
    Say "           NOT blocked: restoring the TPM is what un-sticks a volume that"
    Say "           is already in recovery mode.  If the volume is healthy, expect"
    Say "           one recovery prompt after the mandatory full power off -- have"
    Say "           the recovery key ready."
} elseif ($dep.BLKnown) {
    Say "   BL    = none protected"
} else {
    Say "   BL    = (state unknown -- query failed; 'manage-bde -status' to check)"
}
if ($dep.VBS -ge 0) {
    Say ("   VBS   = {0}{1}{2}" -f $dep.VBSState, $(if ($dep.CG) { ', Credential Guard' } else { '' }), $(if ($dep.HVCI) { ', HVCI' } else { '' }))
}

Say ""
Say "--- target values (from the undo file) ---"
foreach ($nm in $recs) {
    $cells = @()
    foreach ($c in $changes) { $cells += ('0x{0:X}->{1}' -f $c.Off, (Hx (GetAt $undo $nm $c.Off))) }
    Say ("   {0,-9}: {1}" -f $nm, ($cells -join '   '))
}
foreach ($c in $changes) {
    if ((GetAt $undo $primary $c.Off) -lt 0) {
        Say ("   the undo file has no 0x{0:X} in record '{1}' -- aborting" -f $c.Off, $primary)
        Flush; exit 4
    }
}

Say ""
Say "--- write back original records (-sv) ---"
$rc = RunH2 ('-sv ' + (Split-Path -Leaf $undo)) '_svu.txt'
Say ("   exit = {0}" -f $rc)
$t = ReadAny (Join-Path $dir '_svu.txt')
if ($t) { foreach ($ln in ($t -replace "`r`n", "`n") -split "`n") { if ($ln.Trim()) { Say ("   | " + $ln) } } }
Start-Sleep -Seconds 2

Say ""
Say "--- verify ---"
$rc = RunH2 '-gv vars_undo.txt' '_gvu.txt'
Say ("   exit = {0}" -f $rc)
$ok = $true
foreach ($nm in $recs) {
    $cells = @()
    foreach ($c in $changes) {
        $v = GetAt (Join-Path $dir 'vars_undo.txt') $nm $c.Off
        $want = GetAt $undo $nm $c.Off
        if ($nm -eq $primary -and $v -ne $want) { $ok = $false }
        $cells += ('0x{0:X}={1}{2}' -f $c.Off, (Hx $v), $(if ($v -eq $want) { '' } else { ' <-- want ' + (Hx $want) }))
    }
    Say ("   {0,-9}: {1}" -f $nm, ($cells -join '   '))
}

Say ""
if ($ok) { Say ("RESULT: rolled back -- {0}" -f $pdef.Name) }
else {
    Say "RESULT: NOT restored -- the primary record does not match the undo file."
    Say "        review the -sv output above, then FULL POWER OFF and boot."
}
Say "NEXT  : full power off, then boot (the setting is read at power-on)."

Flush
Say ""
Say ("log written to: {0}" -f $logPath)
# non-zero when the primary record did not come back, so a wrapper can tell
if ($ok) { exit 0 } else { exit 1 }
