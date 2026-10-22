# Windows end-to-end run: starts this checkout's dev build (dist\win, built with
# scripts\build-windows.ps1 -DebugLog: only DEBUG builds accept the harness's keys)
# with known settings, runs scripts\e2e\win-harness.swift in the interactive
# session, then restores HKCU\Software\reLayout and whatever reLayout was running.
# Works from an SSH session: both programs start as interactive scheduled tasks.
# Hands off the VM's keyboard and mouse while it runs.
# -Trace: also turn on the dev build's key log and print it on failure.
# -Spell: run with the spell-check option on, plus the scenarios only it decides.
param([switch]$Trace, [switch]$Spell)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path $PSScriptRoot)
$root = (Get-Location).Path
$app = "$root\dist\win\ReLayoutWin.exe"
if (-not (Test-Path $app)) { throw "no $app - run scripts\build-windows.ps1 -DebugLog first" }

New-Item -ItemType Directory -Force -Path .build | Out-Null
$harness = "$root\.build\e2e-harness.exe"
swiftc -O scripts\e2e\win-harness.swift -o $harness
if ($LASTEXITCODE -ne 0) { throw "harness build failed ($LASTEXITCODE)" }
$ErrorActionPreference = 'Continue'   # reg/schtasks report "not found" on stderr; that is expected

$prefs = 'HKCU\Software\reLayout'
$backup = "$env:TEMP\relayout-e2e-prefs.reg"
$log = "$env:TEMP\relayout-e2e.log"
& reg export $prefs $backup /y *> $null
$hadPrefs = $LASTEXITCODE -eq 0
$running = @(Get-Process ReLayoutWin -ErrorAction SilentlyContinue | ForEach-Object { $_.Path } | Select-Object -Unique)

function Start-Interactive([string]$name, [string]$command) {
    $wrap = "$env:TEMP\$name.cmd"
    Set-Content -Path $wrap -Value $command -Encoding ascii
    schtasks /create /tn $name /tr "`"$wrap`"" /sc once /st 00:00 /it /f | Out-Null
    schtasks /run /tn $name | Out-Null
}

try {
    Get-Process ReLayoutWin -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    # Known state: auto-correct and Enter follow-up on, default hotkey (Left Shift twice), nothing learned.
    foreach ($v in 'HotkeyMods', 'HotkeyVK', 'DoubleTap', 'AutoHotkeyMods', 'AutoHotkeyVK', 'AutoHotkeyDoubleTap',
                   'AutoCorrectOnEnter', 'AutoCorrectSameScript', 'AutoCorrectSpell', 'AutoCorrectLearned',
                   'AutoCorrectKept', 'AutoCorrectLearnCounts', 'AutoCorrectLearnCandidates') {
        & reg delete $prefs /v $v /f 2>$null | Out-Null
    }
    & reg add $prefs /v AutoCorrect /t REG_DWORD /d 1 /f | Out-Null
    # Not an install from before the default changed: no Ctrl+Alt+R pinned.
    & reg add $prefs /v HotkeyDefaultPinned /t REG_DWORD /d 1 /f | Out-Null
    # The auto-correct on/off hotkey: a tap of Right Ctrl, for the modifier-tap scenario.
    & reg add $prefs /v AutoHotkeyVK /t REG_DWORD /d 0xA3 /f | Out-Null
    & reg add $prefs /v AutoHotkeyMods /t REG_DWORD /d 0 /f | Out-Null
    if ($Spell) { & reg add $prefs /v AutoCorrectSpell /t REG_DWORD /d 1 /f | Out-Null }
    $keyLog = "$env:TEMP\relayout-debug.log"
    Remove-Item $keyLog -ErrorAction SilentlyContinue
    if ($Trace) { & reg add $prefs /v DebugLog /t REG_DWORD /d 1 /f | Out-Null }

    Start-Interactive 'relayout-e2e-app' "start `"`" `"$app`""
    # The scheduler may take seconds to start it: typing before its hook is in place
    # made the first scenario fail now and then.
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Get-Process ReLayoutWin -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if (-not (Get-Process ReLayoutWin -ErrorAction SilentlyContinue)) { throw 'ReLayoutWin did not start' }
    Start-Sleep -Seconds 2
    Remove-Item $log -ErrorAction SilentlyContinue
    $mode = if ($Spell) { ' spell' } else { '' }
    Start-Interactive 'relayout-e2e' "`"$harness`"$mode > `"$log`" 2>&1"

    $deadline = (Get-Date).AddSeconds(180)
    do {
        Start-Sleep -Seconds 2
        $out = if (Test-Path $log) { Get-Content $log -Raw -Encoding utf8 } else { '' }
    } until ($out -match '(?m)^(all passed|\d+ failed|ABORT|SKIP)' -or (Get-Date) -gt $deadline)
    Write-Output $out
    # Stalls of reLayout's hook thread, logged in any run: Windows skips a hook past its timeout.
    if ($Trace -and (Test-Path $keyLog)) { Select-String -Path $keyLog -Pattern ' slow ' -Encoding utf8 | ForEach-Object Line }
    if ($out -notmatch '(?m)^all passed') {
        $failed = $true
        if ($Trace -and (Test-Path $keyLog)) { "--- key log ---"; $lines = Get-Content $keyLog -Encoding utf8
            $lines | Select-Object -First 200; "..."; $lines | Select-Object -Last 300 }
    }
} finally {
    Get-Process ReLayoutWin, e2e-harness -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    Remove-Item $keyLog -ErrorAction SilentlyContinue   # it holds keystrokes
    & reg delete $prefs /f 2>$null | Out-Null
    if ($hadPrefs) { & reg import $backup 2>$null | Out-Null; Remove-Item $backup }
    foreach ($t in 'relayout-e2e-app', 'relayout-e2e') { schtasks /delete /tn $t /f 2>$null | Out-Null }
    foreach ($p in $running) { Start-Interactive 'relayout-e2e-restore' "start `"`" `"$p`"" }
    if ($running) { Start-Sleep -Seconds 1; schtasks /delete /tn 'relayout-e2e-restore' /f 2>$null | Out-Null }
}
if ($failed) { exit 1 }
