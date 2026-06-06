; Inno Setup script for reLayout (Windows).
; Installs the portable, statically-linked single exe per-user (no admin),
; adds a Start Menu shortcut and a Startup shortcut (the tray app autostarts),
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
AppPublisher=Vlad Forfutdinov
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

[Icons]
Name: "{autoprograms}\reLayout"; Filename: "{app}\ReLayoutWin.exe"
Name: "{userstartup}\reLayout"; Filename: "{app}\ReLayoutWin.exe"

[Run]
Filename: "{app}\ReLayoutWin.exe"; Description: "Launch reLayout"; Flags: nowait postinstall skipifsilent
