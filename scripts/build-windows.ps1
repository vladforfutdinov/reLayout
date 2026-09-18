# Local Windows build, the same steps as the build-windows CI job minus packaging:
# compile the icon/manifest resource, build ReLayoutWin (release), and put the
# trigram models and UI strings next to the exe, where the app looks for them.
# Run from anywhere on a Windows machine with the Swift toolchain and VS Build
# Tools. Output: dist\win\ReLayoutWin.exe (Swift runtime DLLs come from PATH).
# -DebugLog compiles in the keystroke diagnostics (WinDebug.swift); never ship that.
param([switch]$DebugLog)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot)
$debugFlags = if ($DebugLog) { @('-Xswiftc', '-DDEBUG') } else { @() }

Push-Location windows
& llvm-rc /FO "$PWD\..\relayout.res" relayout.rc
if ($LASTEXITCODE -ne 0) { throw "llvm-rc failed ($LASTEXITCODE)" }
Pop-Location

# The About link's repo, like scripts/build.sh: RELAYOUT_REPO_SLUG, else the origin
# remote. Stamped into windows\Identity.swift for the build only, then restored.
$slug = $env:RELAYOUT_REPO_SLUG
if (-not $slug) {
  $origin = git remote get-url origin 2>$null
  if ($origin -match 'github\.com[:/](.+?)(\.git)?$') { $slug = $Matches[1] }
}
if ($slug) { "let repoSlug = `"$slug`"" | Set-Content -Encoding utf8 windows\Identity.swift }
try {
  swift build -c release --product ReLayoutWin -Xlinker "$((Resolve-Path relayout.res).Path)" @debugFlags
  if ($LASTEXITCODE -ne 0) { throw "swift build failed ($LASTEXITCODE)" }
} finally {
  if ($slug) { git checkout -- windows\Identity.swift }
}

$out = "dist\win"
New-Item -ItemType Directory -Force -Path "$out\trigram", "$out\lang" | Out-Null
$bin = swift build -c release --show-bin-path
Copy-Item "$bin\ReLayoutWin.exe" $out -Force
Copy-Item Resources\trigram\*.txt "$out\trigram" -Force
Get-ChildItem Resources -Directory -Filter *.lproj | ForEach-Object {
  New-Item -ItemType Directory -Force -Path "$out\lang\$($_.Name)" | Out-Null
  Copy-Item "$($_.FullName)\Localizable.strings" "$out\lang\$($_.Name)\" -Force
}
Write-Host "Built $((Resolve-Path "$out\ReLayoutWin.exe").Path)"
