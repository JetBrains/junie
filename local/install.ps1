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
  - CUDA 12+ driver
  - Microsoft Visual C++ Redistributable
  - Minimum 40 GB RAM (60 GB recommended)

.PARAMETER Model
  Model identifier to install.  Default: Qwen3.6-27B-LLaMA-4bit

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

  .\install.ps1 --Model Qwen3.8-27B-LLaMA-4bit --Channel eap

  .\install.ps1 --CheckOnly
#>

param(
    [string]$Model = "Qwen3.6-27B-LLaMA-4bit",
    [string]$Channel = "main",
    [switch]$CheckOnly,
    [switch]$ListModels,
    [switch]$Json
)

if ($Json) { $script:MachineOutput = $true } else { $script:MachineOutput = $false }
if ($Channel -notin @("main", "eap")) {
    Write-Host "ERROR: Channel must be 'main' or 'eap', got '$Channel'" -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ============================================================
# Configuration
# ============================================================

$Script:ProtocolVersion = 1

# Base installation directory - mirrors ~/.local/share/junie-local on Unix
$Script:BaseDir = Join-Path $env:LOCALAPPDATA "junie-local"
$Script:JunieHome = if ($env:JUNIE_HOME) { $env:JUNIE_HOME } else { Join-Path $env:USERPROFILE ".junie" }
$Script:ModelsDir = Join-Path $Script:BaseDir "models"
$Script:VersionsDir = Join-Path $Script:BaseDir "versions"
$Script:DownloadDir = Join-Path $Script:BaseDir "incomplete_downloads"

# Engine port and RAM allowance (matches install.sh defaults)
$Script:EnginePort = 19239
$Script:EngineRamGb = 35

# Update files base URL - override via env var for testing
$Script:UpdateFilesBaseUrl =
    if ($env:JUNIE_LOCAL_UPDATE_FILES_BASE_URL) {
        $env:JUNIE_LOCAL_UPDATE_FILES_BASE_URL
    }
    else {
        "https://raw.githubusercontent.com/jetbrains-junie/junie/erokhins/local_update/local"
    }

# Platform identifier (matches install.sh convention)
$Script:Platform = "windows-amd64"

# ============================================================
# Helpers: machine-readable events (--json)
# ============================================================

function Emit-Event {
    param([string]$Payload)
    if (-not $MachineOutput) { return }
    Write-Output "{{$payload}}"
}

function Emit-Check {
    param([string]$Name, [string]$Status, [string]$Value, [string]$Requirement)
    Emit-Event "event:`"check`",name:`"$Name`",status:`"$Status`",value:`"$(Json-Escape $Value)`",requirement:`"$(Json-Escape $Requirement)`""
}

function Emit-StepStart {
    param([string]$Id, [string]$Title)
    Emit-Event "event:`"step_start`",id:`"$Id`",title:`"$(Json-Escape $Title)`""
}

function Emit-StepDone {
    param([string]$Id)
    Emit-Event "event:`"step_done`",id:`"$Id`""
}

function Emit-Progress {
    param([string]$File, [long]$Bytes, [long]$Total, [string]$Label, [string]$Action = "downloading")
    Emit-Event "event:`"progress`",action:`"$Action`",file:`"$(Json-Escape $File)`",bytes:$Bytes,total:$Total,label:`"$(Json-Escape $Label)`""
}

function Emit-Activity {
    param([string]$Action, [string]$File, [string]$Label)
    Emit-Event "event:`"activity`",action:`"$Action`",file:`"$(Json-Escape $File)`",label:`"$(Json-Escape $Label)`""
}

function Emit-Warning {
    param([string]$Message)
    Emit-Event "event:`"warning`",message:`"$(Json-Escape $Message)`""
}

function Emit-Error {
    param([string]$Message)
    Emit-Event "event:`"error`",message:`"$(Json-Escape $Message)`""
}

function Json-Escape {
    param([string]$Text)
    return $Text.Replace('\\', '\\\\').Replace('"', '\\"')
}

function Check-Status {
    param([bool]$Ok, [bool]$Warn)
    if (-not $Ok) { return "fail" }
    if ($Warn) { return "warn" }
    return "ok"
}

# Hello event
Emit-Event "event:`"hello`",protocol:$Script:ProtocolVersion"

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

function Fetch-ModelsConfig {
    $modelsUpdateUrl = "$Script:UpdateFilesBaseUrl/update-info-models-$Script:Channel.jsonl"

    $jsonl = try {
        Invoke-WebRequest -Uri $modelsUpdateUrl -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Could not fetch models config from $modelsUpdateUrl" -ForegroundColor Red
        Emit-Error "Could not fetch models config from $modelsUpdateUrl"
        exit 1
    }

    $lines = $jsonl.Content -split "`r?`n" | Where-Object { $_.Trim() -ne "" }

    # Find the entry matching platform + model
    $dq = [char]34
    $entry = $lines | Where-Object {
        $_ -match "${dq}platform${dq}:${dq}$([regex]::Escape($Script:Platform))${dq}" -and
        $_ -match "${dq}id${dq}:${dq}$([regex]::Escape($Model))${dq}"
    } | Select-Object -Last 1

    if (-not $entry) {
        $supported = ($lines | Where-Object {
            $_ -match "${dq}platform${dq}:${dq}$([regex]::Escape($Script:Platform))${dq}"
        } | ForEach-Object { $_ | Get-JsonField -Field "id" }) -join ","
        Write-Host "ERROR: Unknown model: $Model for platform $Script:Platform (supported: $supported)" -ForegroundColor Red
        exit 1
    }

    $Script:ModelFileId = $entry | Get-JsonField -Field "id"

    # Fetch the model JSON file
    $modelConfigUrl = "$Script:UpdateFilesBaseUrl/models/$Script:ModelFileId.json"
    $Script:ModelsJson = try {
        (Invoke-WebRequest -Uri $modelConfigUrl -UseBasicParsing -ErrorAction Stop).Content
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
    $dq = [char]34
    $matches = [regex]::Matches($Script:ModelsJson, "(?i)${dq}${Field}\s*:\s*${dq}[^${dq}]*)")
    if ($ArchiveIndex -lt $matches.Count) {
        return $matches[$ArchiveIndex].Groups[1].Value.Trim('"').Trim()
    }
    return ""
}

function Fetch-EngineConfig {
    $engineUpdateUrl = "$Script:UpdateFilesBaseUrl/update-info-engine-$Script:Channel.jsonl"

    $jsonl = try {
        Invoke-WebRequest -Uri $engineUpdateUrl -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Could not fetch engine config from $engineUpdateUrl" -ForegroundColor Red
        exit 1
    }

    $lines = $jsonl.Content -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
    $dq = [char]34
    $entry = $lines | Where-Object {
        $_ -match "${dq}platform${dq}:${dq}$([regex]::Escape($Script:Platform))${dq}"
    } | Select-Object -Last 1

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
$Script:CurrentLink = Join-Path $Script:BaseDir "current"

# Fetch configs
Fetch-ModelsConfig
Fetch-EngineConfig

# Archive name from URL — must be after Fetch-EngineConfig
$Script:EngineArchive = [System.IO.Path]::GetFileName($Script:EngineUrl)
$Script:EngineDir = Join-Path $Script:VersionsDir $Script:EngineVersion
$Script:EngineCtl = Join-Path $Script:CurrentLink "serverctl.ps1"

# ============================================================
# List models mode
# ============================================================

if ($ListModels) {
    $modelsUpdateUrl = "$Script:UpdateFilesBaseUrl/update-info-models-$Script:Channel.jsonl"
    $jsonl = (Invoke-WebRequest -Uri $modelsUpdateUrl -UseBasicParsing).Content
    $lines = $jsonl -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
    $dq = [char]34
    $platformLines = $lines | Where-Object {
        $_ -match "${dq}platform${dq}:${dq}$([regex]::Escape($Script:Platform))${dq}"
    }

    if ($MachineOutput) {
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
        Emit-Event "event:`"models`",platform:`"$(Json-Escape $Script:Platform)`",channel:`"$(Json-Escape $Script:Channel)`",models:$array"
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

function Assert-SupportedWindows {
    if ($env:OS -ne "Windows_NT" -or -not [Environment]::Is64BitOperatingSystem) {
        throw "This installer requires 64-bit Windows."
    }

    # Check Windows 10+ (build 19041+)
    $osVersion = [Environment]::OSVersion.Version
    if ($osVersion.Major -lt 10 -or ($osVersion.Major -eq 10 -and $osVersion.Build -lt 19041)) {
        throw "Windows 10 build 19041 or newer is required. Detected: $($osVersion.Major).$($osVersion.Minor) build $($osVersion.Build)"
    }

    $Script:OsDisplay = "Windows $($osVersion.Major).$($osVersion.Minor) build $($osVersion.Build)"
    $Script:OsRequirement = "Windows 10 build 19041 or newer"
    $Script:OsOk = $true

    Write-Host "64-bit Windows is available: $Script:OsDisplay"
}

function Get-NvidiaGpu {
    $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        $Script:GpuOk = $false
        $Script:AccelDisplay = "nvidia-smi not found"
        $Script:AccelRequirement = "NVIDIA GPU with 24 GB VRAM and CUDA 12+"
        $Script:CudaOk = $false
        $Script:CudaDisplay = "CUDA not detected"
        $Script:CudaRequirement = "CUDA 12+"
        return $null
    }

    $output = & $nvidiaSmi.Source `
        --query-gpu=name,driver_version,memory.total,compute_cap `
        --format=csv,noheader,nounits

    if ($LASTEXITCODE -ne 0) {
        $Script:GpuOk = $false
        $Script:AccelDisplay = "nvidia-smi failed"
        $Script:AccelRequirement = "NVIDIA GPU with 24 GB VRAM and CUDA 12+"
        return $null
    }

    $columns = @([string]($output | Select-Object -First 1) -split ",\s*")
    if ($columns.Count -ne 4) {
        $Script:GpuOk = $false
        $Script:AccelDisplay = "GPU info parse error"
        $Script:AccelRequirement = "NVIDIA GPU with 24 GB VRAM and CUDA 12+"
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
        $Script:AccelRequirement = "NVIDIA GPU with 24 GB VRAM and CUDA 12+"
        return $null
    }

    $Script:GpuOk = $true
    $gpuVramGb = [math]::Floor($gpu.MemoryMiB / 1024)
    $Script:AccelDisplay = "$($gpu.Name) ($gpuVramGb GB VRAM, driver $($gpu.DriverVersion))"
    $Script:AccelRequirement = "NVIDIA GPU with 24 GB VRAM and CUDA 12+"

    if ($gpu.MemoryMiB -lt (24 * 1024)) {
        $Script:GpuOk = $false
    }

    # CUDA version from nvidia-smi header
    $cudaHeader = & $nvidiaSmi.Source 2>$null | Select-String "CUDA Version" | Select-Object -First 1
    if ($cudaHeader) {
        $cudaMatch = [regex]::Match($cudaHeader.ToString(), "CUDA Version:\s*(\d+)\.")
        if ($cudaMatch.Success) {
            $cudaMajor = [int]$cudaMatch.Groups[1].Value
            $Script:CudaOk = $cudaMajor -ge 12
            $Script:CudaDisplay = "CUDA $cudaMajor.x"
            $Script:CudaRequirement = "CUDA 12+"
            if (-not $Script:CudaOk) {
                $Script:GpuOk = $false
            }
        }
        else {
            $Script:CudaOk = $false
            $Script:CudaDisplay = "CUDA version not detected"
            $Script:CudaRequirement = "CUDA 12+"
        }
    }
    else {
        $Script:CudaOk = $false
        $Script:CudaDisplay = "CUDA version not detected"
        $Script:CudaRequirement = "CUDA 12+"
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

function Get-SystemRam {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) {
        $Script:MemGb = [math]::Floor($cs.TotalPhysicalMemory / 1GB)
    }
    else {
        $Script:MemGb = 0
    }
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
    $remoteSize = 0
    try {
        $probeHeaders = Invoke-WebRequest -Uri $Source -Method Head -UseBasicParsing -ErrorAction Stop
        if ($probeHeaders) {
            $remoteSize = $probeHeaders.Headers["Content-Length"] | ForEach-Object { [long]$_ } | Select-Object -First 1
        }
    }
    catch {
        $remoteSize = 0
    }

    $localSize = if (Test-Path -LiteralPath $Destination) {
        (Get-Item -LiteralPath $Destination).Length
    } else { 0 }

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

    # Build curl arguments
    $arguments = @(
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--retry", "3",
        "--retry-delay", "2",
        "--continue-at", "-",
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

    try {
        $previousErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $curl.Source @arguments
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousErrorPreference }

        if ($exitCode -ne 0) {
            # Exit 33/36 = server rejected resume offset
            if (($exitCode -eq 33 -or $exitCode -eq 36) -and $remoteSize -eq 0) {
                Write-Host "  Server rejected resume offset; verifying what we have." -ForegroundColor Yellow
                return $true
            }
            Write-Host "  Download failed with exit code $exitCode. Partial data kept for retry." -ForegroundColor Red
            return $false
        }
        return $true
    }
    finally {
        if ($curlConfig) {
            Remove-Item -LiteralPath $curlConfig -Force -ErrorAction SilentlyContinue
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
        if (-not (Invoke-ResumableDownload -Source $Script:EngineUrl -Destination $archivePath -Label $Script:EngineLabel)) {
            Write-Host "  ERROR: Download failed for $Script:EngineArchive" -ForegroundColor Red
            Emit-Error "Download failed for $Script:EngineArchive"
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

        # Try 7z first (handles .tar.gz better), then fall back to Expand-Archive
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
            # Expand-Archive handles .gz: extract to .tar, then extract contents
            $tmpTar = [System.IO.Path]::GetTempFileName() + ".tar"
            Expand-Archive -LiteralPath $archivePath -DestinationPath (Split-Path $tmpTar -Parent) -Force
            # Rename the extracted .gz result to .tar if needed
            $extracted = Get-ChildItem -LiteralPath (Split-Path $tmpTar -Parent) | Select-Object -First 1
            if ($extracted) {
                $tmpTar = $extracted.FullName
            }
            Expand-Archive -LiteralPath $tmpTar -DestinationPath $Script:EngineDir -Force -ErrorAction SilentlyContinue
            # Flatten if needed
            $topLevel = Get-ChildItem -LiteralPath $Script:EngineDir -Directory | Select-Object -First 1
            if ($topLevel -and (Get-ChildItem -LiteralPath $Script:EngineDir).Count -eq 1) {
                Move-Item -LiteralPath (Join-Path $Script:EngineDir $topLevel.Name)/* `
                    -Destination $Script:EngineDir -Force
                Remove-Item -LiteralPath $topLevel.FullName -Recurse -Force
            }
            Remove-Item -LiteralPath $tmpTar -Force -ErrorAction SilentlyContinue
        }

        New-Item -ItemType File -LiteralPath (Engine-CompletionMarker) -Force | Out-Null
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        Write-Host "  Unpack complete."
    }

    # Create/update the "current" symlink (PowerShell junction or directory symlink)
    if (Test-Path -LiteralPath $Script:CurrentLink) {
        Remove-Item -LiteralPath $Script:CurrentLink -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  Pointing $Script:CurrentLink at $Script:EngineDir..."
    New-Item -ItemType SymbolicLink -Path $Script:CurrentLink -Target $Script:EngineDir -Force | Out-Null
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
    return (Test-Path -LiteralPath (Join-Path $Script:ModelsDir $ModelId) -PathType Container) -and
           (Test-Path -LiteralPath (Model-CompletionMarker $ModelId) -PathType Leaf)
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
    if (-not (Invoke-ResumableDownload -Source $downloadUrl -Destination $archivePath -Label $modelLabel)) {
        Write-Host "  ERROR: Download failed for $zipFile" -ForegroundColor Red
        Emit-Error "Download failed for $zipFile"
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

    Write-Host "  Extracting $zipFile..."
    Emit-Activity "extracting" $zipFile $modelLabel

    $modelDest = Join-Path $Script:ModelsDir $modelId
    Remove-Item -LiteralPath $modelDest -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $modelDest -Force | Out-Null

    $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($sevenZip) {
        & 7z.exe x -o$modelDest -y $archivePath | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ERROR: Extraction failed for $zipFile." -ForegroundColor Red
            exit 1
        }
        # Flatten if there's a single top-level directory
        $topLevel = Get-ChildItem -LiteralPath $modelDest -Directory | Select-Object -First 1
        if ($topLevel -and (Get-ChildItem -LiteralPath $modelDest).Count -eq 1) {
            Move-Item -LiteralPath (Join-Path $modelDest $topLevel.Name)/* `
                -Destination $modelDest -Force
            Remove-Item -LiteralPath $topLevel.FullName -Recurse -Force
        }
    }
    else {
        Expand-Archive -LiteralPath $archivePath -DestinationPath $modelDest -Force
        # Flatten
        $topLevel = Get-ChildItem -LiteralPath $modelDest -Directory | Select-Object -First 1
        if ($topLevel -and (Get-ChildItem -LiteralPath $modelDest).Count -eq 1) {
            Move-Item -LiteralPath (Join-Path $modelDest $topLevel.Name)/* `
                -Destination $modelDest -Force
            Remove-Item -LiteralPath $topLevel.FullName -Recurse -Force
        }
    }

    New-Item -ItemType File -LiteralPath (Model-CompletionMarker $modelId) -Force | Out-Null
    Write-Host "  Extraction complete." -ForegroundColor Green
}

# ============================================================
# Server config
# ============================================================

function Handle-ServerConfig {
    $serverConfig = Join-Path $Script:BaseDir "server-config.json"

    if (Test-Path -LiteralPath $serverConfig -PathType Leaf) {
        Write-Host "  Reusing existing server-config.json."
        return
    }

    # Generate auth token
    $keyBytes = New-Object byte[] 32
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($keyBytes)
    }
    finally {
        $random.Dispose()
    }
    $token = "sk-$([Convert]::ToBase64String($keyBytes))"
    Write-Host "  Auth token generated."

    $config = @{
        api_key = $token
        port    = $Script:EnginePort
    }
    Write-Host "  Writing server-config.json with api_key and port..."
    New-Item -ItemType Directory -Path (Split-Path $serverConfig -Parent) -Force | Out-Null
    $config | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $serverConfig -Encoding UTF8
    Write-Host "  server-config.json created with bearer auth and port."
}

# ============================================================
# Start engine
# ============================================================

function Test-EngineRunning {
    try {
        $processes = Get-Process -Name "serverctl", "junie*" -ErrorAction SilentlyContinue
        return $null -ne $processes
    }
    catch { return $false }
}

function Start-Engine {
    $serverConfig = Join-Path $Script:BaseDir "server-config.json"
    $authToken = (Get-Content -LiteralPath $serverConfig -Raw | ConvertFrom-Json).api_key

    $ctlPath = Join-Path $Script:EngineDir "serverctl.ps1"
    if (-not (Test-Path -LiteralPath $ctlPath -PathType Leaf)) {
        $ctlPath = Join-Path $Script:EngineDir "serverctl.sh"
        # If it's a .sh, we need WSL or Git Bash - warn and try
        if (-not (Test-Path -LiteralPath $ctlPath -PathType Leaf)) {
            Write-Host "  ERROR: serverctl.ps1 / serverctl.sh not found in $Script:EngineDir" -ForegroundColor Red
            Emit-Error "serverctl not found in $Script:EngineDir"
            return $false
        }
    }

    # Stop any running engine
    if (Test-EngineRunning) {
        Write-Host "  Stopping the running engine..."
        try {
            & $ctlPath stop 2>$null
        }
        catch { }
        $waited = 0
        while ($waited -lt 10 -and (Test-EngineRunning)) {
            Start-Sleep -Seconds 1
            $waited++
        }
    }

    Write-Host "  Starting the engine..."
    try {
        Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile", "-File", $ctlPath, "start" `
            -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "  WARNING: Could not start engine via serverctl." -ForegroundColor Yellow
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
$Script:CudaOk = $true
$Script:VcRedistOk = $true
$Script:VcRedistDisplay = "Installed"
$Script:VcRedistRequirement = ""
$Script:AllOk = $true

try {
    Assert-SupportedWindows
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}

$gpu = Get-NvidiaGpu
if (-not $Script:GpuOk) {
    $Script:AllOk = $false
}
if (-not $Script:CudaOk) {
    $Script:AllOk = $false
}

Assert-VisualCppRuntime
if (-not $Script:VcRedistOk) {
    $Script:AllOk = $false
}

Get-SystemRam
$ramOk = $Script:MemGb -ge 40
$ramWarn = $Script:MemGb -ge 40 -and $Script:MemGb -lt 60
if (-not $ramOk) {
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

Print-Value "CUDA:" "$Script:CudaDisplay" $Script:CudaOk $false "$Script:CudaRequirement"
Emit-Check "cuda" (Check-Status $Script:CudaOk $false) "$Script:CudaDisplay" "$Script:CudaRequirement"

Print-Value "VC++ Redist:" "$Script:VcRedistDisplay" $Script:VcRedistOk $false "$Script:VcRedistRequirement"
Emit-Check "vc_redist" (Check-Status $Script:VcRedistOk $false) "$Script:VcRedistDisplay" "$Script:VcRedistRequirement"

Print-Value "RAM:" "$($Script:MemGb) GB" $ramOk $ramWarn "minimum 40 GB, 60 GB recommended"
Emit-Check "ram" (Check-Status $ramOk $ramWarn) "$($Script:MemGb) GB" "minimum 40 GB, 60 GB recommended"

# Config event
Emit-Event "event:`"config`",port:$Script:EnginePort,ram_gb:$Script:EngineRamGb,engine_version:`"$(Json-Escape $Script:EngineVersion)`",model:`"$(Json-Escape $Model)`",checks_passed:$($Script:AllOk.ToString().ToLowerInvariant())"

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
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
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
Write-Host "  Installing the inference engine" -ForegroundColor Green
Write-Host "  --------------------------------" -ForegroundColor DarkGray
Write-Host ""
Emit-StepStart "engine" "Installing the inference engine"
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
Handle-ServerConfig

# Generate Junie model config via serverctl
$ctlPath = Join-Path $Script:EngineDir "serverctl.ps1"
if (-not (Test-Path -LiteralPath $ctlPath)) {
    $ctlPath = Join-Path $Script:EngineDir "serverctl.sh"
}
if (Test-Path -LiteralPath $ctlPath) {
    try {
        & $ctlPath --junie-config $Script:JunieHome --model $Model 2>$null
    }
    catch {
        Write-Host "  WARNING: Failed to generate Junie config via serverctl." -ForegroundColor Yellow
    }
}
else {
    Write-Host "  WARNING: serverctl.ps1 not found. Skipping Junie config generation." -ForegroundColor Yellow
}
Emit-StepDone "configure"

# --- Step 4: Start the inference engine ---
Write-Host ""
Write-Host "  Starting the inference engine" -ForegroundColor Green
Write-Host "  ------------------------------" -ForegroundColor DarkGray
Write-Host ""
Emit-StepStart "start" "Starting the inference engine"
Start-Engine | Out-Null
Emit-StepDone "start"

# --- Summary ---
$mainModelId = Get-ArchiveField -ArchiveIndex 0 -Field "modelId"
$mainLabel = Get-ArchiveField -ArchiveIndex 0 -Field "label"

Write-Host ""
Write-Host "  Installation complete" -ForegroundColor Green
Write-Host "  ---------------------" -ForegroundColor DarkGray
Write-Host ""

Print-Value "Engine:" "$Script:EngineDir" $true $false ""
Print-Value "Current:" "$Script:CurrentLink -> $Script:EngineDir" $true $false ""
Print-Value "Models:" "$Script:ModelsDir" $true $false ""
Print-Value "Logs:" "$Script:BaseDir" $true $false ""
Print-Value "Junie config:" "$Script:JunieHome\models\$Script:JunieModelId.json" $true $false ""
Print-Value "Default model:" "$Script:JunieModelId" $true $false ""

Write-Host ""
Write-Host "  The engine serves http://localhost:$Script:EnginePort - the first request has to wait"
Write-Host "  for the model to load."
Write-Host "  Control the engine with: $Script:EngineCtl {start|stop|status|wait}"

Emit-Event "event:`"done`",model_id:`"$Script:JunieModelId`",port:$Script:EnginePort,model_path:`"$(Json-Escape "$Script:ModelsDir/$mainModelId")`",label:`"$(Json-Escape "$mainLabel")`""

Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
exit 0
