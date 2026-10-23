// Dark-mode plumbing Swift's WinSDK module doesn't reach: DWM's dark title bar,
// uxtheme's SetWindowTheme, and the undocumented app mode for dark popup menus.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <vssym32.h>
#include <commctrl.h>

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

int32_t relayout_add_check_image(void *images, void *button, int32_t checked) {
    HIMAGELIST list = (HIMAGELIST)images;
    int cx, cy;
    if (!ImageList_GetIconSize(list, &cx, &cy)) return -1;
    HTHEME theme = OpenThemeData((HWND)button, L"Button");
    if (!theme) return -1;
    BITMAPINFO info = {};
    info.bmiHeader = {sizeof(BITMAPINFOHEADER), cx, -cy, 1, 32, BI_RGB};
    void *bits = nullptr;
    HDC dc = CreateCompatibleDC(nullptr);
    HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    int32_t index = -1;
    if (bitmap) {
        HGDIOBJ old = SelectObject(dc, bitmap);
        int state = checked ? CBS_CHECKEDNORMAL : CBS_UNCHECKEDNORMAL;
        SIZE box = {13, 13};
        GetThemePartSize(theme, dc, BP_CHECKBOX, state, nullptr, TS_DRAW, &box);
        RECT r = {(cx - box.cx) / 2, (cy - box.cy) / 2, 0, 0};
        r.right = r.left + box.cx; r.bottom = r.top + box.cy;
        DrawThemeBackground(theme, dc, BP_CHECKBOX, state, &r, nullptr);
        SelectObject(dc, old);
        index = ImageList_Add(list, bitmap, nullptr);
        DeleteObject(bitmap);
    }
    DeleteDC(dc);
    CloseThemeData(theme);
    return index;
}
