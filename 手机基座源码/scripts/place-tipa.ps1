# Download latest tipa artifact from GitHub Actions and keep only that package locally.
param(
  [string]$Repo = "softwaredg/ios-yunkong-base",
  [string]$OutDir = "e:\iOS投屏\手机基座",
  [long]$RunId = 0
)

$ErrorActionPreference = "Stop"
$OutDir = [IO.Path]::GetFullPath($OutDir)

if ($RunId -le 0) {
  $runsJson = gh run list -R $Repo --workflow=build-tipa.yml -L 20 --json databaseId,conclusion,status
  $run = ($runsJson | ConvertFrom-Json) | Where-Object { $_.conclusion -eq "success" } | Select-Object -First 1
  if (-not $run) { throw "no successful Build tipa run" }
  $RunId = [long]$run.databaseId
}

$arts = gh api "repos/$Repo/actions/runs/$RunId/artifacts" | ConvertFrom-Json
$art = $arts.artifacts |
  Where-Object { $_.name -like "IOS投屏-*-tipa" -or $_.name -like "IOSYunKongBase-*-tipa" } |
  Select-Object -First 1
if (-not $art) { throw "no tipa artifact on run $RunId" }

$tmp = Join-Path $env:TEMP ("tipa-dl-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  gh run download $RunId -R $Repo -n $art.name -D $tmp
  $tipa = Get-ChildItem -Recurse -Path $tmp -Filter "*.tipa" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $tipa) { throw "no tipa in artifact $($art.name)" }

  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  Get-ChildItem -LiteralPath $OutDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "tipa-*" } |
    Remove-Item -Recurse -Force

  $dest = Join-Path $OutDir $tipa.Name
  Copy-Item -Force $tipa.FullName $dest
  $destFull = [IO.Path]::GetFullPath($dest)
  # 每次生成只保留最新 tipa，其余全部清掉
  Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -ieq ".tipa" -and $_.FullName -ne $destFull } |
    ForEach-Object {
      Write-Host "remove old $($_.Name)"
      Remove-Item -LiteralPath $_.FullName -Force
    }
  Write-Host "placed $dest (from $($art.name))"
  Get-Item $dest | Format-List FullName, Length, LastWriteTime
}
finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
