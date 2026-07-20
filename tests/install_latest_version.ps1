#
# Regression test: installers must select the greatest numeric version for the
# current platform, regardless of JSONL entry order.
#
# Usage:
#   pwsh -NoProfile -File tests/install_latest_version.ps1

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$installers = @(
  'install.ps1',
  'install-eap.ps1',
  'install-nightly.ps1',
  'install-experimental.ps1'
)

$script:jsonl = @'
{"version":"2383.9","platform":"windows-amd64","downloadUrl":"https://example.test/2383.9.zip","sha256":"sha-2383.9"}
{"version":"9999.1","platform":"linux-amd64","downloadUrl":"https://example.test/wrong-platform.zip","sha256":"wrong-platform"}
{"version":"2383.10","platform":"windows-amd64","downloadUrl":"https://example.test/2383.10.zip","sha256":"sha-2383.10"}
{"version":"2383.2","platform":"windows-amd64","downloadUrl":"https://example.test/2383.2.zip","sha256":"sha-2383.2"}
'@

function Invoke-RestMethod {
  return $script:jsonl
}

function Log {}
function Log-Error($message) { throw $message }

$passed = 0
$failed = 0

foreach ($name in $installers) {
  $installer = Join-Path $repoRoot $name
  $source = Get-Content -Raw -LiteralPath $installer
  $functionMatch = [regex]::Match(
    $source,
    '(?ms)^function Fetch-LatestVersion \{.*?^\}'
  )
  if (-not $functionMatch.Success) {
    Write-Error "FAIL [$name]: Fetch-LatestVersion function not found"
    $failed++
    continue
  }

  Invoke-Expression $functionMatch.Value
  $script:PLATFORM = 'windows-amd64'
  $script:UPDATE_INFO_URL = 'https://example.test/update-info.jsonl'
  $script:VERSION = $null
  $script:DOWNLOAD_URL = $null
  $script:SHA256 = $null

  Fetch-LatestVersion
  if ($script:VERSION -eq '2383.10' -and
      $script:DOWNLOAD_URL -eq 'https://example.test/2383.10.zip' -and
      $script:SHA256 -eq 'sha-2383.10') {
    Write-Host "PASS [$name]"
    $passed++
  } else {
    Write-Error "FAIL [$name]: expected numeric latest 2383.10, got $($script:VERSION)"
    $failed++
  }
}

Write-Host '----'
Write-Host "PASS: $passed  FAIL: $failed"
if ($failed -ne 0) { exit 1 }