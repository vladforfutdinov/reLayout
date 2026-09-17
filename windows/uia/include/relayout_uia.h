#ifndef RELAYOUT_UIA_H
#define RELAYOUT_UIA_H

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
/// back to the clipboard.
int32_t relayout_uia_read_selection(uint16_t *buf, int32_t cap);

#ifdef __cplusplus
}
#endif

#endif
