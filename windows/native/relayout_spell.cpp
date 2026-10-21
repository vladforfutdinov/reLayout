// Windows Spell Checking API (spellcheck.h) — the system dictionary behind the
// auto-correct spell-check option, the counterpart of NSSpellChecker on macOS.
// COM, so it lives here with the UI Automation reader.
//
// The checker is an out-of-process COM server, and an outgoing COM call from
// inside a low-level keyboard hook fails (RPC_E_CANTCALLOUT_ININPUTSYNCCALL: the
// hook is an input-synchronous call). So every call runs on a worker thread of its
// own (MTA), which owns all spell objects; callers wait for it, with a timeout.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <spellcheck.h>
#include <wchar.h>
#include <stdlib.h>

#include "include/relayout_native.h"

namespace {

// CLSID_SpellCheckerFactory, spelled out so nothing depends on which import
// library carries it.
const CLSID kSpellCheckerFactory =
    {0x7ab36653, 0x1796, 0x484b, {0xbd, 0xfa, 0xe7, 0x4f, 0x1d, 0xb7, 0xc1, 0xdc}};

// --- the worker thread's side: only the worker touches these ---

ISpellCheckerFactory *factory() {
    static ISpellCheckerFactory *cached = nullptr;
    static bool tried = false;
    if (!tried) {
        tried = true;
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

ISpellChecker *checker(const wchar_t *code) {
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

int32_t check(const wchar_t *lang, const wchar_t *word) {
    ISpellChecker *c = checker(lang);
    if (!c) return -1;
    IEnumSpellingError *errors = nullptr;
    if (FAILED(c->Check(word, &errors)) || !errors) return -1;
    ISpellingError *error = nullptr;
    HRESULT hr = errors->Next(&error);
    errors->Release();
    if (hr == S_OK && error) {
        error->Release();
        return 0;
    }
    return hr == S_FALSE ? 1 : -1;   // S_FALSE: no error left, the word is spelled right
}

const int32_t kOutCap = 1024;

// Suggestions, "\n"-separated, into `out` (kOutCap units with the terminator).
int32_t suggest(const wchar_t *lang, const wchar_t *word, wchar_t *out) {
    ISpellChecker *c = checker(lang);
    if (!c) return -1;
    IEnumString *list = nullptr;
    if (FAILED(c->Suggest(word, &list)) || !list) return -1;
    int32_t count = 0, used = 0;
    LPOLESTR s = nullptr;
    while (list->Next(1, &s, nullptr) == S_OK) {
        if (s) {
            int32_t len = (int32_t)wcslen(s);
            int32_t need = len + (count > 0 ? 1 : 0);
            if (used + need < kOutCap) {   // keeps room for the terminator
                if (count > 0) out[used++] = L'\n';
                wmemcpy(out + used, s, len);
                used += len;
                out[used] = 0;
                count++;
            }
            CoTaskMemFree(s);
            s = nullptr;
        }
    }
    list->Release();
    return count;
}

// --- the hand-off: one request at a time ---

enum Kind { kSupported, kCheck, kSuggest };

// Everything the worker reads is copied in, so a caller that stops waiting leaves
// nothing dangling; whoever drops the last reference frees it.
struct Request {
    Kind kind;
    wchar_t lang[16];
    wchar_t *word;          // a copy; null for kSupported
    wchar_t out[kOutCap];
    int32_t result;
    HANDLE done;            // manual-reset, set by the worker
    volatile LONG refs;     // caller + worker
};

void release(Request *r) {
    if (InterlockedDecrement(&r->refs) == 0) {
        CloseHandle(r->done);
        free(r->word);
        free(r);
    }
}

INIT_ONCE started = INIT_ONCE_STATIC_INIT;
HANDLE wake = nullptr;              // auto-reset: `pending` holds a request
Request *volatile pending = nullptr;
volatile LONG busy = 0;             // the worker has a request (maybe one its caller gave up on)

DWORD WINAPI worker(void *) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    for (;;) {
        WaitForSingleObject(wake, INFINITE);
        Request *r = pending;
        switch (r->kind) {
        case kSupported: r->result = checker(r->lang) ? 1 : 0; break;
        case kCheck: r->result = check(r->lang, r->word); break;
        case kSuggest: r->result = suggest(r->lang, r->word, r->out); break;
        }
        InterlockedExchange(&busy, 0);
        SetEvent(r->done);
        release(r);
    }
}

BOOL CALLBACK start(PINIT_ONCE, PVOID, PVOID *) {
    wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    HANDLE t = wake ? CreateThread(nullptr, 0, worker, nullptr, 0, nullptr) : nullptr;
    if (t) CloseHandle(t);
    return t != nullptr;
}

// Runs a request on the worker and waits up to `timeoutMs`; -1 when the worker
// is still on an earlier request, did not answer in time, or could not start.
int32_t run(Kind kind, const uint16_t *lang, const uint16_t *word, uint16_t *out, int32_t cap,
            DWORD timeoutMs) {
    if (!lang || (kind != kSupported && !word)) return -1;
    const wchar_t *code = reinterpret_cast<const wchar_t *>(lang);
    if (wcslen(code) >= 16 || !InitOnceExecuteOnce(&started, start, nullptr, nullptr)) return -1;
    if (InterlockedCompareExchange(&busy, 1, 0) != 0) return -1;
    Request *r = static_cast<Request *>(calloc(1, sizeof(Request)));
    if (!r) { InterlockedExchange(&busy, 0); return -1; }
    r->kind = kind;
    wcsncpy_s(r->lang, 16, code, _TRUNCATE);
    r->word = word ? _wcsdup(reinterpret_cast<const wchar_t *>(word)) : nullptr;
    r->done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    r->refs = 2;
    if ((word && !r->word) || !r->done) {
        if (r->done) CloseHandle(r->done);
        free(r->word); free(r);
        InterlockedExchange(&busy, 0);
        return -1;
    }
    pending = r;
    SetEvent(wake);
    int32_t result = -1;
    if (WaitForSingleObject(r->done, timeoutMs) == WAIT_OBJECT_0) {
        result = r->result;
        if (out && cap > 0) {
            int32_t n = (int32_t)wcsnlen(r->out, kOutCap);
            if (n >= cap) n = cap - 1;
            for (int32_t i = 0; i < n; i++) out[i] = (uint16_t)r->out[i];
            out[n] = 0;
        }
    }
    release(r);
    return result;
}

}  // namespace

// Opening a dictionary is slow (a warm-up, a Settings check): a generous wait.
int32_t relayout_spell_supported(const uint16_t *lang) {
    return run(kSupported, lang, nullptr, nullptr, 0, 5000) == 1 ? 1 : 0;
}

// Asked inside the keyboard hook: a short wait, past which the answer is "unknown".
int32_t relayout_spell_check(const uint16_t *lang, const uint16_t *word) {
    return run(kCheck, lang, word, nullptr, 0, 40);
}

int32_t relayout_spell_suggest(const uint16_t *lang, const uint16_t *word, uint16_t *buf, int32_t cap) {
    if (!buf || cap < 1) return -1;
    buf[0] = 0;
    return run(kSuggest, lang, word, buf, cap, 40);
}
