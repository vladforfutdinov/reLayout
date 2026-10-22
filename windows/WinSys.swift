import WinSDK

// Win32 stand-ins for the Foundation calls the port made: Foundation ships ICU and
// its own DLLs, ~45 MB, with the app.

/// A UTF-8 text file's contents, without a byte-order mark; nil when it can't be read.
func readTextFile(_ path: String) -> String? {
    let h = path.withCString(encodedAs: UTF16.self) {
        CreateFileW($0, DWORD(0x8000_0000) /* GENERIC_READ */, DWORD(FILE_SHARE_READ),
                    nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
    }
    guard let h, h != INVALID_HANDLE_VALUE else { return nil }
    defer { CloseHandle(h) }
    var size = LARGE_INTEGER()
    guard GetFileSizeEx(h, &size), size.QuadPart >= 0, size.QuadPart < 64 << 20 else { return nil }
    var bytes = [UInt8](repeating: 0, count: Int(size.QuadPart))
    var read: DWORD = 0
    if !bytes.isEmpty {
        guard ReadFile(h, &bytes, DWORD(bytes.count), &read, nil), Int(read) == bytes.count else { return nil }
    }
    let body = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes.dropFirst(3) : bytes[...]
    return String(decoding: body, as: UTF8.self)
}

/// Names of the subdirectories of `dir`.
func subdirectories(_ dir: String) -> [String] {
    var data = WIN32_FIND_DATAW()
    let h = "\(dir)\\*".withCString(encodedAs: UTF16.self) { FindFirstFileW($0, &data) }
    guard let h, h != INVALID_HANDLE_VALUE else { return [] }
    defer { FindClose(h) }
    var names: [String] = []
    repeat {
        let name = withUnsafeBytes(of: data.cFileName) { raw in
            String(decoding: raw.bindMemory(to: WCHAR.self).prefix(while: { $0 != 0 }), as: UTF16.self)
        }
        if data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0, name != ".", name != ".." { names.append(name) }
    } while FindNextFileW(h, &data)
    return names
}

private final class ThreadBody {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// Runs `body` on a new thread of its own.
func startThread(_ body: @escaping () -> Void) {
    let ctx = Unmanaged.passRetained(ThreadBody(body)).toOpaque()
    let thread = CreateThread(nil, 0, { p in
        Unmanaged<ThreadBody>.fromOpaque(p!).takeRetainedValue().run()
        return 0
    }, ctx, 0, nil)
    if let thread { CloseHandle(thread) } else { Unmanaged<ThreadBody>.fromOpaque(ctx).release() }
}

/// `s` without leading and trailing whitespace.
func trimmed<S: StringProtocol>(_ s: S) -> String {
    String(s.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
}
