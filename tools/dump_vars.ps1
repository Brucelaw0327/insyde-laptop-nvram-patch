# dump_vars.ps1 -- one H2OUVE -gv pass: NVRAM -> h2ouve\vars_live.txt
# Run elevated (run.ps1 Locate does this through its Elevated() channel).
# Read-only: -gv only dumps, it never writes.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath          # tools\
$root = Split-Path -Parent $here                   # repo root
$h = Join-Path $root 'h2ouve'
$exe = Join-Path $h 'H2OUVE-W-CONSOLEx64.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host "  H2OUVE not found: $exe" -ForegroundColor Red
    Write-Host "  see h2ouve\README.md for where to get it."
    exit 3
}
Set-Location -LiteralPath $h
$out = Join-Path $h 'vars_live.txt'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
& $exe -gv vars_live.txt
$rc = $LASTEXITCODE
if ($rc -eq 0 -and (Test-Path -LiteralPath $out) -and (Get-Item $out).Length -gt 0) {
    Write-Host ("  NVRAM dumped -> {0}  ({1} bytes)" -f $out, (Get-Item $out).Length) -ForegroundColor Green
} else {
    Write-Host "  H2OUVE -gv failed (exit code $rc) -- no dump written." -ForegroundColor Red
    exit $rc
}
