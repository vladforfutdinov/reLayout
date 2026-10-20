; Inno Setup script for reLayout (Windows).
; Installs the portable, statically-linked single exe per-user (no admin),
; adds a Start Menu shortcut and the "Launch at login" Run value (a task, on by default),
; and offers to launch on finish.
;
; Driven entirely by ISCC /D defines from CI (scripts/windows nothing else needed):
;   AppVer       version string, e.g. 1.2.7
;   SrcDir       directory holding ReLayoutWin.exe + the Swift runtime DLLs
;   OutDir       directory to write the setup .exe into
;   OutBase      output base filename (no extension), e.g. reLayout-windows-x64-setup
;   ArchAllowed  Inno ArchitecturesAllowed value (x64compatible | arm64)
;   Arch64       Inno ArchitecturesInstallIn64BitMode value (x64compatible | arm64)

#ifndef AppVer
  #define AppVer "0.0.0"
#endif
#ifndef SrcDir
  #define SrcDir "..\..\dist\payload"
#endif
#ifndef OutDir
  #define OutDir "..\..\dist"
#endif
#ifndef OutBase
  #define OutBase "reLayout-setup"
#endif
#ifndef ArchAllowed
  #define ArchAllowed "x64compatible"
#endif
#ifndef Arch64
  #define Arch64 "x64compatible"
#endif

[Setup]
AppId={{B7E1F2A0-3C4D-4E5F-9A1B-2C3D4E5F6A7B}
AppName=reLayout
AppVersion={#AppVer}
AppPublisher=Volodymyr Forfutdinov
DefaultDirName={autopf}\reLayout
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\ReLayoutWin.exe
OutputDir={#OutDir}
OutputBaseFilename={#OutBase}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#ArchAllowed}
ArchitecturesInstallIn64BitMode={#Arch64}
WizardStyle=modern

[Files]
Source: "{#SrcDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
Name: autostart; Description: "Launch reLayout at login"

[Icons]
Name: "{autoprograms}\reLayout"; Filename: "{app}\ReLayoutWin.exe"

; Earlier installers autostarted through a Startup shortcut, which the app's
; "Launch at login" switch does not see; the Run value below replaces it.
[InstallDelete]
Type: files; Name: "{userstartup}\reLayout.lnk"

[Run]
Filename: "{app}\ReLayoutWin.exe"; Description: "Launch reLayout"; Flags: nowait postinstall skipifsilent

; The Run value is the one the app's "Launch at login" switch reads and writes
; (WinTray.swift: name "reLayout", the quoted exe path). Uninstall removes it and
; the app's settings, which hold words the user typed (learned auto-correct lists).
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "reLayout"; ValueData: """{app}\ReLayoutWin.exe"""; Tasks: autostart; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "reLayout"; Flags: uninsdeletevalue dontcreatekey
Root: HKCU; Subkey: "Software\reLayout"; Flags: uninsdeletekey dontcreatekey
