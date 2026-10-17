// Windows Spell Checking API (spellcheck.h) — the system dictionary behind the
// auto-correct spell-check option, the counterpart of NSSpellChecker on macOS.
// COM, so it lives here with the UI Automation reader.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <spellcheck.h>
#include <wchar.h>

#include "include/relayout_native.h"

namespace {

// CLSID_SpellCheckerFactory, spelled out so nothing depends on which import
// library carries it.
const CLSID kSpellCheckerFactory =
    {0x7ab36653, 0x1796, 0x484b, {0xbd, 0xfa, 0xe7, 0x4f, 0x1d, 0xb7, 0xc1, 0xdc}};

ISpellCheckerFactory *factory() {
    static ISpellCheckerFactory *cached = nullptr;
    static bool tried = false;
    if (!tried) {
        tried = true;
        // The app's UI thread, the same apartment the UI Automation reader joins.
        CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        if (FAILED(CoCreateInstance(kSpellCheckerFactory, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&cached)))) cached = nullptr;
    }
    return cached;
}

bool supported(ISpellCheckerFactory *f, const wchar_t *tag) {
    BOOL ok = FALSE;
    return SUCCEEDED(f->IsSupported(tag, &ok)) && ok;
}

// The dictionary tag for a 2-letter code: the code itself, else the first
// supported "<code>-…" tag ("en" -> "en-US"). False when there is none.
bool resolveTag(ISpellCheckerFactory *f, const wchar_t *code, wchar_t *out, size_t cap) {
    if (supported(f, code)) return wcsncpy_s(out, cap, code, _TRUNCATE) == 0;
    size_t n = wcslen(code);
    bool found = false;
    IEnumString *tags = nullptr;
    if (SUCCEEDED(f->get_SupportedLanguages(&tags)) && tags) {
        LPOLESTR tag = nullptr;
        while (!found && tags->Next(1, &tag, nullptr) == S_OK) {
            if (tag && _wcsnicmp(tag, code, n) == 0 && tag[n] == L'-') {
                found = wcsncpy_s(out, cap, tag, _TRUNCATE) == 0;
            }
            CoTaskMemFree(tag);
            tag = nullptr;
        }
        tags->Release();
    }
    return found;
}

// One checker per language code, created on first use; a null checker = no
// dictionary. Plain arrays, no STL: a handful of languages at most.
struct Entry {
    wchar_t code[16];
    ISpellChecker *checker;
};
Entry cache[32];
int cacheCount = 0;

ISpellChecker *checker(const uint16_t *lang) {
    if (!lang) return nullptr;
    const wchar_t *code = reinterpret_cast<const wchar_t *>(lang);
    if (wcslen(code) >= 16) return nullptr;
    for (int i = 0; i < cacheCount; i++) {
        if (wcscmp(cache[i].code, code) == 0) return cache[i].checker;
    }
    ISpellChecker *made = nullptr;
    wchar_t tag[LOCALE_NAME_MAX_LENGTH] = {0};
    if (ISpellCheckerFactory *f = factory()) {
        if (!resolveTag(f, code, tag, LOCALE_NAME_MAX_LENGTH) ||
            FAILED(f->CreateSpellChecker(tag, &made))) made = nullptr;
    }
    if (cacheCount < 32) {
        wcsncpy_s(cache[cacheCount].code, 16, code, _TRUNCATE);
        cache[cacheCount].checker = made;
        cacheCount++;
    }
    return made;
}

}  // namespace

int32_t relayout_spell_supported(const uint16_t *lang) {
    return checker(lang) ? 1 : 0;
}

int32_t relayout_spell_check(const uint16_t *lang, const uint16_t *word) {
    ISpellChecker *c = checker(lang);
    if (!c || !word) return -1;
    IEnumSpellingError *errors = nullptr;
    if (FAILED(c->Check(reinterpret_cast<LPCWSTR>(word), &errors)) || !errors) return -1;
    ISpellingError *error = nullptr;
    HRESULT hr = errors->Next(&error);
    errors->Release();
    if (hr == S_OK && error) {
        error->Release();
        return 0;
    }
    return hr == S_FALSE ? 1 : -1;   // S_FALSE: no error left, the word is spelled right
}

int32_t relayout_spell_suggest(const uint16_t *lang, const uint16_t *word, uint16_t *buf, int32_t cap) {
    ISpellChecker *c = checker(lang);
    if (!c || !word || !buf || cap < 1) return -1;
    buf[0] = 0;
    IEnumString *list = nullptr;
    if (FAILED(c->Suggest(reinterpret_cast<LPCWSTR>(word), &list)) || !list) return -1;
    int32_t count = 0, used = 0;
    LPOLESTR s = nullptr;
    while (list->Next(1, &s, nullptr) == S_OK) {
        if (s) {
            int32_t len = (int32_t)wcslen(s);
            int32_t need = len + (count > 0 ? 1 : 0);
            if (used + need < cap) {   // keeps room for the terminator
                if (count > 0) buf[used++] = L'\n';
                for (int32_t i = 0; i < len; i++) buf[used++] = (uint16_t)s[i];
                buf[used] = 0;
                count++;
            }
            CoTaskMemFree(s);
            s = nullptr;
        }
    }
    list->Release();
    return count;
}
