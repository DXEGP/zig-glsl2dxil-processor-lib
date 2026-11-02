param(
    [string]$Dxc = 'C:/Program Files/Khronos Group/Vulkan SDK/Bin/dxc.exe',
    [switch]$SkipHardware
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $root
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
try {
    & "$PSScriptRoot/m4_inputs.ps1"
    & "$PSScriptRoot/run.ps1" -Dxc $Dxc -SkipHardware:$SkipHardware
    Invoke-Checked zig @('build', 'dxil-m4', 'dxil-m4-bench', '-Doptimize=ReleaseSafe')
    Invoke-Checked pwsh @('-NoProfile', '-File', 'tests/run.ps1', '-Dxc', $Dxc)
    $support = Get-Content -LiteralPath zig-out/m4/support.json -Raw | ConvertFrom-Json
    $validator = Join-Path $root 'zig-out/dxil/dxil-validate.exe'
    $compilerDll = Join-Path (Split-Path -Parent $Dxc) 'dxcompiler.dll'
    $validation = @()
    for ($offset = 0; $offset -lt $support.artifacts.Count; $offset += 20) {
        $last = [Math]::Min($offset + 19, $support.artifacts.Count - 1)
        $batch = @($support.artifacts[$offset..$last])
        $lines = & $validator $compilerDll 'zig-out/dxil/retail-vectors.bin' @batch
        $validation += $lines
        if ($LASTEXITCODE -ne 0) { $lines | Write-Output; throw 'M4 official validation failed' }
    }
    $validation | Set-Content -LiteralPath zig-out/m4/validation.txt
    $hardware = @()
    if (!$SkipHardware) {
        $hardware = & zig-out/dxil/dxil-source-render.exe --m4
        $rendererStatus = $LASTEXITCODE
        $hardware | Set-Content -LiteralPath zig-out/m4/render.txt
        if ($rendererStatus -ne 0) { $hardware | Select-Object -Last 20 | Write-Output; throw 'M4 GPU comparison failed' }
        $hardware | Where-Object { $_ -match 'adapter=|m4_|source_hardware|sm69=' } | Write-Output
    }
    $inputs = Get-Content -LiteralPath zig-out/m4/inputs.json -Raw | ConvertFrom-Json
    $pso = @($hardware | Where-Object { $_ -match '^passed=minecraft-' } | ForEach-Object {
        if ($_ -match '^passed=(\S+).*pso_us=(\d+)') { @{ scene = $Matches[1]; microseconds = [long]$Matches[2] } }
    })
    $report = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        gitHead = (& git rev-parse HEAD)
        workingTree = @(& git status --short)
        zig = (& zig version)
        optimize = 'ReleaseSafe'
        dxc = (& $Dxc --version | Out-String).Trim()
        dxcSha256 = (Get-FileHash -LiteralPath $Dxc -Algorithm SHA256).Hash
        dxcompilerSha256 = (Get-FileHash -LiteralPath $compilerDll -Algorithm SHA256).Hash
        os = [Environment]::OSVersion.VersionString
        cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
        adapters = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion)
        packages = @($inputs.packages | Select-Object name, sha256)
        macroConfiguration = $support.macro_configuration
        supportedPairs = @($support.records | Where-Object compiled | Group-Object package | Select-Object Name, Count)
        emptyOutputPairs = @($support.records | Where-Object { $_.compiled -and $_.empty_output } | Select-Object package, vertex)
        unsupportedStages = $support.unsupported_stages.Count
        validatedBinaries = $support.artifacts.Count
        signatureNegatives = @($validation | Where-Object { $_ -eq 'rejected inconsistent output signature' }).Count
        hardware = if ($SkipHardware) { 'not run; partial acceptance' } else { 'passed; 16x16 CPU color/fog/depth oracle and optimized/unoptimized comparisons; both hardware adapters; SM6.9 on supported device' }
        pso = $pso
        driverCache = 'uncontrolled OS/driver cache; sequential PSO calls; not cold-driver timing'
        artifacts = @($support.artifacts | ForEach-Object { Get-FileHash -LiteralPath $_ -Algorithm SHA256 | Select-Object Path, Hash })
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath zig-out/m4/report.json -Encoding utf8NoBOM
    Write-Output "M4 report: zig-out/m4/report.json; validated binaries: $($report.validatedBinaries)"
} finally { Pop-Location }
