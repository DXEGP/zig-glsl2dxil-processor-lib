param(
    [string]$Dxc = $env:DXC,
    [string]$DxcInclude,
    [switch]$SkipHardware
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $root

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}

function Get-PeImports {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550) { throw "not a PE image: $Path" }
    $sectionCount = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optionalSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $optional = $pe + 24
    if ([BitConverter]::ToUInt16($bytes, $optional) -ne 0x20b) { throw 'expected PE32+ image' }
    $importRva = [BitConverter]::ToUInt32($bytes, $optional + 120)
    if ($importRva -eq 0) { return }
    $sections = for ($index = 0; $index -lt $sectionCount; $index++) {
        $section = $optional + $optionalSize + $index * 40
        [PSCustomObject]@{
            rva = [BitConverter]::ToUInt32($bytes, $section + 12)
            size = [Math]::Max([BitConverter]::ToUInt32($bytes, $section + 8), [BitConverter]::ToUInt32($bytes, $section + 16))
            offset = [BitConverter]::ToUInt32($bytes, $section + 20)
        }
    }
    $importSection = $sections | Where-Object { $importRva -ge $_.rva -and $importRva -lt $_.rva + $_.size } | Select-Object -First 1
    if (-not $importSection) { throw 'invalid PE import directory' }
    $descriptor = $importSection.offset + $importRva - $importSection.rva
    while ($descriptor + 20 -le $bytes.Length) {
        $nameRva = [BitConverter]::ToUInt32($bytes, $descriptor + 12)
        if ($nameRva -eq 0) { break }
        $nameSection = $sections | Where-Object { $nameRva -ge $_.rva -and $nameRva -lt $_.rva + $_.size } | Select-Object -First 1
        if (-not $nameSection) { throw 'invalid PE import name' }
        $nameOffset = $nameSection.offset + $nameRva - $nameSection.rva
        $end = $nameOffset
        while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
        if ($end -eq $bytes.Length) { throw 'unterminated PE import name' }
        [Text.Encoding]::ASCII.GetString($bytes, $nameOffset, $end - $nameOffset)
        $descriptor += 20
    }
}

try {
    $baseline = Get-Content -LiteralPath tests/dxil/baseline.json -Raw | ConvertFrom-Json
    $zigVersion = (& zig version).Trim()
    if ($zigVersion -ne $baseline.zig) { throw "expected Zig $($baseline.zig), found $zigVersion" }
    if (-not $Dxc) { $Dxc = (Get-Command dxc.exe -ErrorAction Stop).Source }
    $Dxc = (Resolve-Path -LiteralPath $Dxc).Path
    $compilerDirectory = Split-Path -Parent $Dxc
    $compilerDll = Join-Path $compilerDirectory 'dxcompiler.dll'
    if (-not (Test-Path -LiteralPath $compilerDll)) { throw "missing $compilerDll" }
    if (-not $DxcInclude) {
        $DxcInclude = Join-Path (Split-Path -Parent $compilerDirectory) 'Include/dxc'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $DxcInclude 'dxcapi.h'))) {
        throw 'pass -DxcInclude pointing to the directory containing dxcapi.h'
    }
    $cacheDirectory = Join-Path $root '.zig-cache/dxil-reference'
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    $hashSource = Join-Path $cacheDirectory 'DxilHash.cpp'
    if (-not (Test-Path -LiteralPath $hashSource)) {
        $commit = $baseline.references.DirectXShaderCompiler
        $path = $baseline.hashReference.path
        $response = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/DirectXShaderCompiler/contents/${path}?ref=$commit"
        [IO.File]::WriteAllBytes($hashSource, [Convert]::FromBase64String($response.content))
    }
    if ((Get-FileHash -LiteralPath $hashSource -Algorithm SHA256).Hash -ne $baseline.hashReference.sha256) {
        throw 'cached upstream hash reference does not match the pinned SHA256'
    }

    Invoke-Checked zig @('build', 'test', 'c-test', 'cpp-test', 'dxil-c-test', 'dxil-fixtures', 'dxil-source-fixtures', '-Doptimize=ReleaseSafe', '--summary', 'all')
    Invoke-Checked zig @('build', '-Doptimize=ReleaseSafe')
    Invoke-Checked zig @('build', '-Dshared=true', '-Doptimize=ReleaseSafe', '--prefix', 'zig-out/dxil-shared')
    $output = Join-Path $root 'zig-out/dxil'
    $benchmark = & zig build dxil-bench -Doptimize=ReleaseSafe
    if ($LASTEXITCODE -ne 0) { throw 'DXIL emission benchmark failed' }
    $benchmark | Write-Output
    [IO.File]::WriteAllLines((Join-Path $output 'benchmark.txt'), [string[]]$benchmark)
    $sourceBenchmark = & zig build dxil-source-bench -Doptimize=ReleaseSafe
    if ($LASTEXITCODE -ne 0) { throw 'paired source benchmark failed' }
    $sourceBenchmark | Write-Output
    [IO.File]::WriteAllLines((Join-Path $output 'source-benchmark.txt'), [string[]]$sourceBenchmark)
    $validator = Join-Path $output 'dxil-validate.exe'
    $renderer = Join-Path $output 'dxil-render.exe'
    $sourceRenderer = Join-Path $output 'dxil-source-render.exe'
    Invoke-Checked zig @('c++', 'tests/dxil/validate.cpp', $hashSource, '-std=c++23', '-fms-extensions', '-Wall', '-Wextra', '-Werror', '-isystem', $DxcInclude, '-lole32', '-O2', '-o', $validator)
    Invoke-Checked zig @('c++', 'tests/dxil/render.cpp', '-std=c++23', '-fms-extensions', '-Wall', '-Wextra', '-Werror', '-ld3d12', '-ldxgi', '-ldxguid', '-O2', '-o', $renderer)
    Invoke-Checked zig @('c++', 'tests/dxil/source_render.cpp', 'zig-out/lib/glsl2hlsl.lib', '-Iinclude', '-std=c++23', '-fms-extensions', '-Wall', '-Wextra', '-Werror', '-ld3d12', '-ldxgi', '-ldxguid', '-O2', '-o', $sourceRenderer)
    $library = Get-ChildItem -LiteralPath (Join-Path $root 'zig-out/dxil-shared') -Filter '*glsl2hlsl*.dll' -Recurse -File | Select-Object -First 1
    if (-not $library) { throw 'shared library missing' }
    $imports = @{}
    foreach ($image in @($library.FullName, $renderer, $sourceRenderer)) {
        $names = @(Get-PeImports $image)
        if ($names | Where-Object { $_ -match '(?i)dxcompiler|dxil|llvm|clang|mesa' }) { throw "compiler dependency imported by $image" }
        $imports[(Split-Path -Leaf $image)] = $names
    }
    $vertex = Join-Path $output 'passthrough.vert.dxil'
    $fragment = Join-Path $output 'constant.frag.dxil'
    $alternate = Join-Path $output 'alternate.frag.dxil'
    $referenceVertex = Join-Path $output 'reference.vert.dxil'
    $referenceFragment = Join-Path $output 'reference.frag.dxil'
    Invoke-Checked $Dxc @('-T', 'vs_6_5', '-E', 'main', '-validator-version', '1.5', '-Fo', $referenceVertex, '-Fc', (Join-Path $output 'reference.vert.ll'), 'tests/dxil/reference.vert.hlsl')
    Invoke-Checked $Dxc @('-T', 'ps_6_5', '-E', 'main', '-validator-version', '1.5', '-Fo', $referenceFragment, '-Fc', (Join-Path $output 'reference.frag.ll'), 'tests/dxil/reference.frag.hlsl')
    Invoke-Checked $Dxc @('-T', 'vs_6_5', '-E', 'main', '-validator-version', '1.5', '-Fo', (Join-Path $output 'm2/reference-coordinates.vert.dxil'), 'tests/dxil/coordinates.vert.hlsl')
    Invoke-Checked $Dxc @('-T', 'ps_6_5', '-E', 'main', '-validator-version', '1.5', '-Fo', (Join-Path $output 'm2/reference-coordinates.frag.dxil'), 'tests/dxil/coordinates.frag.hlsl')
    $validationOutput = & $validator $compilerDll (Join-Path $output 'retail-vectors.bin') $vertex $fragment $alternate
    if ($LASTEXITCODE -ne 0) { throw 'official validation failed' }
    $validationOutput | Write-Output
    [IO.File]::WriteAllLines((Join-Path $output 'validation.txt'), [string[]]$validationOutput)
    foreach ($shader in @($vertex, $fragment)) {
        $listing = & $Dxc -dumpbin $shader
        if ($LASTEXITCODE -ne 0) { throw "disassembly failed: $shader" }
        [IO.File]::WriteAllLines("$shader.ll", [string[]]$listing)
    }
    $mode = Get-ItemProperty -LiteralPath HKLM:/SOFTWARE/Microsoft/Windows/CurrentVersion/AppModelUnlock -ErrorAction SilentlyContinue
    $developerMode = $null -ne $mode -and $mode.AllowDevelopmentWithoutDevLicense -eq 1
    if (-not $SkipHardware) {
        if ($developerMode) { throw 'M1 retail acceptance requires Windows Developer Mode to be disabled; the script does not change it' }
        $renderOutput = & $renderer $vertex $fragment $alternate
        if ($LASTEXITCODE -ne 0) { throw 'D3D12 hardware acceptance failed' }
        $renderOutput | Write-Output
        [IO.File]::WriteAllLines((Join-Path $output 'render.txt'), [string[]]$renderOutput)
        $referenceOutput = & $renderer $referenceVertex $referenceFragment $alternate
        if ($LASTEXITCODE -ne 0) { throw 'DXC reference rendering failed' }
        [IO.File]::WriteAllLines((Join-Path $output 'reference-render.txt'), [string[]]$referenceOutput)
        $sourceOutput = & $sourceRenderer
        $sourceStatus = $LASTEXITCODE
        $sourceOutput | Write-Output
        if ($sourceStatus -ne 0) { throw 'M2 source hardware acceptance failed' }
        [IO.File]::WriteAllLines((Join-Path $output 'source-render.txt'), [string[]]$sourceOutput)
        $coordinateReference = & $sourceRenderer --reference
        $referenceStatus = $LASTEXITCODE
        $coordinateReference | Write-Output
        if ($referenceStatus -ne 0) { throw 'independent HLSL coordinate reference failed' }
        [IO.File]::WriteAllLines((Join-Path $output 'reference-source-render.txt'), [string[]]$coordinateReference)
    }
    $sourceShaders = @(Get-ChildItem -LiteralPath (Join-Path $output 'm2') -Filter '*.dxil' -File | Sort-Object Name)
    $sourceValidation = & $validator $compilerDll (Join-Path $output 'retail-vectors.bin') @($sourceShaders.FullName)
    $sourceValidation | Write-Output
    if ($LASTEXITCODE -ne 0) { throw 'M2 official validation failed' }
    [IO.File]::WriteAllLines((Join-Path $output 'source-validation.txt'), [string[]]$sourceValidation)
    $report = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        zig = $zigVersion
        dxc = (& $Dxc --version | Out-String).Trim()
        dxcSha256 = (Get-FileHash -LiteralPath $Dxc -Algorithm SHA256).Hash
        dxcompilerSha256 = (Get-FileHash -LiteralPath $compilerDll -Algorithm SHA256).Hash
        hashReferenceSha256 = $baseline.hashReference.sha256
        developerMode = $developerMode
        hardware = if ($SkipHardware) { 'not run; M1 acceptance incomplete' } else { 'passed' }
        benchmark = @($benchmark)
        sourceBenchmark = @($sourceBenchmark)
        m2 = [ordered]@{
            corpusFiles = 10
            pairedCorpusScenarios = 9
            validatedBinaries = $sourceShaders.Count
            coordinateCombinationsPerAdapter = if ($SkipHardware) { 0 } else { 96 }
            hardware = if ($SkipHardware) { 'not run; M2 acceptance incomplete' } else { 'passed with independent CPU and HLSL coordinate oracles' }
            artifacts = @($sourceShaders | Get-FileHash -Algorithm SHA256 | Select-Object Path, Hash)
        }
        peImports = $imports
        os = [Environment]::OSVersion.VersionString
        adapters = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion)
        fixtures = @(Get-FileHash -LiteralPath $vertex, $fragment, $alternate, $referenceVertex, $referenceFragment -Algorithm SHA256 | Select-Object Path, Hash)
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'report.json') -Encoding utf8
    if ($SkipHardware) { Write-Warning 'hardware skipped; M1/M2 are not fully accepted' }
    Write-Output "DXIL report: $output/report.json"
} finally {
    Pop-Location
}
