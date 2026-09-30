# Run with powershell.exe or pwsh -NoProfile -File tests/local_windows_engine_start.ps1.
$ErrorActionPreference = 'Stop'
$source = Get-Content -Raw (Join-Path $PSScriptRoot '../local/install.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ("junie engine " + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    Set-Content (Join-Path $temp 'server-config.json') '{"api_key":"test-token"}'
    Set-Content (Join-Path $temp 'serverctl.ps1') ''
    & {
        $Script:BaseDir = $temp
        $Script:EngineDir = $temp
        $Script:EnginePort = 19239
        $expectedHost = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
        $script:launchCount = 0
        function Get-Command { throw 'Startup must not resolve a PowerShell Store alias from PATH' }
        function Test-EngineRunning { return $false }
        function Start-Process {
            param($FilePath, $ArgumentList, $WindowStyle)
            if ($FilePath -ne $expectedHost) { throw "Wrong PowerShell host: $FilePath" }
            if ($ArgumentList[-2] -ne "`"$(Join-Path $temp 'serverctl.ps1')`"" -or $ArgumentList[-1] -ne 'start') {
                throw 'Controller path containing spaces must be quoted'
            }
            $script:launchCount++
        }
        function Invoke-WebRequest { return @{ Content = '{"phase":"ready"}' } }
        foreach ($name in @('Get-JsonField', 'Start-Engine')) {
            $definition = [regex]::Match($source, "(?ms)^function $name \{.*?^\}")
            if (-not $definition.Success) { throw "Missing function: $name" }
            Invoke-Expression $definition.Value
        }
        if (-not (Start-Engine) -or $script:launchCount -ne 1) { throw 'Engine startup did not succeed' }
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Host 'PASS: engine startup uses the current PowerShell and quotes the controller path'
