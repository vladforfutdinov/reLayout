# In the Windows VM over SSH (run by scripts/win-shots.sh): builds C:\src\rl-shots at
# $Ref from C:\src\rl-shots.bundle, then shoots Settings, Exceptions and Learned in
# the light and the dark app theme with known prefs; restores prefs and theme after.
param([string]$Ref, [string]$Label, [switch]$DebugLog)
$ErrorActionPreference = 'Continue'
$prefs = 'HKCU\Software\reLayout'; $backup = "$env:TEMP\relayout-shots-prefs.reg"
$theme = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$origTheme = (Get-ItemProperty $theme -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
& reg export $prefs $backup /y *> $null; $hadPrefs = $LASTEXITCODE -eq 0
$running = Get-Process ReLayoutWin -ErrorAction SilentlyContinue | ForEach-Object Path | Select-Object -Unique
function Start-Interactive([string]$name, [string]$command) {
  $wrap = "$env:TEMP\$name.cmd"; Set-Content -Path $wrap -Value $command -Encoding ascii
  schtasks /create /tn $name /tr "`"$wrap`"" /sc once /st 00:00 /it /f | Out-Null
  schtasks /run /tn $name | Out-Null
}
Set-Location C:\src\reLayout
if (Test-Path C:\src\rl-shots) { git worktree remove --force C:\src\rl-shots }
git fetch -q -f C:\src\rl-shots.bundle "${Ref}:refs/heads/rl-shots"
git worktree add -q C:\src\rl-shots rl-shots
if (-not (Test-Path C:\src\rl-shots\windows)) { exit 1 }
Set-Location C:\src\rl-shots
"AT $(git log --oneline -1)"
$debugFlag = if ($DebugLog) { "-DebugLog" } else { "" }
powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 $debugFlag | Select-Object -Last 1
"BUILD EXIT: $LASTEXITCODE"
try {
  foreach ($t in @(@{ v = 1; n = 'light' }, @{ v = 0; n = 'dark' })) {
    Get-Process ReLayoutWin -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 500
    & reg delete $prefs /f 2>$null | Out-Null
    & reg add $prefs /v AutoCorrect /t REG_DWORD /d 1 /f | Out-Null
    & reg add $prefs /v Language /t REG_SZ /d en /f | Out-Null
    & reg add $prefs /v HotkeyDefaultPinned /t REG_DWORD /d 1 /f | Out-Null
    & reg add $prefs /v AutoCorrectLearned /t REG_SZ /d "ghbdtn`t??????`nrybuf`t?????" /f | Out-Null
    & reg add $prefs /v AutoCorrectKept /t REG_SZ /d "hello`nwiki" /f | Out-Null
    & reg add $prefs /v AutoCorrectLearnCandidates /t REG_SZ /d "vjq`t???" /f | Out-Null
    if ($DebugLog) { & reg add $prefs /v DebugLog /t REG_DWORD /d 1 /f | Out-Null; Remove-Item "$env:TEMP\relayout-debug.log" -ErrorAction SilentlyContinue }
    Set-ItemProperty $theme -Name AppsUseLightTheme -Value $t.v
    $out = "C:\src\rl-shots-out\$Label\$($t.n)"; Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $out | Out-Null
    Start-Interactive 'relayout-shots-app' "start `"`" `"C:\src\rl-shots\dist\win\ReLayoutWin.exe`""
    Start-Sleep 4
    Start-Interactive 'relayout-shots' "powershell -ExecutionPolicy Bypass -File C:\src\rl-shots\scripts\e2e\win-shots-inner.ps1 -Out $out > $out\inner.log 2>&1"
    for ($i = 0; $i -lt 40 -and -not (Test-Path "$out\done.txt"); $i++) { Start-Sleep 1 }
    if ($DebugLog) { Copy-Item "$env:TEMP\relayout-debug.log" "$out\debug.log" -ErrorAction SilentlyContinue }
    "$($t.n): " + ((Get-ChildItem $out -Filter *.png).Name -join ', ')
    Get-Content "$out\inner.log" -ErrorAction SilentlyContinue | Select-Object -First 5
  }
} finally {
  Get-Process ReLayoutWin -ErrorAction SilentlyContinue | Stop-Process -Force
  if ($null -ne $origTheme) { Set-ItemProperty $theme -Name AppsUseLightTheme -Value $origTheme }
  & reg delete $prefs /f 2>$null | Out-Null
  if ($hadPrefs) { & reg import $backup 2>$null | Out-Null; Remove-Item $backup }
  foreach ($t in 'relayout-shots-app', 'relayout-shots') { schtasks /delete /tn $t /f 2>$null | Out-Null }
  foreach ($p in $running) { Start-Interactive 'relayout-shots-restore' "start `"`" `"$p`"" }
}
