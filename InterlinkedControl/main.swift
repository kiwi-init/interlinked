import Darwin
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let request = args.isEmpty ? "state" : args.joined(separator: " ")

let path: String
if let named = ProcessInfo.processInfo.environment["INTERLINKED_SOCKET"] {
    path = named
} else {
    let user = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
    path = "/tmp/interlinked-\(user).sock"
}

let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
    fputs("interlinked: could not create a socket\n", stderr)
    exit(1)
}

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(path.utf8CString)
withUnsafeMutableBytes(of: &addr.sun_path) { dest in
    guard let base = dest.baseAddress else { return }
    memcpy(base, pathBytes, min(pathBytes.count, dest.count))
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
_ = payload.withCString { cstr in Darwin.write(fd, cstr, strlen(cstr)) }

var data = Data()
var byte: UInt8 = 0
while Darwin.read(fd, &byte, 1) == 1 {
    if byte == 10 { break }
    if byte != 13 { data.append(byte) }
}
Darwin.close(fd)

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
