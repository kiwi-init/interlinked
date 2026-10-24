import Darwin
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let request = args.isEmpty ? "state" : args.joined(separator: " ")

let path: String
if let named = ProcessInfo.processInfo.environment["INTERLINKED_SOCKET"], !named.isEmpty {
    path = named
} else if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
    path = base.appendingPathComponent("Interlinked/control/control.sock").path
} else {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    path = (home as NSString).appendingPathComponent("Library/Application Support/Interlinked/control/control.sock")
}

let probe = sockaddr_un()
let sunPathCapacity = MemoryLayout.size(ofValue: probe.sun_path)
let pathByteCount = path.utf8CString.count
guard pathByteCount <= sunPathCapacity else {
    fputs("interlinked: control socket path too long\n", stderr)
    exit(1)
}
// The server caps requests at 64 KB; refuse oversize input locally.
guard request.utf8.count + 1 <= 64 * 1024 else {
    fputs("interlinked: request too large (64 KB max)\n", stderr)
    exit(1)
}

let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
    fputs("interlinked: could not create a socket\n", stderr)
    exit(1)
}
defer { Darwin.close(fd) }

var noSigPipe: Int32 = 1
_ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
var tv = timeval()
tv.tv_sec = __darwin_time_t(10)
tv.tv_usec = __darwin_suseconds_t(0)
_ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
_ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
memset(&addr.sun_path, 0, sunPathCapacity)
let filled = path.withCString { cstr in
    withUnsafeMutableBytes(of: &addr.sun_path) { dest -> Bool in
        guard let base = dest.baseAddress else { return false }
        memcpy(base, cstr, pathByteCount)
        return true
    }
}
guard filled else {
    fputs("interlinked: control socket path too long\n", stderr)
    exit(1)
}

let connected: Int32 = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
        Darwin.connect(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}

guard connected == 0 else {
    fputs("interlinked: nothing listening on \(path) — is the app running?\n", stderr)
    exit(1)
}

let payload = request + "\n"
let writeOK: Bool = payload.withCString { cstr -> Bool in
    var ptr = UnsafeRawPointer(cstr)
    var remaining = strlen(cstr)
    while remaining > 0 {
        let written = Darwin.write(fd, ptr, remaining)
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        if written == 0 { return false }
        remaining -= Int(written)
        ptr = ptr.advanced(by: Int(written))
    }
    return true
}
guard writeOK else {
    fputs("interlinked: failed to send request\n", stderr)
    exit(1)
}

// Replies (state snapshots) can exceed the 64 KB request cap; allow a few MB.
let maxReplyBytes = 4 * 1024 * 1024
var data = Data()
data.reserveCapacity(4096)
var chunk = [UInt8](repeating: 0, count: 4096)
var sawNewline = false
var tooLarge = false
while !sawNewline && !tooLarge {
    let n = chunk.withUnsafeMutableBytes { buf -> Int in
        guard let base = buf.baseAddress else { return -1 }
        return Darwin.read(fd, base, buf.count)
    }
    if n == 0 { break }
    if n < 0 {
        if errno == EINTR { continue }
        break
    }
    for i in 0..<n {
        let byte = chunk[i]
        if byte == 10 {
            sawNewline = true
            break
        }
        if byte == 13 { continue }
        if data.count >= maxReplyBytes {
            tooLarge = true
            break
        }
        data.append(byte)
    }
}
guard !tooLarge else {
    fputs("interlinked: reply too large\n", stderr)
    exit(1)
}
// Every reply ends in a newline. Without one the app closed the connection
// or stalled past the timeout, and a script must not read that as success.
guard sawNewline else {
    // quit ends the app before it can answer.
    if request == "quit" { exit(0) }
    fputs("interlinked: no reply from \(path)\n", stderr)
    exit(1)
}

let reply = String(data: data, encoding: .utf8) ?? ""
if let json = try? JSONSerialization.jsonObject(with: data),
   let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
   let text = String(data: pretty, encoding: .utf8) {
    print(text)
} else {
    print(reply)
}

if reply.hasPrefix("error ") {
    exit(1)
}
