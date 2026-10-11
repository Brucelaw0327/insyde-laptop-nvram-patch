# run.ps1 -- menu front-end for this repository.
#
# Launched by run.cmd.  Read-only actions run in this window; the two actions
# that MODIFY firmware NVRAM (apply / restore) ask for the patch file, demand a
# typed confirmation, and relaunch themselves elevated via UAC.
#
# Keep this file pure ASCII: PowerShell 5.1 decodes a BOM-less file with the
# console code page, so non-ASCII text can derail the parser.

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $PSCommandPath }
. (Join-Path $here 'lib\patchfile.ps1')      # Resolve-Python + patch helpers

function IsAdmin {
    try {
        return (New-Object Security.Principal.WindowsPrincipal(
            [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function ListPatches {
    return @(Get-ChildItem -LiteralPath (Join-Path $here 'patches') -Filter '*.patch' `
        -File -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Pick([string]$title) {
    $items = @(ListPatches)
    if ($items.Count -eq 0) {
        Write-Host ""
        Write-Host ("  no .patch files found in {0}" -f (Join-Path $here 'patches')) -ForegroundColor Yellow
        Write-Host "  make one with option 2 below, or by hand -- docs\making-a-patch.md." -ForegroundColor Yellow
        return $null
    }
    Write-Host ""
    Write-Host $title
    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $items[$i].Name)
    }
    $sel = Read-Host "  number (blank = cancel)"
    if (-not $sel) { return $null }
    $n = 0
    if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $items.Count) {
        Write-Host "  not a valid number." -ForegroundColor Red
        return $null
    }
    return $items[$n - 1].FullName
}

function Confirm([string]$what) {
    Write-Host ""
    Write-Host ("  ABOUT TO: {0}" -f $what) -ForegroundColor Red
    Write-Host "  This MODIFIES firmware NVRAM.  Read DISCLAIMER.md first." -ForegroundColor Red
    $a = Read-Host "  type YES to continue"
    return ($a -ceq 'YES')
}

# run a script; relaunch elevated in a window that stays open (-NoExit)
# so the result is readable before closing.
#
# Quoting matters here: inside -Command, a QUOTED '-Patch' is a string
# literal and would bind POSITIONALLY (to the first param), not as the
# parameter name -- that is how "patch file not found: -OutDir" happened.
# So switch-like tokens stay bare; only values get quoted.
function Elevated([string]$file, [string[]]$scriptArgs) {
    if (IsAdmin) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file @scriptArgs
        Write-Host ""
        Write-Host "  (exit code: $LASTEXITCODE)" -ForegroundColor Gray
        return
    }
    Write-Host "  (relaunching elevated -- accept the UAC prompt)"
    $cmd = "& '" + ($file -replace "'", "''") + "'"
    foreach ($x in $scriptArgs) {
        if ($x -match '^-[A-Za-z][A-Za-z0-9]*$') { $cmd += ' ' + $x }
        else { $cmd += " '" + ($x -replace "'", "''") + "'" }
    }
    $cmd += "; Write-Host ' (done -- this window can be closed)' -ForegroundColor Gray"
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', $cmd) `
        -Verb RunAs -Wait | Out-Null
}

# The probe is read-only, but half its report (BitLocker state, SecureBoot NVRAM,
# TCG2 physical presence, Win32_Tpm) needs an elevated token -- non-elevated runs
# show UNKNOWN / access-denied for exactly the lines that matter.  So it goes
# through the same Elevated() channel as the writers.
function Probe([string]$patchFile) {
    $ps1 = Join-Path $here 'check_status.ps1'
    # -Dump: after the report, refresh h2ouve\vars_live.txt in the SAME
    # elevated window (one UAC prompt).  Option 2 then always has fresh
    # now= values and never needs its own dump prompt.
    $a = @('-OutDir', $here, '-Dump')
    if ($patchFile) { $a += @('-Patch', $patchFile) }
    Elevated $ps1 $a
    Write-Host ""
    Write-Host ("  log written to the newest stat_*.txt in {0}" -f $here) -ForegroundColor Green
    Write-Host ("  live NVRAM dump refreshed: h2ouve\vars_live.txt (used by option 2)") -ForegroundColor Green
}

function Locate {
    $img = (Read-Host "  firmware image OR upgrade package (.zip/.exe/.fd/.ffs, drag && drop works)").Trim('"').Trim()
    if (-not $img -or -not (Test-Path -LiteralPath $img)) {
        Write-Host "  file not found." -ForegroundColor Red; return
    }
    $pyr = Resolve-Python
    $py = if ($pyr) { $pyr[0] } else { $null }
    $pyArgs = if ($pyr) { @($pyr[1]) } else { @() }
    if (-not $py) {
        Write-Host "  python 3 not found.  The repo ships one at tools\runtime\python --" -ForegroundColor Red
        Write-Host "  re-extract the full repo, or install Python 3 from python.org." -ForegroundColor Red
        return
    }
    $tool = Join-Path $here 'tools\ifr_locate.py'

    # an upgrade package is unwrapped to the Setup FFS first; an .ffs is used as-is
    $ext = [IO.Path]::GetExtension($img).ToLower()
    if ($ext -in @('.zip', '.exe', '.fd', '.bin', '.rom', '.cap')) {
        Write-Host ""
        Write-Host "  unwrapping package -> Setup FFS ..." -ForegroundColor Cyan
        $o = & $py @pyArgs $tool extract $img 2>&1
        $o | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        $hit = @($o | Select-String '^EXTRACTED: (.+)$' | Select-Object -Last 1)
        if (-not $hit) {
            Write-Host "  could not get a Setup FFS from that package." -ForegroundColor Red
            return
        }
        $img = $hit.Matches[0].Groups[1].Value.Trim()
    }

    # live values need an H2OUVE -gv dump.  Reuse the newest one if present;
    # otherwise offer to read one now (elevated, read-only).
    $dump = $null
    foreach ($n in @('vars_live.txt', 'vars_after.txt', 'vars_before.txt', 'vars_orig.txt')) {
        $p = Join-Path $here ('h2ouve\{0}' -f $n)
        if ((Test-Path -LiteralPath $p) -and (Get-Item $p).Length -gt 0) {
            if ($null -eq $dump -or (Get-Item $p).LastWriteTime -gt (Get-Item $dump).LastWriteTime) { $dump = $p }
        }
    }
    if (-not $dump -and (Test-Path -LiteralPath (Join-Path $here 'h2ouve\H2OUVE-W-CONSOLEx64.exe'))) {
        $ans = (Read-Host "  no NVRAM dump yet -- read live values now? (H2OUVE -gv, elevated, read-only) [Y/n]").Trim()
        if ($ans -notmatch '^(n|no)$') {
            Elevated (Join-Path $here 'tools\dump_vars.ps1') @()
            $p = Join-Path $here 'h2ouve\vars_live.txt'
            if ((Test-Path -LiteralPath $p) -and (Get-Item $p).Length -gt 0) { $dump = $p }
        }
    }
    $liveArgs = @()
    if ($dump) {
        Write-Host ("  live values from: {0}" -f $dump) -ForegroundColor Gray
        $liveArgs = @('--live', $dump)
    } else {
        Write-Host "  (no NVRAM dump -- listing shows IFR defaults only)" -ForegroundColor Gray
    }

    $kw = (Read-Host "  keyword(s) to search (blank = list EVERY setting, pick by number)").Trim()
    if (-not $kw) {
        # no keyword: dump every locatable setting (fTPM, Above 4G, Secure
        # Boot, ...) as a numbered list and let the user pick one.
        Write-Host ""
        Write-Host "  scanning IFR -- listing every locatable setting ..." -ForegroundColor Cyan
        # Out-String needs a wide -Width or long JSON lines get wrapped and
        # ConvertFrom-Json chokes on the broken text.
        $json = & $py @pyArgs $tool find $img --json --limit 5000 @liveArgs | Out-String -Width 1000000
        $all = $null
        try { $all = @(($json | ConvertFrom-Json).matches) } catch { }
        if (-not $all -or $all.Count -eq 0) {
            Write-Host "  nothing locatable in that image." -ForegroundColor Red; return
        }
        Write-Host ("  {0} locatable setting(s):" -f $all.Count)
        Write-Host ""
        for ($i = 0; $i -lt $all.Count; $i++) {
            $t = [string]$all[$i].prompt
            if ($t.Length -gt 48) { $t = $t.Substring(0, 48) + '...' }
            $f = [string]$all[$i].form
            if (-not $f) { $f = '?' }
            $extra = ''
            if ($all[$i].live) {
                $l = @($all[$i].live)[0]
                if ($l) {
                    $m = [string]$l.meaning
                    if (-not $m) { $m = '' } else { $m = ' ' + $m }
                    $extra = '   now={0}{1}' -f $l.value, $m
                }
            } elseif ($null -ne $all[$i].PSObject.Properties['live']) {
                $extra = '   now=<not in dump>'
            }
            if ($all[$i].default) {
                $dn = [string]$all[$i].default.name
                $extra += '   def={0} {1}' -f $all[$i].default.value, $dn
            }
            Write-Host ("  [{0}] {1}   ({2}){3}" -f ($i + 1), $t, $f, $extra)
        }
        Write-Host ""
        $sel = (Read-Host "  number (blank = cancel)").Trim()
        if (-not $sel) { return }
        $n = 0
        if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $all.Count) {
            Write-Host "  not a valid number." -ForegroundColor Red; return
        }
        $kw = [string]$all[$n - 1].prompt
        Write-Host ""
        Write-Host ("  -> {0}" -f $kw) -ForegroundColor Cyan
    }

    $slug = ($kw -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
    if (-not $slug) { $slug = 'setting' }
    if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60).Trim('-') }
    if (-not $slug) { $slug = 'setting' }
    $out = Join-Path $here ('patches\{0}.patch' -f $slug)

    Write-Host ""
    & $py @pyArgs $tool find $img (@($kw -split '\s+' | Where-Object { $_ })) @liveArgs --out $out
    Write-Host ""
    if (Test-Path -LiteralPath $out) {
        Write-Host ("  candidate patch written to: {0}" -f $out) -ForegroundColor Green
        Write-Host "  OPEN IT AND CHECK FROM/TO BY EYE before applying (option 4)." -ForegroundColor Yellow
    }
}

while ($true) {
    Clear-Host
    Write-Host "============================================================"
    Write-Host "  insyde-laptop-nvram-patch   --   menu"
    Write-Host "============================================================"
    Write-Host "  [1] Status probe, read-only          (safe any time)"
    Write-Host "  [2] Locate a setting in firmware     (read-only; makes a patch)"
    Write-Host "  [3] Status probe FOR a patch         (safe any time)"
    Write-Host "  [4] Apply a patch                    (MODIFIES NVRAM)"
    Write-Host "  [5] Restore original bytes (undo)    (MODIFIES NVRAM)"
    Write-Host "  [0] Exit"
    Write-Host ""
    $op = Read-Host "  choose"
    switch ($op) {
        '1' { Probe $null }
        '2' { Locate }
        '3' { $p = Pick "  which patch?"; if ($p) { Probe $p } }
        '4' {
            $p = Pick "  which patch?"; if (-not $p) { break }
            if (Confirm ("apply '{0}'" -f (Split-Path -Leaf $p))) {
                Elevated (Join-Path $here 'apply_patch.ps1') @('-Patch', $p, '-OutDir', $here)
                Write-Host ""
                Write-Host "  When it succeeded: FULL POWER OFF, then boot." -ForegroundColor Yellow
            } else { Write-Host "  cancelled." }
        }
        '5' {
            $p = Pick "  which patch are you undoing?"; if (-not $p) { break }
            if (Confirm ("restore original records (undo '{0}')" -f (Split-Path -Leaf $p))) {
                Elevated (Join-Path $here 'restore_original.ps1') @('-Patch', $p, '-OutDir', $here)
                Write-Host ""
                Write-Host "  When it succeeded: FULL POWER OFF, then boot." -ForegroundColor Yellow
            } else { Write-Host "  cancelled." }
        }
        '0' { return }
        default { }
    }
    Write-Host ""
    Read-Host "  press Enter to return to the menu" | Out-Null
}
