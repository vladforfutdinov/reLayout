// Dark-mode plumbing Swift's WinSDK module doesn't reach: DWM's dark title bar,
// uxtheme's SetWindowTheme, and the undocumented app mode for dark popup menus.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <uxtheme.h>

#include "include/relayout_native.h"

void relayout_set_dark_title_bar(void *hwnd, int32_t dark) {
    BOOL value = dark ? TRUE : FALSE;
    DwmSetWindowAttribute((HWND)hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &value, sizeof(value));
}

void relayout_set_window_theme(void *hwnd, const uint16_t *subAppName) {
    SetWindowTheme((HWND)hwnd, (LPCWSTR)subAppName, nullptr);
}

void relayout_allow_dark_menus(int32_t dark) {
    HMODULE uxtheme = GetModuleHandleW(L"uxtheme.dll");
    if (!uxtheme) uxtheme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!uxtheme) return;
    // enum PreferredAppMode { Default, AllowDark, ForceDark, ForceLight, Max };
    using SetPreferredAppMode = int (WINAPI *)(int);
    using FlushMenuThemes = void (WINAPI *)();
    auto setMode = (SetPreferredAppMode)GetProcAddress(uxtheme, MAKEINTRESOURCEA(135));
    auto flush = (FlushMenuThemes)GetProcAddress(uxtheme, MAKEINTRESOURCEA(136));
    if (setMode) setMode(dark ? 2 /* ForceDark */ : 3 /* ForceLight */);
    if (flush) flush();
}
