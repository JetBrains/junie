# Exercise the installer's GPU check without requiring NVIDIA hardware.
# Run: pwsh -NoProfile -File tests/local_gpu_capacity.ps1
$ErrorActionPreference = 'Stop'
$source = Get-Content -Raw -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'local/install.ps1')
$match = [regex]::Match($source, '(?ms)^function Get-NvidiaGpu \{.*?^\}')
if (-not $match.Success) { throw 'GPU-check function not found' }
Invoke-Expression $match.Value
function Get-Command {
    param([string]$Name, [string]$ErrorAction)
    if ($Name -ne 'nvidia-smi') { throw "Unexpected command: $Name" }
    return [PSCustomObject]@{ Source = {
        $script:LASTEXITCODE = 0
        if ($args.Count) {
            "NVIDIA GeForce RTX 4090, 595.79, $script:TestMemoryMiB, 8.9"
        } else {
            "CUDA Version: $script:TestCudaMajor.0"
        }
    } }
}
$cases = @(
    @{ MiB = 24564; Cuda = 13; Expected = $true },
    @{ MiB = 24576; Cuda = 13; Expected = $true },
    @{ MiB = 32768; Cuda = 13; Expected = $true },
    @{ MiB = 24320; Cuda = 13; Expected = $true },
    @{ MiB = 24319; Cuda = 13; Expected = $false },
    @{ MiB = 16384; Cuda = 13; Expected = $false },
    @{ MiB = 24564; Cuda = 11; Expected = $false }
)
foreach ($case in $cases) {
    $script:TestMemoryMiB = $case.MiB
    $script:TestCudaMajor = $case.Cuda
    $gpu = Get-NvidiaGpu
    if ($Script:GpuOk -ne $case.Expected) { throw "Wrong result for $($case.MiB) MiB / CUDA $($case.Cuda)" }
    if ($case.MiB -eq 24564 -and $Script:AccelDisplay -notmatch '23\.99 GiB VRAM, 24564 MiB reported') {
        throw "Misleading capacity display: $Script:AccelDisplay"
    }
}
Write-Output "PASS: $($cases.Count) GPU capacity/CUDA cases, including reported RTX 4090 capacity."
