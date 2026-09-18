import WinSDK
import RelayoutNative

// Light/dark for our own windows, like the macOS ones: the title bar through DWM,
// buttons, combo boxes, scroll bars and tooltips through the system's dark control
// styles, and background, text and separators painted in the theme's colors.
// App windows follow the app mode; the tray menu, like the tray, the taskbar's.

private let personalizeKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"

private func personalizeFlag(_ name: String) -> Bool? {
    var value: DWORD = 0
    var size = DWORD(MemoryLayout<DWORD>.size)
    let r = personalizeKey.withCString(encodedAs: UTF16.self) { key in
        name.withCString(encodedAs: UTF16.self) { n in
            RegGetValueW(HKEY(bitPattern: 0x8000_0001), key, n, DWORD(0x10 /* RRF_RT_REG_DWORD */), nil, &value, &size)
        }
    }
    return r == 0 ? value != 0 : nil
}

/// True in dark app mode (Settings > Personalization > Colors).
func appsUseDarkTheme() -> Bool { personalizeFlag("AppsUseLightTheme") == false }

/// True with a dark taskbar; also the default on Windows without the setting.
func taskbarIsDark() -> Bool { personalizeFlag("SystemUsesLightTheme") != true }

private func rgb(_ r: UInt32, _ g: UInt32, _ b: UInt32) -> COLORREF { COLORREF(r | g << 8 | b << 16) }

/// The colors our windows paint with in the current app mode.
struct ThemeColors {
    let dark: Bool
    let background: COLORREF
    let text: COLORREF
    let secondary: COLORREF
    let separator: COLORREF

    static func current() -> ThemeColors {
        appsUseDarkTheme()
            ? ThemeColors(dark: true, background: rgb(32, 32, 32), text: rgb(255, 255, 255),
                          secondary: rgb(157, 157, 157), separator: rgb(64, 64, 64))
            : ThemeColors(dark: false, background: GetSysColor(COLOR_BTNFACE), text: GetSysColor(COLOR_BTNTEXT),
                          secondary: GetSysColor(COLOR_GRAYTEXT), separator: rgb(216, 216, 216))
    }
}

/// Dark or light title bar for one of our windows.
func applyTitleBarTheme(_ hwnd: HWND?, dark: Bool) {
    relayout_set_dark_title_bar(UnsafeMutableRawPointer(hwnd), dark ? 1 : 0)
}

/// The system's dark style for a control class that has one; the default in light mode.
func applyControlTheme(_ ctl: HWND?, className: String, dark: Bool) {
    let sub: String?
    switch className {
    case "BUTTON", "SysListView32", "tooltips_class32": sub = "DarkMode_Explorer"
    case "COMBOBOX": sub = "DarkMode_CFD"
    default: return
    }
    guard dark, let sub else {
        relayout_set_window_theme(UnsafeMutableRawPointer(ctl), nil)
        return
    }
    sub.withCString(encodedAs: UTF16.self) { relayout_set_window_theme(UnsafeMutableRawPointer(ctl), $0) }
}

/// Rebuilds a window's controls with its painting held off, then paints it once:
/// tearing down and recreating the controls in view flickers.
func rebuildWithoutFlicker(_ hwnd: HWND?, _ rebuild: () -> Void) {
    SendMessageW(hwnd, UINT(WM_SETREDRAW), 0, 0)
    rebuild()
    SendMessageW(hwnd, UINT(WM_SETREDRAW), 1, 0)
    RedrawWindow(hwnd, nil, nil, UINT(RDW_ERASE | RDW_FRAME | RDW_INVALIDATE | RDW_ALLCHILDREN))
}

/// Popup menus (the tray menu) follow the taskbar's theme, as the system's do.
func applyMenuTheme() {
    relayout_allow_dark_menus(taskbarIsDark() ? 1 : 0)
}
