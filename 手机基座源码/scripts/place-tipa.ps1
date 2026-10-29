# Download latest tipa artifact from GitHub Actions and keep only that package locally.
param(
  [string]$Repo = "softwaredg/ios-yunkong-base",
  [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
if (-not $OutDir) {
  $OutDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "手机基座"
  if (-not (Test-Path $OutDir)) {
    $OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) "..\手机基座"
  }
  $OutDir = [IO.Path]::GetFullPath($OutDir)
}

$run = gh run list -R $Repo --workflow=build-tipa.yml -L 20 --json databaseId,conclusion,status,displayTitle |
  ConvertFrom-Json |
  Where-Object { $_.conclusion -eq "success" } |
  Select-Object -First 1
if (-not $run) { throw "no successful Build tipa run" }

$tmp = Join-Path $env:TEMP ("tipa-dl-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  gh run download $run.databaseId -R $Repo -D $tmp
  $tipa = Get-ChildItem -Recurse -Path $tmp -Filter "IOS云控基座-TVH4-IOHID-*.tipa" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $tipa) { throw "no tipa in artifact" }

  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  Get-ChildItem -Path $OutDir -Filter "IOS云控基座-TVH4-IOHID-*.tipa" -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -Path $OutDir -Filter "IOS云控基座.tipa" -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem -Path $OutDir -Directory -Filter "tipa-*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

  $dest = Join-Path $OutDir $tipa.Name
  Copy-Item -Force $tipa.FullName $dest
  Write-Host "placed $dest"
  Get-Item $dest | Format-List FullName, Length, LastWriteTime
}
finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
