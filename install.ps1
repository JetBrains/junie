#
# Junie CLI Installer for Windows
# Usage: irm https://junie.jetbrains.com/install.ps1 | iex
#
# To install a specific version:
#   $env:JUNIE_VERSION="656.1"; irm https://junie.jetbrains.com/install.ps1 | iex
#

$ErrorActionPreference = 'Stop'

$CHANNEL = "eap"
$UPDATE_INFO_URL = "https://raw.githubusercontent.com/jetbrains-junie/junie/main/update-info.jsonl"
$GITHUB_RELEASES = "https://github.com/JetBrains/junie/releases"
$INSTALL_DIR = Join-Path $HOME ".local\bin"

function Log($msg) { Write-Host "[Junie] $msg" }
function Log-Error($msg) { Write-Host "[Junie] ERROR: $msg" -ForegroundColor Red }

function Get-Sha256($file) {
  (Get-FileHash -Path $file -Algorithm SHA256).Hash.ToLower()
}

# Detect architecture
$ARCH = $env:PROCESSOR_ARCHITECTURE
switch ($ARCH) {
  "AMD64"   {$ARCH_NAME = "amd64" }
  "ARM64"   {$ARCH_NAME = "amd64" }
  default   { Log-Error "Unsupported architecture: $ARCH"; exit 1 }
}

$PLATFORM = "windows-$ARCH_NAME"

function Fetch-LatestVersion {
  Log "Fetching latest version info..."
  $jsonl = Invoke-RestMethod -Uri $UPDATE_INFO_URL

  $lines = $jsonl -split "`n" | Where-Object { $_ -match "`"platform`":`"$PLATFORM`"" }
  if (-not $lines) {
    Log-Error "No release found for platform: $PLATFORM"
    exit 1
  }

  $entry = $lines | Select-Object -Last 1
  $parsed = $entry | ConvertFrom-Json

  $script:VERSION = $parsed.version
  $script:DOWNLOAD_URL = $parsed.downloadUrl
  $script:SHA256 = $parsed.sha256

  if (-not $script:VERSION -or -not $script:DOWNLOAD_URL) {
    Log-Error "Failed to parse version info"
    exit 1
  }
}

# Determine version: use JUNIE_VERSION env var if set, otherwise fetch latest
if ($env:JUNIE_VERSION) {
  $VERSION = $env:JUNIE_VERSION
  $DOWNLOAD_URL = "$GITHUB_RELEASES/download/$VERSION/junie-$CHANNEL-$VERSION-$PLATFORM.zip"
  $SHA256 = ""
  Log "Using specified version: $VERSION"
} else {
  Fetch-LatestVersion
}

Log "Installing Junie $VERSION for $PLATFORM..."

# Create install directory
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null

# Download archive
$TMP_ZIP = Join-Path $env:TEMP "junie-$VERSION.zip"

Log "Downloading $DOWNLOAD_URL"
$oldProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $DOWNLOAD_URL -OutFile $TMP_ZIP -UseBasicParsing
$ProgressPreference = $oldProgress

# Verify checksum
if ($SHA256) {
  $actualSha256 = Get-Sha256 $TMP_ZIP
  if ($actualSha256 -ne $SHA256.ToLower()) {
    Log-Error "Checksum verification failed!"
    Log-Error "Expected: $SHA256"
    Log-Error "Got: $actualSha256"
    Remove-Item -Force $TMP_ZIP
    exit 1
  }
  Log "Checksum verified"
}

# Extract to ~/.local/bin
$oldProgress = $global:ProgressPreference
$global:ProgressPreference = 'SilentlyContinue'
Expand-Archive -Path $TMP_ZIP -DestinationPath $INSTALL_DIR -Force
$global:ProgressPreference = $oldProgress

Log "Installed successfully!"

# Add to User PATH permanently (persists across reboots)
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$INSTALL_DIR*") {
  $NewPath = if ($UserPath) { "$UserPath;$INSTALL_DIR" } else { $INSTALL_DIR }
  [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
  Log "Added $INSTALL_DIR to User PATH."
}

Write-Host ""
Write-Host "Please restart your shell to apply the changes to the PATH variable."
Write-Host "After that, you can run: junie --help"
