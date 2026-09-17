// UI Automation text reader — the Windows counterpart of the macOS AX read.
// COM lives here because Swift has no COM interop; the app calls one C function.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>     // defines `interface`, which uiautomation.h uses
#include <oleauto.h>     // BSTR
#include <uiautomation.h>
#include <string.h>

#include "include/relayout_uia.h"

namespace {

IUIAutomation *automation() {
    static IUIAutomation *cached = nullptr;
    if (!cached) {
        CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);   // the app's UI thread
        CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                         IID_PPV_ARGS(&cached));
    }
    return cached;
}

// Copies a BSTR out and frees it. Keeps the END of the text: the caller wants the
// characters next to the caret, not the start of a long line.
int32_t copyTail(BSTR s, uint16_t *buf, int32_t cap) {
    if (!s) return 0;
    int32_t len = (int32_t)SysStringLen(s);
    int32_t n = len < cap - 1 ? len : cap - 1;
    memcpy(buf, s + (len - n), (size_t)n * sizeof(uint16_t));
    buf[n] = 0;
    SysFreeString(s);
    return n;
}

IUIAutomationTextPattern *focusedText(IUIAutomation *uia) {
    IUIAutomationElement *element = nullptr;
    if (FAILED(uia->GetFocusedElement(&element)) || !element) return nullptr;
    IUIAutomationTextPattern *text = nullptr;
    HRESULT hr = element->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&text));
    element->Release();
    return SUCCEEDED(hr) ? text : nullptr;
}

}  // namespace

int32_t relayout_uia_read_selection(uint16_t *buf, int32_t cap) {
    if (!buf || cap < 2) return -1;
    IUIAutomation *uia = automation();
    if (!uia) return -1;

    IUIAutomationTextPattern *text = focusedText(uia);
    if (!text) return -1;

    int32_t result = -1;
    IUIAutomationTextRangeArray *ranges = nullptr;
    if (SUCCEEDED(text->GetSelection(&ranges)) && ranges) {
        int length = 0;
        IUIAutomationTextRange *range = nullptr;
        if (SUCCEEDED(ranges->get_Length(&length)) && length > 0 &&
            SUCCEEDED(ranges->GetElement(0, &range)) && range) {
            BSTR selected = nullptr;
            // An empty range is the caret, not a selection: 0 units, and the
            // caller does nothing — the hotkey never guesses at a word.
            if (SUCCEEDED(range->GetText(-1, &selected))) result = copyTail(selected, buf, cap);
            range->Release();
        }
        ranges->Release();
    }
    text->Release();
    return result;
}

int32_t relayout_uia_snapshot(uint16_t *tail, int32_t cap,
                              int32_t *count, int32_t *caret, int32_t *selected) {
    if (!tail || cap < 2) return -1;
    *count = 0; *caret = 0; *selected = 0;
    IUIAutomation *uia = automation();
    if (!uia) return -1;
    IUIAutomationTextPattern *text = focusedText(uia);
    if (!text) return -1;

    int32_t result = -1;
    IUIAutomationTextRange *document = nullptr;
    IUIAutomationTextRangeArray *ranges = nullptr;
    IUIAutomationTextRange *selection = nullptr;
    int length = 0;
    if (SUCCEEDED(text->get_DocumentRange(&document)) && document &&
        SUCCEEDED(text->GetSelection(&ranges)) && ranges &&
        SUCCEEDED(ranges->get_Length(&length)) && length > 0 &&
        SUCCEEDED(ranges->GetElement(0, &selection)) && selection) {
        BSTR whole = nullptr;
        if (SUCCEEDED(document->GetText(-1, &whole))) {
            *count = (int32_t)SysStringLen(whole);
            SysFreeString(whole);
            BSTR picked = nullptr;
            if (SUCCEEDED(selection->GetText(-1, &picked))) {
                *selected = (int32_t)SysStringLen(picked);
                SysFreeString(picked);
                // Everything before the caret: the document range with its end
                // pulled back to where the selection starts.
                IUIAutomationTextRange *head = nullptr;
                if (SUCCEEDED(document->Clone(&head)) && head) {
                    if (SUCCEEDED(head->MoveEndpointByRange(TextPatternRangeEndpoint_End, selection,
                                                            TextPatternRangeEndpoint_Start))) {
                        BSTR before = nullptr;
                        if (SUCCEEDED(head->GetText(-1, &before))) {
                            *caret = (int32_t)SysStringLen(before);
                            copyTail(before, tail, cap);
                            result = 0;
                        }
                    }
                    head->Release();
                }
            }
        }
    }
    if (selection) selection->Release();
    if (ranges) ranges->Release();
    if (document) document->Release();
    text->Release();
    return result;
}

int32_t relayout_uia_is_password(void) {
    IUIAutomation *uia = automation();
    if (!uia) return -1;
    IUIAutomationElement *element = nullptr;
    if (FAILED(uia->GetFocusedElement(&element)) || !element) return -1;
    VARIANT value;
    VariantInit(&value);
    int32_t result = -1;
    if (SUCCEEDED(element->GetCurrentPropertyValue(UIA_IsPasswordPropertyId, &value)) &&
        value.vt == VT_BOOL) {
        result = value.boolVal == VARIANT_TRUE ? 1 : 0;
    }
    VariantClear(&value);
    element->Release();
    return result;
}
