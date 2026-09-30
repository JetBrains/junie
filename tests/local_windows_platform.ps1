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
    foreach ($architecture in @('ARM64', 'AARCH64', 'X64', 'AMD64', 'X86_64', 'X86', '')) {
        Invoke-Expression $function.Value.Replace($probe, "'$architecture'")
        $actual = Get-NativeWindowsPlatform
        $expected = if ($architecture -in 'ARM64', 'AARCH64') { 'windows-aarch64' }
                    elseif ($architecture -eq 'X86') { 'windows-x86' }
                    elseif (-not $architecture) { 'windows-unknown' }
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
        @('', 'x86', 'windows-x86'),
        @('', '', 'windows-unknown')
    )) {
        $env:PROCESSOR_ARCHITEW6432 = $case[0]
        $env:PROCESSOR_ARCHITECTURE = $case[1]
        $actual = Get-NativeWindowsPlatform
        if ($actual -ne $case[2]) { throw "Fallback for $case returned $actual" }
    }
} finally {
    $env:PROCESSOR_ARCHITECTURE = $previousArchitecture
    $env:PROCESSOR_ARCHITEW6432 = $previousNativeArchitecture
}
Write-Host 'PASS: 13 Windows platform detection cases'

# Run the installer as a child process to verify the protocol Junie receives.
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $shell = (Get-Process -Id $PID).Path
    foreach ($architecture in @('X86', '', 'X64', 'ARM64')) {
        $supported = $architecture -in 'X64', 'ARM64'
        $modes = if ($supported) { @('--check-only') } else { @('--check-only', '--models', '') }
        foreach ($mode in $modes) {
            $script = Join-Path $temp 'install.ps1'
            $variant = $source.Replace($probe, "'$architecture'")
            $variant = "function Invoke-WebRequest { throw 'Unexpected network access' }`n" + $variant
            [IO.File]::WriteAllText($script, $variant, [Text.UTF8Encoding]::new($true))
            $stdout = Join-Path $temp 'stdout.txt'
            $stderr = Join-Path $temp 'stderr.txt'
            $arguments = @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', "`"$script`"", '--json'
            )
            if ($mode) { $arguments += $mode }
            $process = Start-Process -FilePath $shell -ArgumentList $arguments `
                -RedirectStandardOutput $stdout -RedirectStandardError $stderr -Wait -PassThru
            $events = @(Get-Content $stdout | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
            $hello = @($events | Where-Object { $_.event -eq 'hello' })
            $os = @($events | Where-Object { $_.event -eq 'check' -and $_.name -eq 'os' })
            $config = @($events | Where-Object { $_.event -eq 'config' })
            if ($hello.Count -ne 1 -or $hello[0].protocol -ne 1 -or $os.Count -ne 1 -or $config.Count -ne 1) {
                throw "Missing requirements protocol for '$architecture' $mode`: $(Get-Content $stdout -Raw) $(Get-Content $stderr -Raw)"
            }
            if ($supported) {
                if ($os[0].status -ne 'ok') { throw "Supported architecture failed OS check: $architecture" }
            } else {
                $display = if ($architecture) { 'x86' } else { 'unknown' }
                if ($process.ExitCode -ne 1 -or $os[0].status -ne 'fail' -or $config[0].checks_passed -ne $false) {
                    throw "Unsupported architecture did not report failed requirements: '$architecture' $mode"
                }
                if ($os[0].value -notmatch $display -or $os[0].requirement -notmatch 'x64 or ARM64') {
                    throw 'OS check must explain the detected and required architecture'
                }
            }
            if (@($events | Where-Object { $_.event -in 'step_start', 'models', 'done' }).Count) {
                throw 'Requirements check continued into model listing or installation'
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Host 'PASS: 8 installer requirements protocol cases'

foreach ($channel in @('main', 'eap')) {
    $entries = @(Get-Content (Join-Path $PSScriptRoot "../local/update-info-models-$channel.jsonl") | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($id in @('Qwen3.6-27B-Q4_K_M', 'Qwen3.8-3.6-27B-blend-Q4_K_M')) {
        if (@($entries | Where-Object { $_.platform -eq 'windows-aarch64' -and $_.id -eq $id }).Count -ne 1) {
            throw "Expected one ARM64 entry for $id in $channel"
        }
        if (-not (Test-Path (Join-Path $PSScriptRoot "../local/models/$id.json"))) {
            throw "Missing model metadata for $id"
        }
    }
}
Write-Host 'PASS: ARM64 model entries in main and eap'
