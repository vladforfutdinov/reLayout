#ifndef RELAYOUT_NATIVE_H
#define RELAYOUT_NATIVE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Reads the focused control's text through UI Automation, changing neither the
/// selection nor the clipboard.
///
/// buf: caller's UTF-16 buffer, cap: its size in UTF-16 units (terminator included).
/// Returns the number of units written, 0 when nothing is selected, and a negative
/// value when UI Automation has no text for this control — the caller then falls
/// back to the clipboard. A selection of `cap` units or more is not copied: the
/// return value is then its length, and the caller retries with a bigger buffer.
int32_t relayout_uia_read_selection(uint16_t *buf, int32_t cap);

/// Reads the focused field for the Enter follow-up: total length, caret offset,
/// selection length, and up to `cap - 1` UTF-16 units right before the caret.
/// Returns 0 on success, a negative value when the control has no UIA text.
int32_t relayout_uia_snapshot(uint16_t *tail, int32_t cap,
                              int32_t *count, int32_t *caret, int32_t *selected);

/// 1 when the focused control is a password field, 0 when it is not, negative when
/// UI Automation cannot say.
int32_t relayout_uia_is_password(void);

/// Dark title bar for `hwnd` (DWMWA_USE_IMMERSIVE_DARK_MODE, Windows 10 20H1+).
void relayout_set_dark_title_bar(void *hwnd, int32_t dark);

/// Applies a visual-style subclass to a control, e.g. "DarkMode_Explorer" for
/// buttons, scroll bars and tooltips, "DarkMode_CFD" for combo boxes; NULL restores
/// the default style.
void relayout_set_window_theme(void *hwnd, const uint16_t *subAppName);

/// Lets the app's popup menus follow the dark theme (uxtheme SetPreferredAppMode,
/// ordinal 135, undocumented but stable since Windows 10 1903). No-op if missing.
void relayout_allow_dark_menus(int32_t dark);

/// Draws a check box (clear or checked) in the visual style of `button` (a BUTTON
/// window, themed light or dark) and appends it to the image list `images`.
/// Returns the new image's index, or -1 on failure.
int32_t relayout_add_check_image(void *images, void *button, int32_t checked);

/// HTTPS GET through WinHTTP (system proxy settings, 5 s connect/10 s receive).
/// Writes up to `cap` bytes of the body into `buf`.
/// Returns the body length, or a negative value on any failure or a non-200 status.
int32_t relayout_https_get(const uint16_t *host, const uint16_t *path,
                           uint8_t *buf, int32_t cap);

/// Whether the system spell checker has a dictionary for `lang`, a 2-letter code
/// ("ru"; "en" also matches an "en-US" dictionary). Returns 1 or 0.
int32_t relayout_spell_supported(const uint16_t *lang);

/// Spell-checks one word in `lang`.
/// Returns 1 when it is spelled right, 0 when misspelled, -1 when there is no
/// dictionary for `lang` or the check failed.
int32_t relayout_spell_check(const uint16_t *lang, const uint16_t *word);

/// The spell checker's suggestions for `word` in `lang`, joined by '\n' into `buf`
/// (cap: its size in UTF-16 units, terminator included; suggestions that do not
/// fit are dropped). Returns the number written, or -1 with no dictionary/error.
int32_t relayout_spell_suggest(const uint16_t *lang, const uint16_t *word, uint16_t *buf, int32_t cap);

#ifdef __cplusplus
}
#endif

#endif
