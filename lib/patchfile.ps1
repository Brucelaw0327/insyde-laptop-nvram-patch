# patchfile.ps1 -- shared reader for "patch files" and machine.txt.
#
# Dot-source this file.  It defines:
#
#   Read-KvFile                <path>  -> @{ KEY = value }  (repeats become arrays)
#   Read-PatchFile             <path>  -> patch object (see below)
#   Read-MachineFile           <dir>   -> identity keys from machine.txt
#   New-MachineFileFromLive    <dir>   -> seed machine.txt from THIS machine
#   Get-PatchSlug              <patch> -> filesystem-safe name (for undo files)
#
# A patch object:
#   @{ Ok; Err; Name; Varstore; Guid; Records=@(); Changes=@(@{Off;From;To});
#      Path; Slug; Legacy }
#
# ---------------------------------------------------------------------------
# WHY THIS IS A SHARED FILE
#
# machine.txt's offset key used to be read by two scripts and silently ignored
# by a third, so the read-only probe kept explaining 0x100 while the writers
# used something else.  One parser, one behaviour, one place to fix.
#
# ---------------------------------------------------------------------------
# PATCH FILE FORMAT (see ../patches/*.patch)
#
#   NAME     = fTPM -> Disable        # free text, used in log lines
#   VARSTORE = SystemConfig           # the H2OUVE variable store name
#   GUID     = A04A27F4-DF00-4D42-B552-39511302113D
#   RECORDS  = Setup,Custom           # which records of that store to patch
#
#   OFFSET   = 0x100                  # one change expressed as three keys ...
#   FROM     = 0x02
#   TO       = 0x00
#
#   # ... or, for several bytes in one patch, use one CHANGE line per change:
#   CHANGE   = 0x100 0x02 0x00
#   CHANGE   = 0x2A0 0x01 0x00
#
# '#' starts a comment (whole-line, or after whitespace).  Keys are
# case-insensitive.  OFFSET/FROM/TO and CHANGE are mutually exclusive -- mixing
# them is an error rather than a guess.
#
# Keep this file PURE ASCII: PowerShell 5.1 decodes a BOM-less file with the
# console code page, and non-ASCII comments can derail the parser.

$ErrorActionPreference = 'Continue'

function Read-KvFile([string]$path) {
    $kv = @{}
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $kv }
    foreach ($ln in @(Get-Content -LiteralPath $path)) {
        $t = ("$ln").Trim()
        if (-not $t) { continue }
        if ($t.StartsWith('#') -or $t.StartsWith(';')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 0) { continue }
        $k = $t.Substring(0, $eq).Trim().ToUpper()
        $v = $t.Substring($eq + 1).Trim()
        # inline comment: only when '#' is preceded by whitespace, so a value
        # that legitimately contains '#' is left alone
        $v = ($v -replace '\s+#.*$', '').Trim()
        if (-not $k) { continue }
        if ($kv.ContainsKey($k)) { $kv[$k] = @($kv[$k]) + @($v) } else { $kv[$k] = $v }
    }
    return $kv
}

function ConvertFrom-HexOrNeg([string]$s) {
    if ($null -eq $s) { return -1 }
    $t = ("$s").Trim() -replace '^0[xX]', ''
    if ($t -notmatch '^[0-9A-Fa-f]+$') { return -1 }
    try { return [Convert]::ToInt32($t, 16) } catch { return -1 }
}

function Get-PatchSlug($patch) {
    if ($patch -and $patch.Slug) { return $patch.Slug }
    $n = ''
    if ($patch -and $patch.Path) { $n = [IO.Path]::GetFileNameWithoutExtension([string]$patch.Path) }
    elseif ($patch -and $patch.Name) { $n = [string]$patch.Name }
    $n = ($n -replace '[^A-Za-z0-9_.-]+', '_').Trim('_')
    if (-not $n) { $n = 'default' }
    return $n.ToLower()
}

function Read-PatchFile([string]$path) {
    $r = @{ Ok = $false; Err = ''; Name = ''; Varstore = ''; Guid = ''
            Records = @(); Changes = @(); Path = ''; Slug = ''; Legacy = $false }
    if (-not $path) { $r.Err = 'no patch file given'; return $r }
    if (-not (Test-Path -LiteralPath $path)) {
        $r.Err = ('patch file not found: {0}' -f $path); return $r
    }
    $kv = Read-KvFile $path

    $r.Name    = if ($kv['NAME'])     { [string]$kv['NAME'] } else { [IO.Path]::GetFileNameWithoutExtension($path) }
    $r.Varstore = if ($kv['VARSTORE']) { [string]$kv['VARSTORE'] } else { '' }
    $r.Path    = (Resolve-Path -LiteralPath $path).Path
    $r.Slug    = Get-PatchSlug @{ Path = $r.Path; Name = $r.Name }

    if (-not $kv['GUID']) { $r.Err = 'GUID is required (the variable store GUID)'; return $r }
    $g = ([string]$kv['GUID']).Trim().Trim('{', '}')
    if ($g -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') {
        $r.Err = ('GUID is not in xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx form: {0}' -f $g); return $r
    }
    $r.Guid = $g.ToUpper()

    if ($kv['RECORDS']) {
        $r.Records = @(([string]$kv['RECORDS']) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } elseif ($kv['RECORD']) {
        $r.Records = @(([string]$kv['RECORD']).Trim())
    }
    if (@($r.Records).Count -eq 0) {
        $r.Err = 'RECORDS is required (comma-separated record names, e.g. "Setup,Custom")'
        return $r
    }

    $chg = New-Object System.Collections.Generic.List[hashtable]
    if ($kv.ContainsKey('CHANGE')) {
        if ($kv.ContainsKey('OFFSET') -or $kv.ContainsKey('FROM') -or $kv.ContainsKey('TO')) {
            $r.Err = 'use either OFFSET/FROM/TO or CHANGE lines, not both'; return $r
        }
        foreach ($c in @($kv['CHANGE'])) {
            $tk = @(([string]$c) -split '\s+' | Where-Object { $_ })
            if ($tk.Count -ne 3) { $r.Err = ('CHANGE needs "OFFSET FROM TO", got: {0}' -f $c); return $r }
            $o = ConvertFrom-HexOrNeg $tk[0]
            $f = ConvertFrom-HexOrNeg $tk[1]
            $n = ConvertFrom-HexOrNeg $tk[2]
            if ($o -lt 0 -or $f -lt 0 -or $n -lt 0) { $r.Err = ('non-hex value in CHANGE: {0}' -f $c); return $r }
            $chg.Add(@{ Off = $o; From = $f; To = $n })
        }
    } else {
        $o = ConvertFrom-HexOrNeg ([string]$kv['OFFSET'])
        $f = ConvertFrom-HexOrNeg ([string]$kv['FROM'])
        $n = ConvertFrom-HexOrNeg ([string]$kv['TO'])
        if ($o -lt 0 -or $f -lt 0 -or $n -lt 0) {
            $r.Err = 'OFFSET, FROM and TO are all required (hex), or use CHANGE lines'; return $r
        }
        $chg.Add(@{ Off = $o; From = $f; To = $n })
    }

    $seen = @{}
    foreach ($c in $chg) {
        if ($seen.ContainsKey($c.Off)) {
            $r.Err = ('offset 0x{0:X} appears in more than one change' -f $c.Off); return $r
        }
        $seen[$c.Off] = $true
        if ($c.From -eq $c.To) {
            $r.Err = ('offset 0x{0:X}: FROM and TO are both 0x{1:X2} -- nothing to change' -f $c.Off, $c.From)
            return $r
        }
    }
    $r.Changes = @($chg)
    $r.Ok = $true
    return $r
}

# machine.txt holds ONLY the identity (BIOS/BOARD/MODEL).  It used to also
# carry offset keys (TARGET_* / FTPM_*); that legacy path is gone -- a byte
# change is described by a patch file now, never by machine.txt.
function Read-MachineFile([string]$dir) {
    $e = @{ BIOS = $null; BOARD = $null; MODEL = $null }
    $f = Join-Path $dir 'machine.txt'
    if (-not (Test-Path -LiteralPath $f)) { return $e }
    foreach ($ln in @(Get-Content -LiteralPath $f)) {
        $t = ("$ln").Trim()
        if (-not $t -or $t.StartsWith('#') -or ($t -notmatch '=')) { continue }
        $k = ($t -split '=', 2)[0].Trim().ToUpper()
        $v = ($t -split '=', 2)[1].Trim()
        $v = ($v -replace '\s+#.*$', '').Trim()
        if ($e.ContainsKey($k)) {
            if ($v -match '^<.*>$') { $v = $null }   # template placeholder, not a real value
            $e[$k] = $v
        }
    }
    return $e
}

# Seed machine.txt from the LIVE machine's identity (registry, no admin needed).
# Deliberately for the read-only probe only: a writer script must never invent
# its own config.  Policy: seed ONLY when the file does not exist at all -- a
# partial machine.txt is a person's decision in progress, not ours to fill in.
function New-MachineFileFromLive([string]$dir) {
    $r = @{ Ok = $false; Written = $false; Path = ''; Err = ''
            BIOS = $null; BOARD = $null; MODEL = $null }
    $path = Join-Path $dir 'machine.txt'
    $r.Path = $path
    if (Test-Path -LiteralPath $path) { $r.Err = 'machine.txt already exists'; return $r }

    function GetLive([string]$name) {
        try {
            $v = (Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' `
                    -Name $name -ErrorAction Stop).$name
            if ($v -is [array]) { $v = $v[0] }
            return ("$v").Trim()
        } catch { return $null }
    }
    $r.BIOS  = GetLive 'BIOSVersion'
    $r.BOARD = GetLive 'BaseBoardProduct'
    $r.MODEL = GetLive 'SystemProductName'
    foreach ($k in @('BIOS', 'BOARD', 'MODEL')) {
        if (-not $r[$k]) {
            $r.Err = ('could not read {0} from HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -f $k)
            return $r
        }
    }
    $lines = @(
        '# identity of the machine the record files were built on.  Seeded'
        '# automatically by run.cmd option 1 (check_status.ps1) -- edit only if this is'
        '# not the machine you are running on.'
        ('BIOS={0}'  -f $r.BIOS)
        ('BOARD={0}' -f $r.BOARD)
        ('MODEL={0}' -f $r.MODEL)
    )
    [System.IO.File]::WriteAllLines($path, $lines)
    $r.Ok = $true; $r.Written = $true
    return $r
}

# ---------------------------------------------------------------------------
# Resolve-Python: find a WORKING Python 3 for the analysis scripts.
#
# Order:
#   1. repo-local tools\runtime\python\python.exe (embeddable, ships with the
#      repo -- no install needed, works offline)
#   2. python / python3 / py -3 on PATH -- but every candidate must actually
#      run and self-report "Python 3.x".  The Microsoft Store "python.exe"
#      app-execution alias sits on PATH on every clean Windows install, does
#      not run Python, and only prints "Python was not found ..." -- it must
#      be skipped, which a bare Get-Command check cannot do.
#
# Returns @($exe, $extraArgs) with $extraArgs = @('-3') for the py launcher,
# or $null when nothing works.
function Resolve-Python {
    $local = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\runtime\python\python.exe'
    if (Test-Path -LiteralPath $local) {
        return ,@($local, @())
    }
    foreach ($c in @('python', 'python3')) {
        $p = Get-Command $c -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        try { $v = & $p.Source --version 2>&1 } catch { continue }
        if ("$v" -match '^Python 3\.') { return ,@($p.Source, @()) }
    }
    $p = Get-Command 'py' -ErrorAction SilentlyContinue
    if ($p) {
        try { $v = & $p.Source -3 --version 2>&1 } catch { }
        if ("$v" -match '^Python 3\.') { return ,@($p.Source, @('-3')) }
    }
    foreach ($root in @("$env:LOCALAPPDATA\Programs\Python",
                        'C:/Program Files\Python313',
                        'C:/Program Files\Python312',
                        'C:/Python313', 'C:/Python312')) {
        if (-not (Test-Path $root)) { continue }
        foreach ($h in @(Get-ChildItem -Path $root -Filter python.exe `
                        -Recurse -Depth 1 -ErrorAction SilentlyContinue)) {
            try { $v = & $h.FullName --version 2>&1 } catch { continue }
            if ("$v" -match '^Python 3\.') { return ,@($h.FullName, @()) }
        }
    }
    return $null
}
