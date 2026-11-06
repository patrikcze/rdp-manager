// RDPManagerAskpass: OpenSSH's SSH_ASKPASS helper for RDP Manager's terminal sessions.
//
// OpenSSH runs it with the prompt as the only argument (and SSH_ASKPASS_PROMPT as a hint)
// whenever it needs an answer: a host key confirmation, a password, a key passphrase, a
// keyboard-interactive code. The helper does nothing but relay: it sends the prompt to the
// session that started this ssh, over the Unix socket named in RDPM_ASKPASS_SOCKET, and
// prints the answer the app sends back. It never touches the Keychain, keeps nothing and
// logs nothing. The app checks that the connection comes from this helper, running as a
// descendant of its own ssh process, and decides itself whether and how to answer.
//
// Wire format, all lengths 32-bit big-endian:
//   request:  len(hint) hint len(prompt) prompt
//   response: status (0 answer, 1 cancel) len(answer) answer

import Darwin

let maximumLength: UInt32 = 65536

func fail() -> Never {
    exit(1)
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { return false }
        offset += written
    }
    return true
}

func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
        let received = buffer[offset...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if received < 0, errno == EINTR { continue }
        guard received > 0 else { return nil }
        offset += received
    }
    return buffer
}

func lengthPrefixed(_ text: String) -> [UInt8] {
    let bytes = Array(text.utf8.prefix(Int(maximumLength)))
    let length = UInt32(bytes.count).bigEndian
    return withUnsafeBytes(of: length) { Array($0) } + bytes
}

guard let socketPath = getenv("RDPM_ASKPASS_SOCKET").map({ String(cString: $0) }),
      socketPath.utf8.count < 104
else { fail() }
let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let hint = getenv("SSH_ASKPASS_PROMPT").map { String(cString: $0) } ?? ""

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail() }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    let bytes = Array(socketPath.utf8)
    buffer.copyBytes(from: bytes)
    buffer[bytes.count] = 0
}
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { fail() }
guard writeAll(fd, lengthPrefixed(hint) + lengthPrefixed(prompt)) else { fail() }

guard let header = readExactly(fd, 5) else { fail() }
let length = header[1 ... 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
guard header[0] == 0, length <= maximumLength else { fail() }
guard var answer = readExactly(fd, Int(length)) else { fail() }
close(fd)
answer.append(0x0A)
let printed = writeAll(STDOUT_FILENO, answer)
// Don't leave the answer in this process's memory longer than needed.
for index in answer.indices { answer[index] = 0 }
exit(printed ? 0 : 1)
