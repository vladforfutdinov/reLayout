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

/// Reads the focused field for the Enter follow-up: total length, caret offset,
/// selection length, and up to `cap - 1` UTF-16 units right before the caret.
/// Returns 0 on success, a negative value when the control has no UIA text.
int32_t relayout_uia_snapshot(uint16_t *tail, int32_t cap,
                              int32_t *count, int32_t *caret, int32_t *selected);

#ifdef __cplusplus
}
#endif

#endif
