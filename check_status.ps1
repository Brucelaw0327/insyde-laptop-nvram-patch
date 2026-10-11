# check_status.ps1 -- READ-ONLY firmware / TPM status probe.  Writes NOTHING.
#
#   * machine identity (BIOS / board / model) -- the record-layout fingerprint.
#     Compared against machine.txt (see machine.sample.txt).  REPORT ONLY here;
#     this script never blocks, because a mismatch is exactly what you want to
#     SEE after a BIOS update.
#   * Secure Boot, read from the real UEFI variable + the registry mirror.
#   * TCG2 physical-presence variable state.
#   * the variable records a patch targets -- when -Patch is given: the store,
#     records, offset and live byte, exactly as apply_patch.ps1 sees them.
#     Without -Patch this section is skipped: there are no built-in offsets, and
#     a wrong offset silently explained is worse than none.
#   * BitLocker / device encryption, VBS / Credential Guard / HVCI and Windows
#     Hello -- everything that breaks when a TPM disappears.
#   * TPM presence on the OS side.
#   * with -Dump: one H2OUVE -gv pass at the end -> h2ouve\vars_live.txt
#     (read-only; the same dump option 2 reuses to show now= values).  Runs in
#     the already-elevated window, so it costs no extra UAC prompt.  Needs
#     H2OUVE present; skipped with a note when it is not.
#
# Usage:  check_status.ps1 [-Patch patches\<your>.patch] [-OutDir <dir>] [-Dump]
#         With -Patch it explains the SAME patch apply_patch.ps1 would apply.
#
# Log: stat_<timestamp>.txt next to this script.
#
# Keep this file pure ASCII: PowerShell 5.1 decodes a BOM-less file with the
# console code page, so non-ASCII comments can derail the parser.

param(
    [string]$Patch = '',
    [string]$OutDir = '',
    [switch]$Dump
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $PSCommandPath }
$lib = Join-Path $here 'lib\patchfile.ps1'
if (-not (Test-Path -LiteralPath $lib)) {
    Write-Host ("missing: {0}  (required -- it reads machine.txt and patch files)" -f $lib)
    exit 2
}
. $lib
if (-not $OutDir) { $OutDir = $here }
$OutDir = $OutDir.Trim('"').Trim()
while ($OutDir.Length -gt 3 -and $OutDir.EndsWith('\')) { $OutDir = $OutDir.Substring(0, $OutDir.Length - 1) }
if (-not $OutDir -or -not (Test-Path -LiteralPath $OutDir)) { $OutDir = $here }

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $OutDir ("stat_{0}.txt" -f $stamp)
$L = New-Object System.Collections.Generic.List[string]
function Say([string]$m, [string]$c) {
    [void]$L.Add($m)
    if ($c) { Write-Host $m -ForegroundColor $c } else { Write-Host $m }
}
function Flush {
    try { $L -join "`r`n" | Set-Content -LiteralPath $logPath -Encoding UTF8 }
    catch { Write-Host ("WARN: could not write log to {0}" -f $logPath) }
}

$sig = @"
using System;
using System.Runtime.InteropServices;
public static class UefiVar2
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern uint GetFirmwareEnvironmentVariableEx(
        string lpName, string lpGuid, byte[] pBuffer, uint nSize, out uint pdwAttributes);
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TOKEN_PRIVILEGES np,
        uint len, IntPtr prev, IntPtr ret);
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }
    public static int EnablePrivilegeEx(string name)
    {
        IntPtr tok;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x28, out tok)) return Marshal.GetLastWin32Error();
        LUID luid;
        if (!LookupPrivilegeValue(null, name, out luid)) return Marshal.GetLastWin32Error();
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1;
        tp.Privileges.Luid = luid;
        tp.Privileges.Attributes = 0x00000002;
        bool ok = AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        int err = Marshal.GetLastWin32Error();
        if (!ok) return err == 0 ? -1 : err;
        return err;
    }
}
"@
if (-not ('UefiVar2' -as [type])) { Add-Type -TypeDefinition $sig -ErrorAction Stop }

Say "check_status -- read-only firmware / TPM status"
Say ("log = {0}" -f $logPath)
$isAdmin = $false
try {
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
Say ("elevated = {0}" -f $isAdmin) $(if ($isAdmin) { 'Green' } else { 'Yellow' })
if ($isAdmin) {
    $pe = [UefiVar2]::EnablePrivilegeEx('SeSystemEnvironmentPrivilege')
    Say ("SeSystemEnvironmentPrivilege -> {0}  (0 = enabled)" -f $pe)
}

# ---------------------------------------------------------------- machine identity
function GetRegStr([string]$name) {
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name $name -ErrorAction Stop).$name
        if ($v -is [array]) { $v = $v[0] }
        return ("$v").Trim()
    } catch { return $null }
}
$idBios  = GetRegStr 'BIOSVersion'
$idBoard = GetRegStr 'BaseBoardProduct'
$idModel = GetRegStr 'SystemProductName'
if (-not $idBios)  { try { $idBios  = ("$((Get-CimInstance Win32_BIOS -ErrorAction Stop).SMBIOSBIOSVersion)").Trim() } catch { } }
if (-not $idBoard) { try { $idBoard = ("$((Get-CimInstance Win32_BaseBoard -ErrorAction Stop).Product)").Trim() } catch { } }
if (-not $idModel) { try { $idModel = ("$((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Model)").Trim() } catch { } }

# machine.txt is a LOCAL, git-ignored file holding the identity your record
# files were generated on.  Copy machine.sample.txt -> machine.txt and fill it
# in from the lines printed below.  The parser lives in lib\patchfile.ps1, which
# the two writer scripts also use -- this probe and the writers explain the SAME
# byte, which is exactly what went wrong when each parsed machine.txt itself.
$exp = Read-MachineFile $here
# The probe is the one place allowed to seed machine.txt: what it sees IS this
# machine, and step 1 of the quick start is where the file used to be typed in
# by hand.  The writers still refuse to invent config (apply_patch exits 6).
$seeded = $false
if (-not (Test-Path -LiteralPath (Join-Path $here 'machine.txt'))) {
    $seed = New-MachineFileFromLive $here
    if ($seed.Ok) { $seeded = $true; $exp = Read-MachineFile $here }
    else {
        Say ("  machine.txt is absent and could not be seeded automatically: {0}" -f $seed.Err) 'Yellow'
        Say "  create it by hand from machine.sample.txt instead." 'Yellow'
    }
}
$haveCfg = ($exp.BIOS -and $exp.BOARD -and $exp.MODEL)

# ---------------------------------------------------------------- what we explain
# The byte(s) reported below come from ONE place only: -Patch.  There are no
# built-in patches or offsets in this repository -- a byte change is described
# by a patch file (docs/making-a-patch.md), or nothing is reported.
$pdef = $null
if ($Patch) {
    $pdef = Read-PatchFile $Patch
    if (-not $pdef.Ok) { Write-Host ("patch: {0}" -f $pdef.Err); exit 2 }
}
$off        = if ($pdef) { @($pdef.Changes)[0].Off }  else { -1 }
$onVal      = if ($pdef) { @($pdef.Changes)[0].From } else { -1 }
$offVal     = if ($pdef) { @($pdef.Changes)[0].To }   else { -1 }
$recs       = if ($pdef) { @($pdef.Records) }         else { @() }
$PATCH_GUID = if ($pdef) { '{' + $pdef.Guid + '}' }     else { '' }

# Generic wording only: the script does not know what the byte means.
function ValWord([int]$v, [int]$aV, [int]$bV) {
    if ($v -eq $bV) { return ('0x{0:X2} = target  <== after the patch' -f $v) }
    if ($v -eq $aV) { return ('0x{0:X2} = source  <== before the patch' -f $v) }
    return ('0x{0:X2} = (not one of the patch values)' -f $v)
}

function CmpOne([string]$actual, [string]$expected) {
    if (-not $expected) { return 'n/a' }
    if ($actual -eq $expected) { return 'OK' }
    return 'MISMATCH'
}

# Everything below seals data to the TPM, so it all breaks once the fTPM stops
# being published.  REPORT ONLY here -- this script never blocks.
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

Say ""
if ($seeded) {
    Say "--- machine identity (machine.txt was absent -- seeded from this machine) ---" 'Green'
} elseif ($haveCfg) {
    Say "--- machine identity (compared with machine.txt) ---" 'Cyan'
} else {
    Say "--- machine identity (machine.txt not set up -- writing the values for you) ---" 'Yellow'
}
Say ("  BIOS  = '{0}'  expected '{1}'  {2}" -f $idBios,  $(if ($exp.BIOS)  { $exp.BIOS }  else { 'n/a' }), (CmpOne $idBios  $exp.BIOS))
Say ("  board = '{0}'  expected '{1}'  {2}" -f $idBoard, $(if ($exp.BOARD) { $exp.BOARD } else { 'n/a' }), (CmpOne $idBoard $exp.BOARD))
Say ("  model = '{0}'  expected '{1}'  {2}" -f $idModel, $(if ($exp.MODEL) { $exp.MODEL } else { 'n/a' }), (CmpOne $idModel $exp.MODEL))
Say ("  OS    = {0}  build {1}  ({2})" -f `
    $(try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { '?' }), `
    $(try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).BuildNumber } catch { '?' }), `
    $(try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).OSArchitecture } catch { '?' }))

if (-not $haveCfg) {
    Say ""
    Say "  ==> machine.txt is missing or incomplete." 'Yellow'
    Say "      Record these three values, then create machine.txt from machine.sample.txt:" 'Yellow'
    Say ("        BIOS={0}"  -f $idBios)  'Yellow'
    Say ("        BOARD={0}" -f $idBoard) 'Yellow'
    Say ("        MODEL={0}" -f $idModel) 'Yellow'
} elseif ($idBios -ne $exp.BIOS -or $idBoard -ne $exp.BOARD -or $idModel -ne $exp.MODEL) {
    Say ""
    Say "  ==> IDENTITY MISMATCH: your record files were generated on a different" 'Red'
    Say "      machine or BIOS build.  Do NOT apply any patch until you have" 'Red'
    Say "      re-dumped this firmware and re-located the byte -- see" 'Red'
    Say "      docs/how-it-works.md." 'Red'
}
Say ""

# ---------------------------------------------------------------- TPM dependents
# Read this before applying a patch: everything here leans on the TPM.
Say "--- TPM-dependent features (what removing a TPM will take with it) ---" 'Cyan'
$dep = Get-TpmDependents
if ($dep.BL.Count -gt 0) {
    Say "  BitLocker / device encryption : ON  <== apply_patch.ps1 will REFUSE" 'Red'
    foreach ($b in $dep.BL) { Say ("    " + $b) 'Red' }
    Say "    A TPM-protected volume boots into recovery mode once the TPM is gone." 'Yellow'
    Say "    Turn it off first:  manage-bde -off C:   -- or suspend one boot with:" 'Yellow'
    Say "                        manage-bde -protectors -disable C:" 'Yellow'
    Say "    (otherwise re-run apply_patch.ps1 with -Force and your recovery key)." 'Yellow'
} elseif ($dep.BLKnown) {
    Say "  BitLocker / device encryption : none protected" 'Green'
} else {
    Say "  BitLocker / device encryption : UNKNOWN (query failed)" 'Yellow'
    Say "    Check by hand with 'manage-bde -status' before disabling the fTPM." 'Yellow'
}
if ($dep.VBS -ge 0) {
    Say ("  VBS / core isolation          : {0}" -f $dep.VBSState) $(if ($dep.VBS -eq 2) { 'Yellow' } else { $null })
    if ($dep.CG)   { Say "    Credential Guard RUNNING -- secrets sealed to the TPM will be lost." 'Yellow' }
    if ($dep.HVCI) { Say "    HVCI (memory integrity) RUNNING." 'Yellow' }
}
Say "  Windows Hello (PIN / fingerprint / face) : keys live in the TPM; expect to" 'Yellow'
Say "    re-enrol it and to lose TPM-sealed secrets after the flip." 'Yellow'
Say ""

function ReadFw([string]$n, [string]$g, [uint32]$sz) {
    $buf = New-Object byte[] $sz
    $a = [uint32]0
    $c = [UefiVar2]::GetFirmwareEnvironmentVariableEx($n, $g, $buf, $sz, [ref]$a)
    $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($c -eq 0) { return @{ Ok = $false; Err = $e } }
    $o = New-Object byte[] $c
    [Array]::Copy($buf, $o, $c)
    return @{ Ok = $true; Data = $o; Attr = $a; Len = $c }
}

# ---------------------------------------------------------------- Secure Boot
# Read the REAL UEFI variable straight from firmware (authoritative), then the
# registry mirror as a cross-check.  REPORTED, never enforced -- see the note.
# Secure Boot OFF is NOT a precondition for the fTPM flip: that byte lives in
# NVRAM and is independent of SB.  SB only decides whether the vendor kernel
# driver loads.  If segwindrv.cat carries a Microsoft WHQL signature (Windows
# Hardware Compatibility Publisher) that is the kind Secure Boot accepts, so a
# write MAY work with SB on -- but that combination is unverified.
$SBG   = '{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}'   # EFI_GLOBAL_VARIABLE
$SBNAM = @{ 0 = 'DISABLED'; 1 = 'ENABLED' }
Say "--- Secure Boot (reported, NOT a gate) ---" 'Cyan'
$sbReg = $null
try {
    $sbReg = [int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name 'UEFISecureBootEnabled' -ErrorAction Stop).UEFISecureBootEnabled
} catch { }
$sbFw = $null
if ($isAdmin) {
    $xsb = ReadFw 'SecureBoot' $SBG 8
    if ($xsb.Ok -and $xsb.Len -ge 1) { $sbFw = [int]$xsb.Data[0] }
}
if ($null -ne $sbFw) {
    $nm = if ($SBNAM.ContainsKey($sbFw)) { $SBNAM[$sbFw] } else { '?' }
    Say ("  firmware NVRAM 'SecureBoot'  = 0x{0:X2}  =>  {1}" -f $sbFw, $nm) $(if ($sbFw -eq 0) { 'Green' } else { 'Yellow' })
} else {
    Say "  firmware NVRAM 'SecureBoot'  = (read failed / not elevated)"
}
Say ("  registry UEFISecureBootEnabled = {0}" -f $(if ($null -ne $sbReg) { $sbReg } else { '(key absent)' }))
if ($sbFw -eq 1 -or $sbReg -eq 1) {
    Say "  ==> Secure Boot is ON.  The driver-load step was only ever proven with" 'Yellow'
    Say "      Secure Boot OFF.  If a write fails while installing segwindrv, turn" 'Yellow'
    Say "      Secure Boot off in BIOS and retry." 'Yellow'
}

$PPG = '{AEB9C5C1-94F1-4D02-BFD9-4602DB2D3C54}'
$PPNAME = @{ 0='No Action'; 1='ENABLE'; 2='DISABLE'; 3='ACTIVATE'; 4='DEACTIVATE'; 5='CLEAR' }

Say "--- TCG2 physical presence (the request we submitted) ---" 'Cyan'
$r = ReadFw 'Tcg2PhysicalPresence' $PPG 16
if ($r.Ok) {
    $d = $r.Data
    $req = [int]$d[0]; $last = [int]$d[8]
    $pr = [BitConverter]::ToUInt32($d, 12)
    $nm  = if ($PPNAME.ContainsKey($req)) { $PPNAME[$req] } else { '?' }
    $lnm = if ($PPNAME.ContainsKey($last)) { $PPNAME[$last] } else { '?' }
    Say ("  PPRequest     = {0} ({1})" -f $req, $nm)
    Say ("  LastPPRequest = {0} ({1})" -f $last, $lnm)
    Say ("  PPResponse    = 0x{0:X8}" -f $pr)
    Say ("  raw = {0}" -f (($d | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
    if ($req -eq 0 -and $last -eq 2) {
        Say "  ==> FIRMWARE CONSUMED IT: it executed the PP path, judged opcode 2 invalid" 'Yellow'
        Say "      (TPM2 PPI has no 'turn off' op) and booted on. Path closed." 'Yellow'
    } elseif ($req -eq 2) {
        Say "  ==> NOT CONSUMED: the firmware never processes TCG2 PP at all." 'Yellow'
    }
} else { Say ("  read failed err={0}" -f $r.Err) 'Red' }
$rf = ReadFw 'Tcg2PhysicalPresenceFlags' $PPG 4
if ($rf.Ok) { Say ("  PPFlags = 0x{0:X8}" -f [BitConverter]::ToUInt32($rf.Data, 0)) }

Say ""
if ($pdef) {
    Say "--- the records this patch would touch ---" 'Cyan'
    Say ("  patch         : {0}" -f $pdef.Name) 'Green'
    Say ("  offset in use : 0x{0:X}   (from -Patch {1})" -f $off, (Split-Path -Leaf $pdef.Path)) 'Green'
    Say ("  values        : source=0x{0:X2}  target=0x{1:X2}" -f $onVal, $offVal)
    Say ("  records       : {0}" -f ($recs -join ', '))
    $SG = $PATCH_GUID
    foreach ($nm in $recs) {
        $x = ReadFw $nm $SG 0x800
        if ($x.Ok) {
            $d = $x.Data
            if ($off -ge $x.Len) {
                Say ("  {0,-9} len=0x{1:X} attr=0x{2:X}  0x{3:X} is BEYOND this record" -f $nm, $x.Len, $x.Attr, $off) 'Red'
                Say "            -- this offset does not belong to this firmware.  Do not write." 'Red'
            } else {
                Say ("  {0,-9} len=0x{1:X} attr=0x{2:X}  0x{3:X}={4}" -f $nm, $x.Len, $x.Attr, $off, (ValWord ([int]$d[$off]) $onVal $offVal)) 'Yellow'
            }
        } else { Say ("  {0,-9} read failed err={1}" -f $nm, $x.Err) 'Red' }
    }
} else {
    Say "--- the records a patch would touch : (skipped -- no -Patch given) ---" 'Cyan'
    Say "  There are NO built-in offsets in this repository.  To have this probe"
    Say "  explain a change, pass the patch file:  check_status.ps1 -Patch <file>"
    Say "  (run.cmd option 3 does exactly that).  To make a patch, use run.cmd"
    Say "  option 2 or see docs/making-a-patch.md."
}

Say ""
Say "--- OS side: is the TPM visible? ---" 'Cyan'
try {
    $p = Get-CimInstance -Namespace root/cimv2/security/microsofttpm -ClassName Win32_Tpm -ErrorAction Stop
    if ($p) {
        Say ("  Win32_Tpm : Present={0} Enabled={1} Activated={2} Owned={3} Spec={4} FW={5}" -f `
            $p.IsTPMPresent, $p.IsEnabled_InitialValue, $p.IsActivated_InitialValue, $p.IsOwned_InitialValue, $p.SpecVersion, $p.ManufacturerVersion)
    } else { Say "  Win32_Tpm : no instance (TPM not present to the OS)" 'Green' }
} catch { Say ("  Win32_Tpm query failed: {0}" -f $_.Exception.Message) 'Yellow' }
$dev = Get-PnpDevice -Class SecurityDevices -ErrorAction SilentlyContinue
if ($dev) { foreach ($d in $dev) { Say ("  device  : {0}   status={1}" -f $d.InstanceId, $d.Status) } }
else { Say "  device  : none under SecurityDevices  <== ACPI\MSFT0101 gone" 'Green' }

# ---------------------------------------------------------------- optional live NVRAM dump
# One H2OUVE -gv pass -> h2ouve\vars_live.txt.  Read-only (-gv only dumps).
# Option 2 reuses the newest dump in h2ouve\ to show now= values, so running
# the probe first means option 2 never has to dump again.  Skipped (with a
# note) when H2OUVE is not in h2ouve\ or the session is not elevated.
if ($Dump) {
    Say ""
    Say "--- live NVRAM dump (H2OUVE -gv, read-only) ---" 'Cyan'
    $h   = Join-Path $here 'h2ouve'
    $exe = Join-Path $h 'H2OUVE-W-CONSOLEx64.exe'
    if (-not $isAdmin) {
        Say "  not elevated -- skipping the dump (H2OUVE -gv needs admin)." 'Yellow'
    } elseif (-not (Test-Path -LiteralPath $exe)) {
        Say ("  H2OUVE not found: {0} -- skipped.  See h2ouve\README.md." -f $exe) 'Yellow'
    } else {
        $out = Join-Path $h 'vars_live.txt'
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
        Push-Location -LiteralPath $h
        & $exe -gv vars_live.txt
        $rc = $LASTEXITCODE
        Pop-Location
        if ($rc -eq 0 -and (Test-Path -LiteralPath $out) -and (Get-Item $out).Length -gt 0) {
            Say ("  NVRAM dumped -> {0}  ({1} bytes)  -- option 2 will show now= values" -f $out, (Get-Item $out).Length) 'Green'
        } else {
            Say ("  H2OUVE -gv failed (exit code {0}) -- no dump written." -f $rc) 'Red'
        }
    }
}

Flush
Say ""
Say ("log written to: {0}" -f $logPath) 'Green'
