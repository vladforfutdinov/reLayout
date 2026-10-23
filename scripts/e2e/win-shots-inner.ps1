# Desktop session: opens Settings, Exceptions and Learned in the running app and
# saves each window (PrintWindow) to $args[0]\<name>.png.
param([string]$Out)
$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Drawing; using System.Drawing.Imaging;
public static class Shot {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static IntPtr Wait(string cls) {
    for (int i = 0; i < 200; i++) { var h = FindWindowW(cls, null); if (h != IntPtr.Zero) return h; System.Threading.Thread.Sleep(100); }
    return IntPtr.Zero;
  }
  public static void Save(IntPtr h, string path) {
    RECT r; GetWindowRect(h, out r);
    using (var bmp = new Bitmap(r.R - r.L, r.B - r.T)) {
      using (var g = Graphics.FromImage(bmp)) { var dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc); }
      bmp.Save(path, ImageFormat.Png);
    }
  }
}
'@
[void][Shot]::SetProcessDPIAware()
$WM_COMMAND = 0x0111; $WM_CLOSE = 0x0010
$tray = [Shot]::Wait('ReLayoutTrayWnd'); if ($tray -eq 0) { throw 'no tray window' }
[void][Shot]::PostMessageW($tray, $WM_COMMAND, [IntPtr]1, [IntPtr]0)
$set = [Shot]::Wait('ReLayoutSettingsWnd'); if ($set -eq 0) { throw 'no settings window' }
Start-Sleep -Milliseconds 1500; [Shot]::Save($set, "$Out\settings.png")
foreach ($w in @(@{ id = 111; cls = 'ReLayoutExceptionsWnd'; name = 'exceptions' }, @{ id = 117; cls = 'ReLayoutLearnedWnd'; name = 'learned' })) {
  [void][Shot]::PostMessageW($set, $WM_COMMAND, [IntPtr]$w.id, [IntPtr]0)
  $h = [Shot]::Wait($w.cls); if ($h -eq 0) { throw "no $($w.name) window" }
  Start-Sleep -Milliseconds 1500; [Shot]::Save($h, "$Out\$($w.name).png")
  [void][Shot]::PostMessageW($h, $WM_CLOSE, [IntPtr]0, [IntPtr]0); Start-Sleep -Milliseconds 500
}
[void][Shot]::PostMessageW($set, $WM_CLOSE, [IntPtr]0, [IntPtr]0)
'ok' | Set-Content "$Out\done.txt"
