import WinSDK
import Foundation
import Dispatch
import ReLayoutCore
import RelayoutNative

// Update check, the light form of the macOS Sparkle updater: asks GitHub for the
// latest release a minute after start and then daily, and if it is newer shows one
// tray notice per version plus a menu item that opens the release page. Nothing is
// downloaded or installed. Dev builds skip it and show no menu item.

private let firstCheckTimer: UINT_PTR = 10
private let dailyCheckTimer: UINT_PTR = 11

/// The newer release tag, once a check found one ("v1.3.0").
private(set) var availableUpdate: String?

var releasePageURL: String { "https://github.com/\(repoSlug)/releases/latest" }

/// Only a release build checks: its version is a number ("1.2.27"). Local builds
/// say "dev", CI's untagged ones "0.0.0-dev" — neither parses as newer than 0.
var updatesEnabled: Bool { isNewerVersion(appVersion, than: "0") }

func scheduleUpdateChecks(_ hwnd: HWND?) {
    guard updatesEnabled else { return }
    SetTimer(hwnd, firstCheckTimer, 60_000, nil)
    SetTimer(hwnd, dailyCheckTimer, 24 * 60 * 60 * 1000, nil)
}

/// Handles the tray window's timers; returns true when the timer was ours.
func handleUpdateTimer(_ hwnd: HWND?, _ id: WPARAM) -> Bool {
    guard id == WPARAM(firstCheckTimer) || id == WPARAM(dailyCheckTimer) else { return false }
    if id == WPARAM(firstCheckTimer) { KillTimer(hwnd, firstCheckTimer) }
    checkForUpdates(hwnd, manual: false)
    return true
}

/// Runs the request off the UI thread (it blocks up to ~20 s) and hands each answer
/// back with its own request, so overlapping checks cannot take each other's.
func checkForUpdates(_ hwnd: HWND?, manual: Bool) {
    guard updatesEnabled else {
        if manual { showMessage(L("win.update.latest")) }
        return
    }
    DispatchQueue.global().async {
        let tag = latestReleaseTag()
        postToUI { handleUpdateResult(tag, manual: manual) }
    }
}

/// Remembers a newer release, tells the user once per version (or always, for a
/// manual check).
/// - Parameter tag: the latest release's tag; nil when the check failed.
private func handleUpdateResult(_ tag: String?, manual: Bool) {
    guard let tag else {
        if manual { showMessage(L("win.update.failed")) }
        return
    }
    guard isNewerVersion(tag, than: appVersion) else {
        if manual { showMessage(L("win.update.latest")) }
        return
    }
    availableUpdate = tag
    if manual {
        openExternally(releasePageURL)
    } else if loadNotifiedUpdate() != tag {
        saveNotifiedUpdate(tag)
        showTrayNotice(title: "reLayout", text: L("win.update.notice", tag))
    }
}

private func showMessage(_ text: String) {
    text.withCString(encodedAs: UTF16.self) { t in
        "reLayout".withCString(encodedAs: UTF16.self) { c in
            _ = MessageBoxW(nil, t, c, UINT(MB_ICONINFORMATION))
        }
    }
}

// MARK: - GitHub API

private func latestReleaseTag() -> String? {
    var body = [UInt8](repeating: 0, count: 1 << 20)   // a release reply is a few KB
    let n = "api.github.com".withCString(encodedAs: UTF16.self) { host in
        "/repos/\(repoSlug)/releases/latest".withCString(encodedAs: UTF16.self) { path in
            relayout_https_get(host, path, &body, Int32(body.count))
        }
    }
    guard n > 0 else { return nil }
    let json = try? JSONSerialization.jsonObject(with: Data(body.prefix(Int(n)))) as? [String: Any]
    return json?["tag_name"] as? String
}
