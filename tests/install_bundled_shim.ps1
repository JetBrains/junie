#
# Regression test: Windows installers must install the package's own
# versions\<v>\shim\junie.bat byte-for-byte, and fall back to the embedded
# (CRLF-normalized) shim only for packages without a bundled one.
#
# Usage:
#   pwsh -NoProfile -File tests/install_bundled_shim.ps1
#   powershell -NoProfile -File tests/install_bundled_shim.ps1

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$installers = @(
  'install.ps1',
  'install-eap.ps1',
  'install-nightly.ps1',
  'install-experimental.ps1'
)

$passed = 0
$failed = 0

function Fail($name, $message) {
  Write-Host "FAIL [$name]: $message" -ForegroundColor Red
  $script:failed++
}

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("junie-bundled-shim-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

try {
  foreach ($name in $installers) {
    $source = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $name)
    $functionMatch = [regex]::Match($source, '(?ms)^function Install-Shim\(.*?^\}')
    if (-not $functionMatch.Success) {
      Fail $name "Install-Shim function not found"
      continue
    }
    Invoke-Expression $functionMatch.Value

    $caseDir = Join-Path $workRoot ([System.IO.Path]::GetFileNameWithoutExtension($name))
    $versionDir = Join-Path $caseDir "versions\1.1"
    $shimPath = Join-Path $caseDir "bin\junie.bat"
    New-Item -ItemType Directory -Force -Path (Join-Path $versionDir "shim") | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path $shimPath) | Out-Null
    [System.IO.File]::WriteAllText($shimPath, "stale shim`r`n")

    $bundled = [System.Text.Encoding]::ASCII.GetBytes("@echo off`r`n:: JUNIE_MANAGED_SHIM`r`n:: bundled $name`r`n")
    [System.IO.File]::WriteAllBytes((Join-Path $versionDir "shim\junie.bat"), $bundled)
    Install-Shim $versionDir $shimPath
    $installed = [System.IO.File]::ReadAllBytes($shimPath)
    if ([Convert]::ToBase64String($installed) -ne [Convert]::ToBase64String($bundled)) {
      Fail $name "bundled shim was not installed byte-for-byte"
      continue
    }

    [System.IO.File]::Delete((Join-Path $versionDir "shim\junie.bat"))
    Install-Shim $versionDir $shimPath
    $embedded = [System.IO.File]::ReadAllText($shimPath)
    if (-not $embedded.Contains('JUNIE_MANAGED_SHIM')) {
      Fail $name "fallback did not install the embedded managed shim"
      continue
    }
    if ($embedded -match "(?<!`r)`n") {
      Fail $name "fallback shim contains LF-only line endings"
      continue
    }

    Write-Host "PASS [$name]"
    $passed++
  }
} finally {
  Remove-Item -Recurse -Force -LiteralPath $workRoot -ErrorAction SilentlyContinue
}

Write-Host '----'
Write-Host "PASS: $passed  FAIL: $failed"
if ($failed -ne 0) { exit 1 }
