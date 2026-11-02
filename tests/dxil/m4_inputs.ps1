param([string]$MinecraftClient = 'zig-out/m4/minecraft-1.21.4.jar')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $root
try {
    New-Item -ItemType Directory -Path zig-out/m4 -Force | Out-Null
    if (!(Test-Path -LiteralPath $MinecraftClient)) {
        Invoke-WebRequest 'https://piston-data.mojang.com/v1/objects/a7e5a6024bfd3cd614625aa05629adf760020304/client.jar' -OutFile $MinecraftClient
    }
    if ((Get-FileHash -LiteralPath $MinecraftClient -Algorithm SHA1).Hash -ne 'A7E5A6024BFD3CD614625AA05629ADF760020304') { throw 'Minecraft 1.21.4 client hash mismatch' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $inputs = @(
        @{ name = 'minecraft-1.21.4'; path = $MinecraftClient; prefix = ''; expected = '' },
        @{ name = 'complementary-unbound-5.8.1'; path = 'example_shaderpack/ComplementaryUnbound_r5.8.1.zip'; prefix = 'shaders/'; expected = 'BB89B1FC54687D4147A837FB2E3C3F7261A13BEE51819761E9B6A91CB7915965' },
        @{ name = 'iterationRP-0.8.31'; path = 'example_shaderpack/iterationRP Alpha 0.8.31.zip'; prefix = 'shaders/'; expected = '334D0B0DADB5E2B927B992F2B93596C4CC1A518305C1E2A9B175C754A4D946E8' }
    )
    $packages = @()
    foreach ($input in $inputs) {
        if (!(Test-Path -LiteralPath $input.path)) { throw "Missing local shader pack: $($input.path)" }
        $hash = (Get-FileHash -LiteralPath $input.path -Algorithm SHA256).Hash
        if ($input.expected -and $hash -ne $input.expected) { throw "Shader pack hash mismatch: $($input.name)" }
        $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($input.path))
        try {
            $files = @()
            foreach ($entry in $archive.Entries | Sort-Object FullName) {
                if ($entry.FullName -notmatch '\.(glsl|vsh|fsh|csh|gsh|tcs|tes)$') { continue }
                if (!$entry.FullName.StartsWith($input.prefix, [StringComparison]::Ordinal)) { continue }
                if ($entry.Length -gt 1MB) { throw "Oversized shader entry: $($entry.FullName)" }
                $reader = [IO.StreamReader]::new($entry.Open())
                try { $source = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $files += @{ name = $entry.FullName.Substring($input.prefix.Length); source = $source }
                if ($input.name -eq 'minecraft-1.21.4') {
                    $destination = [IO.Path]::GetFullPath((Join-Path 'zig-out/m4/minecraft' $entry.FullName))
                    $destinationRoot = [IO.Path]::GetFullPath('zig-out/m4/minecraft') + [IO.Path]::DirectorySeparatorChar
                    if (!$destination.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid shader archive path' }
                    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
                    [IO.File]::WriteAllText($destination, $source)
                }
                if ($input.name -eq 'iterationRP-0.8.31' -and $entry.FullName.Substring($input.prefix.Length) -in @('composite45.vsh', 'composite45.fsh', 'Lib/Programs/Discard_VS.glsl', 'Lib/Programs/Discard_FS.glsl')) {
                    $destination = Join-Path 'zig-out/m4/iteration-runtime' $entry.FullName.Substring($input.prefix.Length)
                    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
                    [IO.File]::WriteAllText($destination, $source)
                }
            }
            $packages += @{ name = $input.name; sha256 = $hash; files = $files }
        } finally { $archive.Dispose() }
    }
    @{ packages = $packages } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath zig-out/m4/inputs.json -Encoding utf8NoBOM
    Write-Output 'Pinned, unchanged shader sources prepared in zig-out/m4/inputs.json'
} finally { Pop-Location }
