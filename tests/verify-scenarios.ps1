#
# JUNIE-3346 scenario matrix.
#
# Sweeps several user-profile folder shapes and, for each, builds a real 8.3
# short %TEMP% path (C:\Users\<name>\AppData\Local\Temp), drops a junie-*.zip
# there, and tries to delete it three ways:
#   OLD   : Remove-Item -Force <path> -ErrorAction SilentlyContinue   (pre-fix)
#   PR77  : Remove-Item -Force -LiteralPath <path> -ErrorAction ...    (PR #77)
#   FIX   : [System.IO.File]::Delete(<path>)                           (shipped Remove-TempFile)
#
# For each method we record OK (file deleted, no throw) or THREW (terminating
# error). This isolates the exact failing call from JUNIE-3346 and proves which
# strategy survives every scenario. No network required -> deterministic.

$ErrorActionPreference = 'Continue'
Write-Host "PowerShell = $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
$build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
Write-Host "OS build   = $build"
& fsutil 8dot3name set C: 0 | Out-Null
Write-Host ""

# name | description
$cases = @(
  @{ name = 'a.lastname';        desc = 'dotted, short>long (ticket case)' }
  @{ name = 's.ivanov';          desc = 'dotted, short>long' }
  @{ name = 'john';              desc = 'plain short, no dot' }
  @{ name = 'Administrator';     desc = 'plain 13 chars, short<long' }
  @{ name = 'john.doe.smith';    desc = 'dotted 14 chars, short<long' }
  @{ name = 'program.files.dir'; desc = 'dotted, long>12, short<long' }
)

function Try-Delete($label, $file, [scriptblock]$remover) {
  'x' | Set-Content -LiteralPath $file
  $existedBefore = Test-Path -LiteralPath $file
  try {
    & $remover $file
    $existsAfter = Test-Path -LiteralPath $file
    if ($existsAfter) { return "STAYED" }   # returned but did not delete
    return "OK"
  } catch {
    return "THREW:$($_.Exception.GetType().Name)"
  }
}

$rows = @()
foreach ($c in $cases) {
  $userDir = Join-Path 'C:\Users' $c.name
  New-Item -ItemType Directory -Force -Path $userDir | Out-Null
  $shortUser = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($userDir).ShortPath
  $leafLong  = Split-Path $userDir -Leaf
  $leafShort = Split-Path $shortUser -Leaf
  $tempDir   = Join-Path $shortUser 'AppData\Local\Temp'
  New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
  $zip = Join-Path $tempDir 'junie-1966.57.zip'

  $isShorter = $leafShort.Length -le $leafLong.Length
  $oldR  = Try-Delete 'OLD'  $zip { param($p) Remove-Item -Force $p -ErrorAction SilentlyContinue }
  $pr77R = Try-Delete 'PR77' $zip { param($p) Remove-Item -Force -LiteralPath $p -ErrorAction SilentlyContinue }
  $fixR  = Try-Delete 'FIX'  $zip { param($p) [System.IO.File]::Delete($p) }

  $rows += [pscustomobject]@{
    LongName  = $leafLong
    LenLong   = $leafLong.Length
    ShortName = $leafShort
    LenShort  = $leafShort.Length
    'Short>Long' = if ($leafShort.Length -gt $leafLong.Length) { 'YES' } else { 'no' }
    OLD       = $oldR
    PR77      = $pr77R
    FIX       = $fixR
  }
}

Write-Host "=== JUNIE-3346 deletion-strategy matrix ==="
$rows | Format-Table -AutoSize | Out-String | Write-Host

$fixAllOk = ($rows | Where-Object { $_.FIX -ne 'OK' }).Count -eq 0
Write-Host ("FIX deletes the temp zip in every scenario: {0}" -f $fixAllOk)
if ($fixAllOk) { Write-Host "VERDICT: PASS" -ForegroundColor Green; exit 0 }
else           { Write-Host "VERDICT: FAIL" -ForegroundColor Red;   exit 1 }
