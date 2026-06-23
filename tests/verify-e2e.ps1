param(
  [Parameter(Mandatory=$true)][string]$InstallerPath
)

# End-to-end JUNIE-3346 scenarios against the LOCAL (fixed) installer, run
# IN-PROCESS (spawning child pwsh is unstable in this Server Core image).
# install.ps1 only calls `exit` on error paths, so a successful run just falls
# through and returns control here. For each scenario we point $HOME at a fresh
# sandbox and %TEMP% at the shape under test, run the installer, and check it
# reached "Installed successfully!" with junie.exe on disk and no terminating error.
#
# NOTE: this image's Expand-Archive *cmdlet* crashes (an environmental Archive-
# module quirk; works on real machines, and the .NET ZipFile API works here),
# so we shim Expand-Archive over the .NET API ONLY to reach the code under test:
# the temp-zip cleanup on the 8.3 short %TEMP% path, which is the actual bug.

Write-Host "PowerShell = $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
& fsutil 8dot3name set C: 0 | Out-Null
$installerText = Get-Content -Raw -LiteralPath $InstallerPath

function Expand-Archive {
  param([string]$Path, [string]$LiteralPath, [string]$DestinationPath, [switch]$Force)
  $src = if ($LiteralPath) { $LiteralPath } else { $Path }
  [System.IO.Compression.ZipFile]::ExtractToDirectory($src, $DestinationPath, $true)
}

function New-ShortTemp($userName) {
  $userDir = Join-Path 'C:\Users' $userName
  New-Item -ItemType Directory -Force -Path $userDir | Out-Null
  $shortUser = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($userDir).ShortPath
  $temp = Join-Path $shortUser 'AppData\Local\Temp'
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  return $temp
}

function Run-Scenario($label, $tempDir) {
  Write-Host ""
  Write-Host "########## SCENARIO: $label ##########"
  Write-Host "TEMP = $tempDir"
  $sbHome = Join-Path 'C:\sandboxes' ([guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $sbHome | Out-Null

  $prevHome = $HOME
  $threw = $null
  Set-Variable HOME $sbHome -Scope Global -Force
  $env:HOME = $sbHome
  $env:TEMP = $tempDir
  $env:TMP  = $tempDir
  try {
    Invoke-Expression $installerText
  } catch {
    $threw = $_
  } finally {
    Set-Variable HOME $prevHome -Scope Global -Force
  }

  if ($threw) {
    Write-Host ("  THREW: {0}: {1}" -f $threw.Exception.GetType().Name, $threw.Exception.Message) -ForegroundColor Yellow
    Write-Host ("  AT   : {0}" -f ($threw.InvocationInfo.PositionMessage -replace "`n"," ")) -ForegroundColor Yellow
  }
  $verDir = Join-Path $sbHome '.local\share\junie\versions'
  $exePresent = (Test-Path $verDir) -and [bool](Get-ChildItem -Recurse -Filter junie.exe $verDir -ErrorAction SilentlyContinue)
  # The temp zip must be gone (cleanup succeeded) and no terminating error.
  $leftover = Get-ChildItem -LiteralPath $tempDir -Filter 'junie-*.zip' -ErrorAction SilentlyContinue
  Write-Host ("  threw={0}  junie.exe present={1}  leftover temp zip={2}" -f [bool]$threw, [bool]$exePresent, [bool]$leftover)
  if (-not $threw -and $exePresent -and -not $leftover) {
    Write-Host "  -> PASS" -ForegroundColor Green; return $true
  } else {
    Write-Host "  -> FAIL" -ForegroundColor Red; return $false
  }
}

$results = [ordered]@{}
$results['normal-user (no short path)'] = Run-Scenario 'normal-user' $env:TEMP
$results['dotted a.lastname (trigger)'] = Run-Scenario 'dotted-a.lastname' (New-ShortTemp 'a.lastname')
$results['dotted s.ivanov (trigger)']  = Run-Scenario 'dotted-s.ivanov'  (New-ShortTemp 's.ivanov')

Write-Host ""
Write-Host "=== END-TO-END SCENARIO SUMMARY ==="
foreach ($k in $results.Keys) { Write-Host ("{0,-32} : {1}" -f $k, ($(if ($results[$k]) {'PASS'} else {'FAIL'}))) }
$allPass = ($results.Values | Where-Object { -not $_ }).Count -eq 0
if ($allPass) { Write-Host "VERDICT: PASS" -ForegroundColor Green; exit 0 }
else          { Write-Host "VERDICT: FAIL" -ForegroundColor Red;   exit 1 }
