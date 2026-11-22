# Copyright (C) 2026 Rocks
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds a release copy of Strata.rbxm into dist/ after verifying src/Version.luau and wally.toml match.
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$versionFile = Join-Path $root "src\Version.luau"
$wallyFile = Join-Path $root "wally.toml"
$projectFile = Join-Path $root "default.project.json"
$distDir = Join-Path $root "dist"
$outFile = Join-Path $distDir "Strata.rbxm"

$versionContent = Get-Content -Path $versionFile -Raw
$wallyContent = Get-Content -Path $wallyFile -Raw

$versionMatch = [regex]::Match($versionContent, '(?m)^return\s+"([^"]+)"')
$wallyMatch = [regex]::Match($wallyContent, '(?m)^version\s*=\s*"([^"]+)"')

if (-not $versionMatch.Success) {
	throw "Could not read version string from src/Version.luau"
}

if (-not $wallyMatch.Success) {
	throw "Could not read package version from wally.toml"
}

$version = $versionMatch.Groups[1].Value
$wallyVersion = $wallyMatch.Groups[1].Value

if ($version -ne $wallyVersion) {
	throw "Version mismatch: src/Version.luau has '$version' but wally.toml has '$wallyVersion'"
}

$semver = '^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'

if ($version -notmatch $semver) {
	throw "Version '$version' is not valid SemVer"
}

if (-not (Test-Path $distDir)) {
	New-Item -ItemType Directory -Path $distDir | Out-Null
}

& rojo build $projectFile -o $outFile

if ($LASTEXITCODE -ne 0) {
	exit $LASTEXITCODE
}

Write-Host "Built Strata $version -> $outFile"
Write-Host "Keep the filename Strata.rbxm when installing into Roblox Studio's Plugins folder."
Write-Host "Tag when ready: git tag -a v$version -m `"Strata $version`""
