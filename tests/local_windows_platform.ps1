# Run with powershell.exe or pwsh -NoProfile -File tests/local_windows_platform.ps1.
$ErrorActionPreference = 'Stop'
$source = Get-Content -Raw (Join-Path $PSScriptRoot '../local/install.ps1')
$function = [regex]::Match($source, '(?ms)^function Get-NativeWindowsPlatform \{.*?^\}')
if (-not $function.Success) { throw 'Get-NativeWindowsPlatform not found' }
$probe = '[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()'
if (-not $function.Value.Contains($probe)) { throw 'OS architecture probe not found' }

$previousArchitecture = $env:PROCESSOR_ARCHITECTURE
$previousNativeArchitecture = $env:PROCESSOR_ARCHITEW6432
try {
    # An emulated shell must still select the native OS architecture.
    $env:PROCESSOR_ARCHITECTURE = 'x86'
    $env:PROCESSOR_ARCHITEW6432 = 'AMD64'
    foreach ($architecture in @('ARM64', 'AARCH64', 'X64', 'AMD64', 'X86_64', 'X86')) {
        Invoke-Expression $function.Value.Replace($probe, "'$architecture'")
        $actual = try { Get-NativeWindowsPlatform } catch { 'unsupported' }
        $expected = if ($architecture -in 'ARM64', 'AARCH64') { 'windows-aarch64' }
                    elseif ($architecture -eq 'X86') { 'unsupported' }
                    else { 'windows-amd64' }
        if ($actual -ne $expected) { throw "$architecture returned $actual; expected $expected" }
    }

    # Exercise the fallback used when RuntimeInformation is unavailable.
    Invoke-Expression $function.Value.Replace($probe, "`$(throw 'RuntimeInformation unavailable')")
    foreach ($case in @(
        @('ARM64', 'AMD64', 'windows-aarch64'),
        @('AMD64', 'x86', 'windows-amd64'),
        @('', 'ARM64', 'windows-aarch64'),
        @('', 'AMD64', 'windows-amd64'),
        @('', 'x86', 'unsupported')
    )) {
        $env:PROCESSOR_ARCHITEW6432 = $case[0]
        $env:PROCESSOR_ARCHITECTURE = $case[1]
        $actual = try { Get-NativeWindowsPlatform } catch { 'unsupported' }
        if ($actual -ne $case[2]) { throw "Fallback for $case returned $actual" }
    }
} finally {
    $env:PROCESSOR_ARCHITECTURE = $previousArchitecture
    $env:PROCESSOR_ARCHITEW6432 = $previousNativeArchitecture
}
Write-Host 'PASS: 11 Windows platform detection cases'
