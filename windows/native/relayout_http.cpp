// HTTPS GET for the update check. WinHTTP is not in Swift's WinSDK module, so it
// lives here with the other Win32 calls Swift can't reach.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>

#include "include/relayout_native.h"

namespace {

struct Handle {
    HINTERNET h;
    explicit Handle(HINTERNET handle) : h(handle) {}
    ~Handle() { if (h) WinHttpCloseHandle(h); }
};

}  // namespace

int32_t relayout_https_get(const uint16_t *host, const uint16_t *path, uint8_t *buf, int32_t cap) {
    if (!host || !path || !buf || cap <= 0) return -1;
    Handle session(WinHttpOpen(L"reLayout", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                               WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
    if (!session.h) return -1;
    WinHttpSetTimeouts(session.h, 5000, 5000, 5000, 10000);
    Handle connect(WinHttpConnect(session.h, (LPCWSTR)host, INTERNET_DEFAULT_HTTPS_PORT, 0));
    if (!connect.h) return -1;
    Handle request(WinHttpOpenRequest(connect.h, L"GET", (LPCWSTR)path, nullptr,
                                      WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                      WINHTTP_FLAG_SECURE));
    if (!request.h) return -1;
    if (!WinHttpSendRequest(request.h, L"Accept: application/vnd.github+json", (DWORD)-1,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(request.h, nullptr)) return -1;

    DWORD status = 0, size = sizeof(status);
    if (!WinHttpQueryHeaders(request.h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX) ||
        status != 200) return -1;

    int32_t total = 0;
    for (;;) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request.h, &available) || available == 0) break;
        if (total + (int32_t)available > cap) return -1;   // larger than any release reply
        DWORD read = 0;
        if (!WinHttpReadData(request.h, buf + total, available, &read) || read == 0) break;
        total += (int32_t)read;
    }
    return total;
}
