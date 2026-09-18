# Local Windows build, the same steps as the build-windows CI job minus packaging:
# compile the icon/manifest resource, build ReLayoutWin (release), and put the
# trigram models and UI strings next to the exe, where the app looks for them.
# Run from anywhere on a Windows machine with the Swift toolchain and VS Build
# Tools. Output: dist\win\ReLayoutWin.exe (Swift runtime DLLs come from PATH).
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot)

Push-Location windows
& llvm-rc /FO "$PWD\..\relayout.res" relayout.rc
if ($LASTEXITCODE -ne 0) { throw "llvm-rc failed ($LASTEXITCODE)" }
Pop-Location

swift build -c release --product ReLayoutWin -Xlinker "$((Resolve-Path relayout.res).Path)"
if ($LASTEXITCODE -ne 0) { throw "swift build failed ($LASTEXITCODE)" }

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
