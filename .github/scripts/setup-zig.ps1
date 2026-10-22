# Installs the pinned Zig toolchain on a Windows runner (x86_64 or ARM64).
#
#   setup-zig.ps1 [-Pin .github/zig-toolchain.txt] [-Dest "$env:RUNNER_TOOL_CACHE\zig"] [-Arch x86_64|aarch64]
#
# -Arch overrides the runner's architecture (default: PROCESSOR_ARCHITECTURE).
#
# Tries the community mirrors in shuffled order, then ziglang.org, checks the
# archive's SHA-256 against the pin before extracting, and appends the zig
# directory to $env:GITHUB_PATH (and ZIG_VERSION to $env:GITHUB_ENV) when set.
# An extracted toolchain already in -Dest is reused after `zig version`
# matches the pin.
#
# Exit codes: 0 ok, 10 hash mismatch, 11 all sources failed, 12 unsupported
# arch or missing pin entry. Requires PowerShell 7.
param(
    [string]$Pin = ".github/zig-toolchain.txt",
    [string]$Dest = $(if ($env:RUNNER_TOOL_CACHE) { Join-Path $env:RUNNER_TOOL_CACHE "zig" } else { Join-Path $env:LOCALAPPDATA "zig-toolchain" }),
    [ValidateSet("", "x86_64", "aarch64")][string]$Arch = ""
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProgressPreference = "SilentlyContinue"

$mirrorsUrl = if ($env:ZIGGURO_MIRRORS_URL) { $env:ZIGGURO_MIRRORS_URL } else { "https://ziglang.org/download/community-mirrors.txt" }
$fallback = if ($env:ZIGGURO_FALLBACK_URL) { $env:ZIGGURO_FALLBACK_URL } else { "https://ziglang.org/download" }

if ($Arch) { $arch = $Arch } else {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { $arch = "x86_64" }
        "ARM64" { $arch = "aarch64" }
        default { Write-Error "setup-zig: unsupported architecture $($env:PROCESSOR_ARCHITECTURE)" -ErrorAction Continue; exit 12 }
    }
}
$triple = "$arch-windows"

$version = $null; $file = $null; $sha = $null
foreach ($raw in Get-Content -LiteralPath $Pin) {
    $line = ($raw -split "#", 2)[0].Trim()
    if ($line -eq "") { continue }
    $f = $line -split "\s+"
    if ($f[0] -eq "version") { $version = $f[1] }
    elseif ($f[0] -eq $triple -and $f.Count -ge 3) { $file = $f[1]; $sha = $f[2] }
}
if (-not $version -or -not $file -or $sha.Length -ne 64) {
    Write-Error "setup-zig: no pin entry for $triple in $Pin" -ErrorAction Continue
    exit 12
}
$dirName = [System.IO.Path]::GetFileNameWithoutExtension($file)
$install = Join-Path $Dest $dirName
$zigExe = Join-Path $install "zig.exe"

function Publish {
    if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $install }
    if ($env:GITHUB_ENV) { Add-Content -LiteralPath $env:GITHUB_ENV -Value "ZIG_VERSION=$version" }
    Write-Host "setup-zig: zig $version at $install"
}

if (Test-Path -LiteralPath $zigExe) {
    $have = (& $zigExe version 2>$null)
    if ($have -eq $version) {
        Write-Host "setup-zig: cache hit"
        Publish
        exit 0
    }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("setup-zig-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $mirrors = @()
    try {
        $list = (Invoke-WebRequest -Uri $mirrorsUrl -TimeoutSec 30 -UseBasicParsing).Content
        $mirrors = @($list -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "^https://" } | Get-Random -Shuffle)
    } catch {
        Write-Warning "setup-zig: could not fetch the mirror list: $($_.Exception.Message)"
    }
    $sources = @($mirrors | ForEach-Object { "$($_.TrimEnd('/'))/$file`?source=zigguro-ci" })
    $sources += "$($fallback.TrimEnd('/'))/$version/$file"

    $archive = Join-Path $tmp $file
    $url = $null
    foreach ($s in $sources) {
        try {
            Invoke-WebRequest -Uri $s -OutFile $archive -TimeoutSec 120 -MaximumRetryCount 2 -UseBasicParsing
            $url = $s
            break
        } catch {
            Write-Warning "setup-zig: $s failed, trying the next source"
        }
    }
    if (-not $url) {
        Write-Error "setup-zig: every source failed for $file" -ErrorAction Continue
        exit 11
    }

    $got = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if (-not ($got -ieq $sha)) {
        Write-Error "zig toolchain hash mismatch: $file from $url" -ErrorAction Continue
        exit 10
    }

    $x = Join-Path $tmp "x"
    Expand-Archive -LiteralPath $archive -DestinationPath $x
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    if (Test-Path -LiteralPath $install) { Remove-Item -LiteralPath $install -Recurse -Force }
    Move-Item -LiteralPath (Join-Path $x $dirName) -Destination $install
    if ((& $zigExe version) -ne $version) {
        Write-Error "setup-zig: installed zig does not report $version" -ErrorAction Continue
        exit 10
    }
    Publish
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
