<#
.SYNOPSIS
  Junie Local Model Installer for Windows

.DESCRIPTION
  Downloads and installs the inference engine and model weights for Junie's
  local model capability on Windows.  Mirrors the behaviour of install.sh
  (macOS / Linux) but uses Windows-native tooling: PowerShell for flow
  control, curl.exe for resumable downloads, and 7-Zip / Expand-Archive for
  extraction.

  System checks are modelled after the JBInferenceRunner setup.ps1:
  - 64-bit Windows 10+ (build 19041+)
  - NVIDIA GPU with sufficient VRAM
  - NVIDIA driver 581+
  - Microsoft Visual C++ Redistributable

.PARAMETER Model
  Model identifier to install.  Default: Qwen3.6-27B-Q4_K_M

.PARAMETER Channel
  Update channel: main (default) or eap.

.PARAMETER CheckOnly
  Report system information and exit without installing anything.

.PARAMETER ListModels
  List all available models for this platform, then exit.

.PARAMETER Json
  Emit machine-readable JSON events on stdout; human output goes to stderr.

.EXAMPLE
  .\install.ps1

  .\install.ps1 --Model Qwen3.6-27B-Q4_K_M --Channel eap

  .\install.ps1 --CheckOnly
#>

# ============================================================
# CLI parameter parsing (PowerShell 5.1 doesn't support -- switches)
# ============================================================

$script:ArgModel = "Qwen3.6-27B-Q4_K_M"
$script:ArgChannel = "main"
$script:ArgCheckOnly = $false
$script:ArgListModels = $false
$script:ArgJson = $false
$script:ArgHelp = $false

# Skip PowerShell wrapper args (everything before the script file path)
$rawArgs = @($MyInvocation.UnboundArguments)
$scriptName = [System.IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
$skipCount = 0
for ($k = 0; $k -lt $rawArgs.Length; $k++) {
    if ($rawArgs[$k] -eq '-File' -and ($k + 1) -lt $rawArgs.Length -and [System.IO.Path]::GetFileName($rawArgs[$k + 1]) -eq $scriptName) {
        $skipCount = $k + 2
        break
    }
}
if ($skipCount -gt 0) {
    $rawArgs = @($rawArgs[$skipCount..($rawArgs.Length - 1)] | Where-Object { $_ -ne '' })
} else {
    $rawArgs = @($rawArgs | Where-Object { $_ -ne '' })
}

$p = 0
while ($p -lt $rawArgs.Length) {
    switch ($rawArgs[$p]) {
        { $_ -in '--model', '-Model', '-model' } {
            $p++
            if ($p -ge $rawArgs.Length) {
                Write-Host "ERROR: --model requires a value" -ForegroundColor Red
                $script:ArgHelp = $true
            } else {
                $script:ArgModel = $rawArgs[$p]
            }
        }
        { $_ -in '--channel', '-Channel', '-channel' } {
            $p++
            if ($p -ge $rawArgs.Length) {
                Write-Host "ERROR: --channel requires a value" -ForegroundColor Red
                $script:ArgHelp = $true
            } else {
                $script:ArgChannel = $rawArgs[$p]
            }
        }
        { $_ -in '--check-only', '-CheckOnly', '-check-only' } { $script:ArgCheckOnly = $true }
        { $_ -in '--models', '-ListModels', '-models' } { $script:ArgListModels = $true }
        { $_ -in '--json' } { $script:ArgJson = $true }
        { $_ -in '--help', '-h', '-help' } { $script:ArgHelp = $true }
        default {
            Write-Host "ERROR: Unknown argument: $($rawArgs[$p])" -ForegroundColor Red
            $script:ArgHelp = $true
        }
    }
    $p++
}

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ============================================================
# Configuration
# ============================================================

$Script:ProtocolVersion = 1

# Base installation directory
$Script:BaseDir = "$HOME\.local\share\junie-local"
$Script:JunieHome = if ($env:JUNIE_HOME) { $env:JUNIE_HOME } else { Join-Path $env:USERPROFILE ".junie" }
$Script:ModelsDir = Join-Path $Script:BaseDir "models"
$Script:VersionsDir = Join-Path $Script:BaseDir "versions"
$Script:DownloadDir = Join-Path $Script:BaseDir "incomplete_downloads"

# Engine port and RAM allowance (matches install.sh defaults)
$Script:EnginePort = 19239
$Script:EngineRamGb = 24

# Update files base URL - override via env var for testing
$Script:UpdateFilesBaseUrl =
    if ($env:JUNIE_LOCAL_UPDATE_FILES_BASE_URL) {
        $env:JUNIE_LOCAL_UPDATE_FILES_BASE_URL
    }
    else {
        "https://raw.githubusercontent.com/jetbrains-junie/junie/main/local"
    }

# Detect the native OS architecture, even when PowerShell runs under emulation.
function Get-NativeWindowsPlatform {
    $architecture = ""

    try {
        $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    catch {
        # Fall back to environment variables on older PowerShell, accounting for emulation.
        if ($env:PROCESSOR_ARCHITEW6432) {
            $architecture = $env:PROCESSOR_ARCHITEW6432
        }
        else {
            $architecture = $env:PROCESSOR_ARCHITECTURE
        }
    }

    if (-not $architecture) { $architecture = "unknown" }
    switch ($architecture.ToUpperInvariant()) {
        { $_ -in "ARM64", "AARCH64" } { return "windows-aarch64" }
        { $_ -in "X64", "AMD64", "X86_64" } { return "windows-amd64" }
        default { return "windows-$($architecture.ToLowerInvariant())" }
    }
}

$Script:Platform = Get-NativeWindowsPlatform
$Script:PlatformSupported = $Script:Platform -in @("windows-amd64", "windows-aarch64")

# ============================================================
# Helpers: machine-readable events (--json)
# ============================================================

function Emit-Event {
    param([string]$Payload)
    if (-not $Script:MachineOutput) { return }
    [System.Console]::WriteLine("{$Payload}")
}

function Emit-Check {
    param([string]$Name, [string]$Status, [string]$Value, [string]$Requirement)
    Emit-Event "`"event`":`"check`",`"name`":`"$Name`",`"status`":`"$Status`",`"value`":`"$(Json-Escape $Value)`",`"requirement`":`"$(Json-Escape $Requirement)`""
}

function Emit-StepStart {
    param([string]$Id, [string]$Title)
    Emit-Event "`"event`":`"step_start`",`"id`":`"$Id`",`"title`":`"$(Json-Escape $Title)`""
}

function Emit-StepDone {
    param([string]$Id)
    Emit-Event "`"event`":`"step_done`",`"id`":`"$Id`""
}

function Emit-Progress {
    param([string]$File, [long]$Bytes, [long]$Total, [string]$Label, [string]$Action = "downloading")
    Emit-Event "`"event`":`"progress`",`"action`":`"$Action`",`"file`":`"$(Json-Escape $File)`",`"bytes`":$([string]$Bytes),`"total`":$([string]$Total),`"label`":`"$(Json-Escape $Label)`""
}

function Emit-Activity {
    param([string]$Action, [string]$File, [string]$Label)
    Emit-Event "`"event`":`"activity`",`"action`":`"$Action`",`"file`":`"$(Json-Escape $File)`",`"label`":`"$(Json-Escape $Label)`""
}

function Emit-Warning {
    param([string]$Message)
    Emit-Event "`"event`":`"warning`",`"message`":`"$(Json-Escape $Message)`""
}

function Emit-Error {
    param([string]$Message)
    Emit-Event "`"event`":`"error`",`"message`":`"$(Json-Escape $Message)`""
}

function Wait-ForExitKey {
    if ($Script:MachineOutput -or [System.Console]::IsInputRedirected) { return }
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Json-Escape {
    param([string]$Text)
    return $Text.Replace('\', '\\').Replace('"', '\"')
}

function Check-Status {
    param([bool]$Ok, [bool]$Warn)
    if (-not $Ok) { return "fail" }
    if ($Warn) { return "warn" }
    return "ok"
}

function usage {
    Write-Host ""
    Write-Host "Usage: install.ps1 [options]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --model <name>     Model to install: Qwen3.6-27B-Q4_K_M (default)"
    Write-Host "  --channel <name>   Update channel: main (default) or eap"
    Write-Host "  --check-only       Report system information, then exit"
    Write-Host "  --models           List all available models for this architecture, then exit"
    Write-Host "  --json             Emit machine-readable events on stdout, human output on stderr"
    Write-Host "  --help, -h         Show this help"
}

# Apply parsed args to script variables
$Model = $script:ArgModel
$Channel = $script:ArgChannel
$CheckOnly = $script:ArgCheckOnly
$ListModels = $script:ArgListModels
$Script:MachineOutput = $script:ArgJson

# Handle help / errors
if ($script:ArgHelp) { usage; exit 1 }
if ($Channel -notin @("main", "eap")) {
    Write-Host "ERROR: Channel must be 'main' or 'eap', got '$Channel'" -ForegroundColor Red
    exit 1
}

# Hello event
Emit-Event "`"event`":`"hello`",`"protocol`":$Script:ProtocolVersion"

# ============================================================
# JSON parsing helpers (no external dependencies)
# ============================================================

function Get-JsonField {
    <#
    .SYNOPSIS
      Extract a string field from a compact JSON object on stdin.
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Json,
        [Parameter(Mandatory)]
        [string]$Field
    )
    process {
        $dq = [char]34
        $pattern = "(?i)${dq}$([regex]::Escape($Field))${dq}\s*:\s*${dq}([^${dq}]*)${dq}"
        $match = [regex]::Match($Json, $pattern)
        if ($match.Success) {
            return $match.Groups[1].Value
        }
        return ""
    }
}

# ============================================================
# Fetch model & engine configuration from remote JSONL
# ============================================================

# Reads a text resource. Unlike Invoke-WebRequest, WebClient always returns a
# string and also understands file:// URLs, which makes local overrides via
# JUNIE_LOCAL_UPDATE_FILES_BASE_URL work the same way they do on Unix.
function Get-UpdateFileText {
    param([Parameter(Mandatory)][string]$Url)
    $client = New-Object System.Net.WebClient
    try {
        $client.Encoding = [System.Text.Encoding]::UTF8
        return $client.DownloadString($Url)
    }
    finally { $client.Dispose() }
}

function Fetch-ModelsConfig {
    $modelsUpdateUrl = "$Script:UpdateFilesBaseUrl/update-info-models-$Script:Channel.jsonl"

    $jsonl = try {
        Get-UpdateFileText $modelsUpdateUrl
    }
    catch {
        Write-Host "ERROR: Could not fetch models config from $modelsUpdateUrl" -ForegroundColor Red
        Emit-Error "Could not fetch models config from $modelsUpdateUrl"
        exit 1
    }

    $lines = $jsonl -split "`r?`n" | Where-Object { $_.Trim() -ne "" }

    # Find the entry matching platform + model
    $dq = [char]34
    $platOnly = @($lines | Where-Object {
        $_ -match "${dq}platform${dq}:${dq}$([regex]::Escape($Script:Platform))${dq}"
    })
    $entry = $platOnly | Where-Object {
        $_ -match "${dq}id${dq}:${dq}$([regex]::Escape($Script:Model))${dq}"
    } | Select-Object -Last 1

    if (-not $entry) {
        $supported = $platOnly | ForEach-Object { $_ | Get-JsonField -Field "id" }
        Write-Host "ERROR: Unknown model: $Script:Model for platform $Script:Platform (supported: $supported)" -ForegroundColor Red
        exit 1
    }

    $Script:ModelFileId = $entry | Get-JsonField -Field "id"

    # Fetch the model JSON file
    $modelConfigUrl = "$Script:UpdateFilesBaseUrl/models/$Script:ModelFileId.json"
    $Script:ModelsJson = try {
        Get-UpdateFileText $modelConfigUrl
    }
    catch {
        Write-Host "ERROR: Could not fetch model config from $modelConfigUrl" -ForegroundColor Red
        exit 1
    }

    # Save model JSON locally (skip when only listing)
    if (-not $ListModels) {
        $modelConfigFile = Join-Path $Script:BaseDir "models\$Script:ModelFileId.json"
        Write-Host "  Saving model config to $modelConfigFile..."
        New-Item -ItemType Directory -Path (Split-Path $modelConfigFile -Parent) -Force | Out-Null
        $Script:ModelsJson | Set-Content -LiteralPath $modelConfigFile -Encoding UTF8 -NoNewline
    }

    # Junie model id
    $Script:JunieModelId = $Script:ModelsJson | Get-JsonField -Field "id"

    # Archive count
    $Script:ArchiveCount = ([regex]::Matches($Script:ModelsJson, '"modelId"')).Count
}

function Get-ArchiveField {
    param(
        [int]$ArchiveIndex,
        [string]$Field
    )
    # Extract all values of the field and pick the Nth
    $pattern = '(?i)"{0}"\s*:\s*"([^"]*)"' -f [regex]::Escape($Field)
    $matches = [regex]::Matches($Script:ModelsJson, $pattern)
    if ($ArchiveIndex -lt $matches.Count) {
        return $matches[$ArchiveIndex].Groups[1].Value
    }
    return ""
}

# Resolves the archive index for the model's "main" weights. Models that ship
# extra archives (e.g. a vision mmproj file, see main_model/vision_model in
# the model JSON) identify the main one explicitly; older models without that
# field fall back to archive 0, which has always been the main archive.
function Get-MainArchiveIndex {
    $mainModelId = $Script:ModelsJson | Get-JsonField -Field "main_model"
    if ($mainModelId) {
        for ($i = 0; $i -lt $Script:ArchiveCount; $i++) {
            if ((Get-ArchiveField -ArchiveIndex $i -Field "modelId") -eq $mainModelId) {
                return $i
            }
        }
    }
    return 0
}

function Fetch-EngineConfig {
    $engineUpdateUrl = "$Script:UpdateFilesBaseUrl/update-info-engine-$Script:Channel.jsonl"

    $jsonl = try {
        Get-UpdateFileText $engineUpdateUrl
    }
    catch {
        Write-Host "ERROR: Could not fetch engine config from $engineUpdateUrl" -ForegroundColor Red
        exit 1
    }

    $lines = $jsonl -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
    $dq = [char]34
    $entry = @($lines | Where-Object {
        $_ -match "${dq}platform${dq}:${dq}$([regex]::Escape($Script:Platform))${dq}"
    }) | Select-Object -Last 1

    if (-not $entry) {
        Write-Host "ERROR: No engine entry found for platform $Script:Platform in channel $Script:Channel" -ForegroundColor Red
        exit 1
    }

    $Script:EngineVersion = $entry | Get-JsonField -Field "version"
    $Script:EngineUrl = $entry | Get-JsonField -Field "downloadUrl"
    $Script:EngineSha256 = $entry | Get-JsonField -Field "sha256"
}

$Script:EngineLabel = "inference engine"
$Script:VersionsDir = Join-Path $Script:BaseDir "versions"
$Script:CurrentFile = Join-Path $Script:BaseDir "current"

# Filled in by Fetch-EngineConfig. Empty until the metadata is resolved, which
# only happens on the install path.
$Script:EngineVersion = ""

# Paths that cannot be known before the engine metadata is fetched.
function Resolve-EnginePaths {
    # Archive name is the last path segment of the download URL.
    $Script:EngineArchive = $Script:EngineUrl.Split("/")[-1]
    $Script:EngineDir = Join-Path $Script:VersionsDir $Script:EngineVersion
    $Script:EngineCtl = Join-Path $Script:EngineDir "serverctl.ps1"
}

# Everything the install needs from the network and the only pre-install write
# to disk. It is a function and not top-level code on purpose: --check-only
# exits before it is ever called, so a check stays offline and side-effect free.
function Resolve-InstallMetadata {
    Fetch-ModelsConfig
    Fetch-EngineConfig
    Resolve-EnginePaths
}

# ============================================================
# List models mode
# ============================================================

if ($ListModels -and $Script:PlatformSupported) {
    $modelsUpdateUrl = "$Script:UpdateFilesBaseUrl/update-info-models-$Script:Channel.jsonl"
    $jsonl = Get-UpdateFileText $modelsUpdateUrl
    $lines = $jsonl -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
    $dq = [char]34
    $platformLines = @($lines | Where-Object {
        $_ -match "${dq}platform${dq}:${dq}$([regex]::Escape($Script:Platform))${dq}"
    })

    if ($Script:MachineOutput) {
        $array = "["
        $first = $true
        foreach ($line in $platformLines) {
            $id = $line | Get-JsonField -Field "id"
            $name = $line | Get-JsonField -Field "displayName"
            if (-not $first) { $array += "," }
            $array += "{`"id`":`"$(Json-Escape $id)`",`"displayName`":`"$(Json-Escape $name)`"}"
            $first = $false
        }
        $array += "]"
        Emit-Event "`"event`":`"models`",`"platform`":`"$(Json-Escape $Script:Platform)`",`"channel`":`"$(Json-Escape $Script:Channel)`",`"models`":$array"
    }
    else {
        Write-Host "Available models for $Script:Platform ($Script:Channel channel):"
        foreach ($line in $platformLines) {
            $id = $line | Get-JsonField -Field "id"
            $name = $line | Get-JsonField -Field "displayName"
            Write-Host "$name ($id)"
        }
    }
    exit 0
}

# ============================================================
# System checks (modelled after setup.ps1 reference)
# ============================================================

function Test-WindowsRequirements {
    $osVersion = [Environment]::OSVersion.Version
    $Script:OsDisplay = "Windows $($osVersion.Major).$($osVersion.Minor) build $($osVersion.Build) ($($Script:Platform -replace '^windows-', ''))"
    $Script:OsRequirement = "x64 or ARM64 Windows 10 build 19041 or newer"
    $Script:OsOk = $Script:PlatformSupported -and $env:OS -eq "Windows_NT" -and [Environment]::Is64BitOperatingSystem -and (
        $osVersion.Major -gt 10 -or ($osVersion.Major -eq 10 -and $osVersion.Build -ge 19041)
    )
}

function Get-NvidiaGpu {
    $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        $Script:GpuOk = $false
        $Script:AccelDisplay = "nvidia-smi not found"
        $Script:AccelRequirement = "NVIDIA GPU with 24 GB VRAM and driver 581+"
        $Script:DriverOk = $false
        $Script:DriverDisplay = "Driver not detected"
        $Script:DriverRequirement = "Driver 581+"
        return $null
    }

    $output = & $nvidiaSmi.Source `
        --query-gpu=name,driver_version,memory.total,compute_cap `
        --format=csv,noheader,nounits

    if ($LASTEXITCODE -ne 0) {
        $Script:GpuOk = $false
        $Script:AccelDisplay = "nvidia-smi failed"
        $Script:AccelRequirement = "NVIDIA GPU with 24 GB VRAM and driver 581+"
        return $null
    }

    $columns = @([string]($output | Select-Object -First 1) -split ",\s*")
    if ($columns.Count -ne 4) {
        $Script:GpuOk = $false
        $Script:AccelDisplay = "GPU info parse error"
        $Script:AccelRequirement = "NVIDIA GPU with 24 GB VRAM and driver 581+"
        return $null
    }

    try {
        $gpu = [PSCustomObject]@{
            Name = $columns[0].Trim()
            DriverVersion = [version]$columns[1].Trim()
            MemoryMiB = [int]$columns[2].Trim()
            ComputeCapability = [double]::Parse(
                $columns[3].Trim(),
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
    }
    catch {
        $Script:GpuOk = $false
        $Script:AccelDisplay = "GPU info parse error: $_"
        $Script:AccelRequirement = "NVIDIA GPU with 24 GB VRAM and driver 581+"
        return $null
    }

    $Script:GpuOk = $true
    $gpuVramGiB = ($gpu.MemoryMiB / 1024).ToString("F2", [Globalization.CultureInfo]::InvariantCulture)
    $Script:AccelDisplay = "$($gpu.Name) ($gpuVramGiB GiB VRAM, $($gpu.MemoryMiB) MiB reported, driver $($gpu.DriverVersion))"
    $Script:AccelRequirement = "NVIDIA GPU with 24 GB VRAM and driver 581+"

    # Allow 256 MiB of reporting headroom for 24 GiB cards (e.g. RTX 4090 reports 24564 MiB).
    $minimumReportedVramMiB = (24 * 1024) - 256
    if ($gpu.MemoryMiB -lt $minimumReportedVramMiB) {
        $Script:GpuOk = $false
    }

    # Driver version check: require at least 581
    $driverMajor = $gpu.DriverVersion.Major
    $Script:DriverOk = $driverMajor -ge 581
    $Script:DriverDisplay = "Driver $($gpu.DriverVersion)"
    $Script:DriverRequirement = "Driver 581+"
    if (-not $Script:DriverOk) {
        $Script:GpuOk = $false
    }

    return $gpu
}

function Assert-VisualCppRuntime {
    $systemDirectory = Join-Path $env:WINDIR "System32"
    $requiredDlls = @("msvcp140.dll", "vcruntime140.dll")
    $missingDlls = @(
        $requiredDlls | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $systemDirectory $_) -PathType Leaf)
        }
    )
    if ($missingDlls.Count -eq 0) {
        $Script:VcRedistOk = $true
        $Script:VcRedistDisplay = "Installed"
        $Script:VcRedistRequirement = ""
        Write-Host "Microsoft Visual C++ Runtime is available."
        return
    }

    $Script:VcRedistOk = $false
    $Script:VcRedistDisplay = "Missing: $($missingDlls -join ', ')"
    $Script:VcRedistRequirement = "Microsoft Visual C++ Redistributable 2015+"
    Write-Host "Microsoft Visual C++ Runtime is missing: $($missingDlls -join ', ')" -ForegroundColor Yellow
}

# ============================================================
# SHA-256 helper
# ============================================================

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
        }
        finally { $sha256.Dispose() }
    }
    finally { $stream.Dispose() }
}

# ============================================================
# Download helpers
# ============================================================

# ============================================================
# Download with retry logic (matches install.sh download_with_retry)
# Every attempt resumes from the bytes already on disk.
# ============================================================
function Invoke-DownloadWithRetry {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [int]$MaxRetries = 3,
        [string]$Label = ""
    )

    $fileName = [System.IO.Path]::GetFileName($Destination)
    $attempt = 1
    $delay = 2

    while ($attempt -le $MaxRetries) {
        if ($attempt -gt 1) {
            Write-Host "  Attempt $attempt of $MaxRetries" -ForegroundColor DarkGray
        }

        $before = [long]0
        if (Test-Path -LiteralPath $Destination) {
            $before = [long](Get-Item -LiteralPath $Destination).Length
        }

        if (Invoke-ResumableDownload -Source $Source -Destination $Destination -Label $Label) {
            return $true
        }

        $after = [long]0
        if (Test-Path -LiteralPath $Destination) {
            $after = [long](Get-Item -LiteralPath $Destination).Length
        }

        if ($attempt -lt $MaxRetries) {
            if ($after -gt $before) {
                $delay = 2  # Reset backoff if we made progress
            }
            if ($after -gt 0) {
                Write-Host "  Download stopped at $(HumanBytes $after). Resuming in ${delay}s..." -ForegroundColor Yellow
            } else {
                Write-Host "  Download failed. Retrying in ${delay}s..." -ForegroundColor Yellow
            }
            Start-Sleep -Seconds $delay
            $delay = $delay * 2
        }
        $attempt++
    }

    Write-Host "  ERROR: Download failed after $MaxRetries attempts for $fileName" -ForegroundColor Red
    Emit-Error "Download failed after $MaxRetries attempts"
    if (Test-Path -LiteralPath $Destination) {
        Write-Host "  The partial file is kept — re-run this script to resume." -ForegroundColor DarkGray
    }
    return $false
}

function Invoke-ResumableDownload {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Label = ""
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        throw "curl.exe is required for downloads. Install it via winget or your package manager."
    }

    $fileName = [System.IO.Path]::GetFileName($Destination)
    $destDir = Split-Path $Destination -Parent
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    # Check for already-complete download
    $remoteSize = [long]0
    try {
        $probeHeaders = Invoke-WebRequest -Uri $Source -Method Head -UseBasicParsing -ErrorAction Stop
        if ($probeHeaders) {
            $cl = $probeHeaders.Headers["Content-Length"]
            if ($cl) {
                $remoteSize = [long]((($cl -split ',')[0] -replace '\D', ''))
            }
        }
    }
    catch {
        $remoteSize = [long]0
    }

    $localSize = [long]0
    if (Test-Path -LiteralPath $Destination) {
        $localSize = (Get-Item -LiteralPath $Destination).Length
    }

    if ($remoteSize -gt 0 -and $localSize -eq $remoteSize) {
        Write-Host "  Already downloaded ($(HumanBytes $remoteSize))" -ForegroundColor Green
        Emit-Progress $fileName $localSize $remoteSize $Label
        return $true
    }

    if ($remoteSize -gt 0 -and $localSize -gt $remoteSize) {
        Write-Host "  Local file is bigger than remote - starting over." -ForegroundColor Yellow
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        $localSize = 0
    }

    if ($localSize -gt 0) {
        Write-Host "  Resuming at $(HumanBytes $localSize)"
    }

    # Use curl's own --stderr to avoid PowerShell 5.1 bug with
    # Start-Process -RedirectStandardError (returns $null for ExitCode)
    $curlErrFile = "$env:TEMP\junie-curl-err.txt"
    Remove-Item -LiteralPath $curlErrFile -Force -ErrorAction SilentlyContinue

    # Build curl arguments (silent — we track progress by polling the file)
    $arguments = @(
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--retry", "3",
        "--retry-delay", "2",
        "--continue-at", "-",
        "--stderr", $curlErrFile,
        "--output", $Destination,
        $Source
    )

    # Handle HF_TOKEN for Hugging Face downloads
    $curlConfig = $null
    if ($env:HF_TOKEN -and ($Source -match "huggingface\.co")) {
        $curlConfig = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText(
            $curlConfig,
            "oauth2-bearer = `"$($env:HF_TOKEN)`"",
            [System.Text.Encoding]::ASCII
        )
        $arguments = @("--config", $curlConfig) + $arguments
    }

    $proc = $null
    try {
        # Run curl in background, poll file size for progress
        $proc = Start-Process -FilePath $curl.Source -ArgumentList $arguments -NoNewWindow -PassThru
        
        $prevBytes = [long]$localSize
        $prevTime = [long][System.DateTimeOffset]::Now.ToUnixTimeSeconds()
        $bytesPerSec = [long]0

        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 200
            $curBytes = [long]0
            if (Test-Path -LiteralPath $Destination) {
                $curBytes = [long](Get-Item -LiteralPath $Destination).Length
            }
            $curTime = [long][System.DateTimeOffset]::Now.ToUnixTimeSeconds()
            if ($curTime -gt $prevTime) {
                $bytesPerSec = [long](([long]$curBytes - [long]$prevBytes) / ([long]$curTime - [long]$prevTime))
                $prevBytes = $curBytes
                $prevTime = $curTime
            }
            Progress-Render $curBytes $remoteSize $bytesPerSec $Label
            # JSON progress events: emit once per second (matches install.sh)
            if ($Script:MachineOutput -and $remoteSize -gt 0) {
                $now = [long][System.DateTimeOffset]::Now.ToUnixTimeSeconds()
                if ($now -gt $Script:LastProgressTime) {
                    $Script:LastProgressTime = $now
                    Emit-Progress $fileName $curBytes $remoteSize $Label
                }
            }
        }

        $proc.WaitForExit()

        # PowerShell 5.1 Start-Process returns $null for ExitCode with console apps.
        # Instead, use curl's stderr file: empty means success, non-empty means failure
        # (--silent --show-error only writes on error).
        $curlError = $false
        if (Test-Path $curlErrFile) {
            $errContent = Get-Content $curlErrFile -ErrorAction SilentlyContinue | ForEach-Object { $_.TrimEnd("`r") }
            if ($errContent -and ($errContent -join "").Trim() -ne "") {
                $curlError = $true
            }
        }

        if (-not $curlError) {
            # Success
            $finalBytes = [long]0
            if (Test-Path -LiteralPath $Destination) {
                $finalBytes = [long](Get-Item -LiteralPath $Destination).Length
            }
            Progress-Render $finalBytes $remoteSize $bytesPerSec $Label
            Emit-Progress $fileName $finalBytes $remoteSize $Label
            Progress-End
            return $true
        }

        # Curl reported an error — check if file is actually complete anyway
        if ($remoteSize -gt 0) {
            $actualFinal = [long]0
            if (Test-Path -LiteralPath $Destination) {
                $actualFinal = [long](Get-Item -LiteralPath $Destination).Length
            }
            if ($actualFinal -eq $remoteSize) {
                Write-Host "  Curl reported an error, but the file is complete ($(HumanBytes $actualFinal))." -ForegroundColor Yellow
                Progress-Render $actualFinal $remoteSize $bytesPerSec $Label
                Emit-Progress $fileName $actualFinal $remoteSize $Label
                Progress-End
                return $true
            }
        }

        # Show curl error
        if (Test-Path $curlErrFile) {
            $errText = Get-Content $curlErrFile -ErrorAction SilentlyContinue | Select-Object -First 2 | ForEach-Object { $_.TrimEnd("`r") }
            if ($errText) { Write-Host "  $errText" -ForegroundColor Red }
        }
        Write-Host "  Download failed. Partial data kept for retry." -ForegroundColor Red
        return $false
    }
    finally {
        # Kill orphaned curl if script exits unexpectedly
        if ($proc -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
        if ($curlConfig) {
            Remove-Item -LiteralPath $curlConfig -Force -ErrorAction SilentlyContinue
        }
        if ($curlErrFile) {
            Remove-Item -LiteralPath $curlErrFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function HumanBytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:F1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:F1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:F0} KB" -f ($Bytes / 1KB) }
    return "{0} B" -f $Bytes
}

# ============================================================
# Progress bar rendering
# ============================================================

$Script:ProgressDrew = $false
$Script:ProgressLogged = -1
$Script:LastProgressPct = -1
$Script:LastProgressTime = [long]0
$Script:IsTerminal = [bool](Test-Path variable:Interactive) -or ([System.Console]::IsOutputRedirected -eq $false)

function Progress-Render {
    param(
        [long]$HaveBytes,
        [long]$TotalBytes,
        [long]$BytesPerSec,
        [string]$Label
    )

    # Machine output mode — skip visual progress, events carry it
    if ($Script:MachineOutput) { return }

    # Non-interactive: log at 10% intervals
    if ([System.Console]::IsOutputRedirected) {
        if ($TotalBytes -gt 0) {
            $step = [int](([double]$HaveBytes * 10 / $TotalBytes))
            if ($step -gt $Script:ProgressLogged) {
                $Script:ProgressLogged = $step
                Write-Host "  $($step * 10)% ($(HumanBytes $HaveBytes) of $(HumanBytes $TotalBytes))"
            }
        }
        return
    }

    $Script:ProgressDrew = $true

    # Build the bar
    $barWidth = 32
    $ratio = if ($TotalBytes -gt 0) { [double]$HaveBytes / $TotalBytes } else { 1 }
    if ($ratio -gt 1) { $ratio = 1 }
    $filled = [int]($ratio * $barWidth + 0.5)
    $bar = "█" * $filled + "░" * ($barWidth - $filled)

    # Stats
    $pct = if ($TotalBytes -gt 0) { "{0,3}%" -f ([int]($ratio * 100)) } else { "   " }
    $size = if ($TotalBytes -gt 0) {
        "$(HumanBytes $HaveBytes) of $(HumanBytes $TotalBytes)"
    } else {
        $(HumanBytes $HaveBytes)
    }
    $speed = if ($BytesPerSec -gt 0) { "  $(HumanBytes $BytesPerSec)/s" } else { "" }

    # ETA
    $eta = ""
    if ($BytesPerSec -gt 0 -and $TotalBytes -gt $HaveBytes) {
        $etaSecs = [int](([double]($TotalBytes - $HaveBytes)) / $BytesPerSec)
        $eta = "  eta {0:D2}:{1:D2}" -f ([int]($etaSecs / 60)), ([int]($etaSecs % 60))
    }

    $line = "`r  $bar  $pct  $size$speed$eta"
    if ($Label) { $line += "  $Label" }

    [System.Console]::Write($line)
    [System.Console]::Write([char]27 + "[0K")  # ESC[0K clear to end of line
}

function Progress-End {
    if ($Script:ProgressDrew -and -not [System.Console]::IsOutputRedirected) {
        Write-Host ""  # newline after the bar
    }
    $Script:ProgressDrew = $false
    $Script:ProgressLogged = -1
}

# ============================================================
# Engine installation
# ============================================================

function Engine-CompletionMarker {
    return Join-Path $Script:VersionsDir ".$Script:EngineVersion.installed"
}

function Test-EngineInstalled {
    $ctl = Join-Path $Script:EngineDir "serverctl.ps1"
    return (Test-Path -LiteralPath $ctl -PathType Leaf) -and
           (Test-Path -LiteralPath (Engine-CompletionMarker) -PathType Leaf)
}

function Install-Engine {
    if (Test-EngineInstalled) {
        Write-Host "  Engine v$Script:EngineVersion is already unpacked. Skipping download." -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Downloading $Script:EngineArchive..."
        $archivePath = Join-Path $Script:DownloadDir $Script:EngineArchive
        if (-not (Invoke-DownloadWithRetry -Source $Script:EngineUrl -Destination $archivePath -Label $Script:EngineLabel)) {
            exit 1
        }

        Write-Host "  Checking SHA256..."
        Emit-Activity "verifying" $Script:EngineArchive $Script:EngineLabel
        $actualSha = Get-Sha256 -Path $archivePath
        if ($actualSha -ne $Script:EngineSha256) {
            Write-Host "  ERROR: SHA256 mismatch for $Script:EngineArchive" -ForegroundColor Red
            Write-Host "    Expected: $Script:EngineSha256"
            Write-Host "    Actual:   $actualSha"
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            Write-Host "  The damaged file was removed - re-run this script to download it again."
            Emit-Error "SHA256 mismatch for $Script:EngineArchive"
            exit 1
        }
        Write-Host "  SHA256 verified $actualSha"

        Write-Host "  Unpacking to $Script:EngineDir..."
        Emit-Activity "extracting" $Script:EngineArchive $Script:EngineLabel
        Remove-Item -LiteralPath $Script:EngineDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $Script:EngineDir -Force | Out-Null

        # Try 7z first (handles .zip and .tar.gz), then fall back to Expand-Archive
        $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
        if ($sevenZip) {
            & 7z.exe x -o$Script:EngineDir -y $archivePath | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  ERROR: 7z extraction failed." -ForegroundColor Red
                exit 1
            }
            # If the archive has a top-level folder, flatten it
            $topLevel = Get-ChildItem -LiteralPath $Script:EngineDir -Directory | Select-Object -First 1
            if ($topLevel -and (Get-ChildItem -LiteralPath $Script:EngineDir).Count -eq 1) {
                Move-Item -LiteralPath (Join-Path $Script:EngineDir $topLevel.Name)/* `
                    -Destination $Script:EngineDir -Force
                Remove-Item -LiteralPath $topLevel.FullName -Recurse -Force
            }
        }
        else {
            if ($Script:EngineArchive -like '*.zip') {
                Expand-Archive -LiteralPath $archivePath -DestinationPath $Script:EngineDir -Force
            }
            else {
                # Expand-Archive handles .gz: extract to .tar, then extract contents
                $tmpTar = [System.IO.Path]::GetTempFileName() + ".tar"
                Expand-Archive -LiteralPath $archivePath -DestinationPath (Split-Path $tmpTar -Parent) -Force
                # Rename the extracted .gz result to .tar if needed
                $extracted = Get-ChildItem -LiteralPath (Split-Path $tmpTar -Parent) | Select-Object -First 1
                if ($extracted) {
                    $tmpTar = $extracted.FullName
                }
                Expand-Archive -LiteralPath $tmpTar -DestinationPath $Script:EngineDir -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $tmpTar -Force -ErrorAction SilentlyContinue
            }
            # Flatten if needed
            $topLevel = Get-ChildItem -LiteralPath $Script:EngineDir -Directory | Select-Object -First 1
            if ($topLevel -and (Get-ChildItem -LiteralPath $Script:EngineDir).Count -eq 1) {
                Move-Item -LiteralPath (Join-Path $Script:EngineDir $topLevel.Name)/* `
                    -Destination $Script:EngineDir -Force
                Remove-Item -LiteralPath $topLevel.FullName -Recurse -Force
            }
        }

        New-Item -ItemType File -Path (Engine-CompletionMarker) -Force | Out-Null
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        Write-Host "  Unpack complete."
    }

    # Write the version name to the "current" file (no symlink needed)
    Write-Host "  Recording v$Script:EngineVersion as the current engine..."
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Script:CurrentFile, $Script:EngineVersion, $utf8NoBom)
    Write-Host ""
}

# ============================================================
# Model installation
# ============================================================

function Model-CompletionMarker {
    param([string]$ModelId)
    return Join-Path $Script:ModelsDir ".$ModelId.installed"
}

function Test-ModelInstalled {
    param([string]$ModelId)
    return (Test-Path -LiteralPath (Model-CompletionMarker $ModelId) -PathType Leaf)
}

function Install-ModelIfNeeded {
    param([int]$ArchiveIndex)

    $zipFile = Get-ArchiveField -ArchiveIndex $ArchiveIndex -Field "name"
    $downloadUrl = Get-ArchiveField -ArchiveIndex $ArchiveIndex -Field "downloadUrl"
    $sha256Sum = Get-ArchiveField -ArchiveIndex $ArchiveIndex -Field "sha256"
    $modelId = Get-ArchiveField -ArchiveIndex $ArchiveIndex -Field "modelId"
    $modelLabel = Get-ArchiveField -ArchiveIndex $ArchiveIndex -Field "label"

    if (Test-ModelInstalled -ModelId $modelId) {
        Write-Host "  Model $modelId is already installed. Skipping." -ForegroundColor DarkGray
        return
    }

    Write-Host "  Model $modelLabel is not installed. Proceeding..."
    Write-Host "  Downloading $zipFile..."

    $archivePath = Join-Path $Script:DownloadDir $zipFile
    if (-not (Invoke-DownloadWithRetry -Source $downloadUrl -Destination $archivePath -Label $modelLabel)) {
        exit 1
    }

    Write-Host "  Checking SHA256..."
    Emit-Activity "verifying" $zipFile $modelLabel
    $actual = Get-Sha256 -Path $archivePath
    if ($actual -ne $sha256Sum) {
        Write-Host "  ERROR: SHA256 mismatch for $zipFile" -ForegroundColor Red
        Write-Host "    Expected: $sha256Sum"
        Write-Host "    Actual:   $actual"
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        Write-Host "  The damaged archive was removed - re-run this script to download it again."
        Emit-Error "SHA256 mismatch for $zipFile"
        exit 1
    }
    Write-Host "  SHA256 verified $actual"

    New-Item -ItemType Directory -Path $Script:ModelsDir -Force | Out-Null

    Write-Host "  Copying $zipFile..."
    Emit-Activity "extracting" $zipFile $modelLabel
    Copy-Item -LiteralPath $archivePath -Destination (Join-Path $Script:ModelsDir $zipFile) -Force

    New-Item -ItemType File -Path (Model-CompletionMarker $modelId) -Force | Out-Null
    Write-Host "  Extraction complete." -ForegroundColor Green
}

# ============================================================
# Server config
# ============================================================

# serverctl update-configs owns server-config.json: it generates the api_key and
# picks a free port on first install, and keeps both on re-install. The installer
# only reads the port back so the readiness check and summary use the real one.
function Sync-EnginePortFromConfig {
    $serverConfig = Join-Path $Script:BaseDir "server-config.json"
    if (-not (Test-Path -LiteralPath $serverConfig -PathType Leaf)) { return }
    try {
        $port = (Get-Content -LiteralPath $serverConfig -Raw | ConvertFrom-Json).port
        if ($port -is [int] -or $port -is [long]) {
            if ($port -ge 1 -and $port -le 65535) {
                $Script:EnginePort = [int]$port
            }
        }
    }
    catch { }
}

# ============================================================
# Start engine
# ============================================================

# The engine runs as junie-local.exe; its llama-server.exe child exits with it.
# Only processes installed under $Script:BaseDir (any engine version) count.
function Get-EngineProcesses {
    $root = [System.IO.Path]::GetFullPath($Script:BaseDir).TrimEnd('\') + '\'
    try {
        return @(Get-Process -Name "junie-local" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) })
    }
    catch { return @() }
}

function Test-EngineRunning {
    return (Get-EngineProcesses).Count -gt 0
}

function Start-Engine {
    $serverConfig = Join-Path $Script:BaseDir "server-config.json"
    if (-not (Test-Path -LiteralPath $serverConfig -PathType Leaf)) {
        Write-Host "  ERROR: server-config.json not found in $Script:BaseDir" -ForegroundColor Red
        Emit-Error "server-config.json not found in $Script:BaseDir"
        return $false
    }
    $authToken = (Get-Content -LiteralPath $serverConfig -Raw | ConvertFrom-Json).api_key

    $ctlPath = Join-Path $Script:EngineDir "serverctl.ps1"
    if (-not (Test-Path -LiteralPath $ctlPath -PathType Leaf)) {
        Write-Host "  ERROR: serverctl.ps1 not found in $Script:EngineDir" -ForegroundColor Red
        Emit-Error "serverctl.ps1 not found in $Script:EngineDir"
        return $false
    }

    # Stop any running engine
    if (Test-EngineRunning) {
        Write-Host "  Stopping the running engine..."
        try {
            # Keep its output out of this function's return value.
            & $ctlPath stop 2>$null | Out-Null
        }
        catch { }
        $waited = 0
        while ($waited -lt 10 -and (Test-EngineRunning)) {
            Start-Sleep -Seconds 1
            $waited++
        }
        # serverctl could not stop it in time: kill junie-local, llama-server exits with it.
        $remaining = Get-EngineProcesses
        if ($remaining.Count -gt 0) {
            Write-Host "  The engine did not stop via serverctl, killing it..." -ForegroundColor Yellow
            $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
            $waited = 0
            while ($waited -lt 5 -and (Test-EngineRunning)) {
                Start-Sleep -Seconds 1
                $waited++
            }
            if (Test-EngineRunning) {
                Write-Host "  WARNING: could not stop the running engine." -ForegroundColor Yellow
                Emit-Warning "could not stop the running engine"
            }
        }
    }

    Write-Host "  Starting the engine..."
    # Use the running PowerShell installation; PATH may contain an unusable Store alias.
    $psExecutable = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $psHost = Join-Path $PSHOME $psExecutable
    try {
        Start-Process -FilePath $psHost `
            -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ctlPath`"", "start" `
            -WindowStyle Hidden
    }
    catch {
        Write-Host "  WARNING: Could not start engine via serverctl. $_" -ForegroundColor Yellow
    }

    # Wait for engine readiness
    $waited = 0
    while ($waited -lt 30) {
        try {
            $response = Invoke-WebRequest `
                -Uri "http://localhost:$Script:EnginePort/status" `
                -Headers @{ "Authorization" = "Bearer $authToken" } `
                -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($response) {
                $phase = ($response.Content | Get-JsonField -Field "phase")
                if ($phase -eq "ready") {
                    Write-Host "  Engine is ready on port $Script:EnginePort."
                    return $true
                }
                if ($phase -eq "error") { break }
            }
        }
        catch { }
        Start-Sleep -Seconds 1
        $waited++
    }

    Write-Host "  WARNING: the engine is not answering on port $Script:EnginePort yet." -ForegroundColor Yellow
    Write-Host "  Check the engine logs in $Script:BaseDir"
    Emit-Warning "engine did not start listening on port $Script:EnginePort - see logs in $Script:BaseDir"
    return $false
}

# Send one short chat request so the first Junie request does not pay for the first generation.
function Warm-Engine {
    $ctlPath = Join-Path $Script:EngineDir "serverctl.ps1"
    if (-not (Test-Path -LiteralPath $ctlPath -PathType Leaf)) { return }
    Write-Host "  Warming up the engine..."
    # Show serverctl's stdout as regular installer output; its stderr goes straight to the console.
    & $ctlPath warmup --model $Model | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: engine warm-up failed. The first request may be slower." -ForegroundColor Yellow
        Emit-Warning "serverctl warmup failed"
    }
}

# ============================================================
# System validation display
# ============================================================

function Print-Value {
    param(
        [string]$Label,
        [string]$Value,
        [bool]$Ok,
        [bool]$Warn,
        [string]$Requirement
    )
    $pad = 20 - $Label.Length
    $suffix = " " * [math]::Max(0, $pad)
    if ($Ok -and -not $Warn) {
        Write-Host "  $Label$suffix" -NoNewline
        Write-Host " $Value" -ForegroundColor Green
    }
    elseif ($Warn) {
        Write-Host "  $Label$suffix" -NoNewline
        Write-Host " $Value" -ForegroundColor Yellow -NoNewline
        if ($Requirement) {
            Write-Host "  ($Requirement)" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host "  $Label$suffix" -NoNewline
        Write-Host " $Value" -ForegroundColor Red -NoNewline
        if ($Requirement) {
            Write-Host "  (requirement: $Requirement)" -ForegroundColor DarkGray
        }
    }
}

# ============================================================
# Main flow
# ============================================================

# --- System checks ---
$Script:OsOk = $true
$Script:GpuOk = $true
$Script:DriverOk = $true
$Script:VcRedistOk = $true
$Script:VcRedistDisplay = "Installed"
$Script:VcRedistRequirement = ""
$Script:AllOk = $true

Test-WindowsRequirements
if (-not $Script:OsOk) {
    $Script:AllOk = $false
}

$gpu = Get-NvidiaGpu
if (-not $Script:GpuOk) {
    $Script:AllOk = $false
}
if (-not $Script:DriverOk) {
    $Script:AllOk = $false
}

Assert-VisualCppRuntime
if (-not $Script:VcRedistOk) {
    $Script:AllOk = $false
}

# CPU model
try {
    $cpuModel = (Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name
}
catch { $cpuModel = "unknown" }

# --- Display system info ---
Write-Host ""
Write-Host "  Junie Local Model Installer" -ForegroundColor Green
Write-Host "  ----------------------------" -ForegroundColor DarkGray
Write-Host ""

Print-Value "OS:" "$Script:OsDisplay" $Script:OsOk $false "$Script:OsRequirement"
Emit-Check "os" (Check-Status $Script:OsOk $false) "$Script:OsDisplay" "$Script:OsRequirement"

Print-Value "CPU:" "$cpuModel" $true $false ""
Emit-Check "cpu" "ok" "$cpuModel" ""

Print-Value "GPU:" "$Script:AccelDisplay" $Script:GpuOk $false "$Script:AccelRequirement"
Emit-Check "gpu" (Check-Status $Script:GpuOk $false) "$Script:AccelDisplay" "$Script:AccelRequirement"

Print-Value "Driver:" "$Script:DriverDisplay" $Script:DriverOk $false "$Script:DriverRequirement"
Emit-Check "driver" (Check-Status $Script:DriverOk $false) "$Script:DriverDisplay" "$Script:DriverRequirement"

Print-Value "VC++ Redist:" "$Script:VcRedistDisplay" $Script:VcRedistOk $false "$Script:VcRedistRequirement"
Emit-Check "vc_redist" (Check-Status $Script:VcRedistOk $false) "$Script:VcRedistDisplay" "$Script:VcRedistRequirement"

# Resolve the install metadata (model and engine configs) now that the checks
# are done. This is the first thing in the script that touches the network or
# writes to disk, and --check-only exits right below without needing any of it,
# so a check never pays for it - it reports an empty engine version instead.
if (-not $CheckOnly -and $Script:AllOk) {
    Resolve-InstallMetadata
}

# A re-install keeps the port saved in server-config.json, so report that one.
Sync-EnginePortFromConfig

# Config event
Emit-Event "`"event`":`"config`",`"port`":$Script:EnginePort,`"ram_gb`":$Script:EngineRamGb,`"engine_version`":`"$(Json-Escape $Script:EngineVersion)`",`"model`":`"$(Json-Escape $Model)`",`"checks_passed`":$($Script:AllOk.ToString().ToLowerInvariant())"

# Check-only mode
if ($CheckOnly) {
    if ($Script:AllOk) {
        exit 0
    }
    else {
        exit 1
    }
}

# Abort if requirements not met
if (-not $Script:AllOk) {
    Write-Host ""
    Write-Host "  Some system requirements are not met. Installation cannot proceed." -ForegroundColor Red
    Emit-Error "Some system requirements are not met. Installation cannot proceed."
    Wait-ForExitKey
    exit 1
}

# ============================================================
# Main installation flow
# ============================================================

Write-Host "  Creating directories..." -ForegroundColor DarkGray
New-Item -ItemType Directory -Path $Script:ModelsDir -Force | Out-Null
New-Item -ItemType Directory -Path $Script:VersionsDir -Force | Out-Null
New-Item -ItemType Directory -Path $Script:DownloadDir -Force | Out-Null

# --- Step 1: Install the inference engine ---
Write-Host ""
Write-Host "  Installing $Script:EngineLabel" -ForegroundColor Green
Write-Host "  ----------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Emit-StepStart "engine" "Installing $Script:EngineLabel"
Install-Engine
Emit-StepDone "engine"

# --- Step 2: Download and install models ---
Write-Host ""
Write-Host "  Installing models" -ForegroundColor Green
Write-Host "  -----------------" -ForegroundColor DarkGray
Write-Host ""
Emit-StepStart "models" "Installing models"

for ($i = 0; $i -lt $Script:ArchiveCount; $i++) {
    Install-ModelIfNeeded -ArchiveIndex $i
}

# Cleanup downloaded archives
Write-Host "  Removing downloaded archives..." -ForegroundColor DarkGray
Remove-Item -LiteralPath $Script:DownloadDir -Recurse -Force -ErrorAction SilentlyContinue
Emit-StepDone "models"

# --- Step 3: Configure Junie ---
Write-Host ""
Write-Host "  Configuring Junie" -ForegroundColor Green
Write-Host "  -----------------" -ForegroundColor DarkGray
Write-Host ""
Emit-StepStart "configure" "Configuring Junie"
# Rebuild server-config.json from the engine template (keeping a saved api_key,
# port and max_context_length, generating a key and a free port when missing)
# and write the Junie model config to $JUNIE_HOME/models/<id>.json.
# Other hand-edited server-config.json fields are reset on every install.
$ctlPath = Join-Path $Script:EngineDir "serverctl.ps1"
if (Test-Path -LiteralPath $ctlPath -PathType Leaf) {
    # Show serverctl's stdout as regular installer output; its stderr goes straight to the console.
    & $ctlPath update-configs --junie-home $Script:JunieHome --model $Model |
        ForEach-Object { Write-Host "  $_" }
    $profilePath = Join-Path $Script:JunieHome "models\$Script:JunieModelId.json"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        Write-Host "  WARNING: Junie config generation failed." -ForegroundColor Yellow
        Emit-Warning "serverctl update-configs failed"
    }
    Sync-EnginePortFromConfig
} else {
    Write-Host "  WARNING: serverctl.ps1 not found at $ctlPath" -ForegroundColor Yellow
    Write-Host "  Skipping Junie config generation."
}
Emit-StepDone "configure"

# --- Step 4: Start the inference engine ---
Write-Host ""
Write-Host "  Starting and warming up the inference engine" -ForegroundColor Green
Write-Host "  ----------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Emit-StepStart "start" "Starting and warming up the inference engine"
if (Start-Engine) {
    Warm-Engine
}
Emit-StepDone "start"

# --- Summary ---
$mainArchiveIndex = Get-MainArchiveIndex
$mainModelId = Get-ArchiveField -ArchiveIndex $mainArchiveIndex -Field "modelId"
$mainLabel = Get-ArchiveField -ArchiveIndex $mainArchiveIndex -Field "label"

Write-Host ""
Write-Host "  Installation complete" -ForegroundColor Green
Write-Host "  ---------------------" -ForegroundColor DarkGray
Write-Host ""

Print-Value "Models:" "$Script:ModelsDir" $true $false ""
Print-Value "Engine:" "v$Script:EngineVersion on port $Script:EnginePort" $true $false ""
Print-Value "Junie model config:" "$Script:JunieHome\models\${Script:JunieModelId}.json" $true $false ""
Print-Value "Default model:" "$Script:JunieModelId" $true $false ""

Write-Host ""
Write-Host "  The engine serves http://localhost:$Script:EnginePort - the first request has to wait"
Write-Host "  for the model to load."
Write-Host "  Control the engine with: $ctlPath {start|stop|status|wait}"
Write-Host ""

Emit-Event "`"event`":`"done`",`"model_id`":`"$Script:JunieModelId`",`"port`":$Script:EnginePort,`"model_path`":`"$(Json-Escape "$Script:ModelsDir/$mainModelId")`",`"label`":`"$(Json-Escape "$mainLabel")`""

Wait-ForExitKey
exit 0
