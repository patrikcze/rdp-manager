import Foundation
import RDPManagerCore

/// Reads a key file's type and fingerprint with `ssh-keygen -l`, off the main actor. Only the
/// public part is read: the `.pub` next to the key, else the public key a new-format private
/// key carries in the clear. No passphrase is ever asked for or passed.
enum SSHKeyInspector {
    static func describe(_ path: String) async -> SSHKeyDescription? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = SSHSecretPolicy.expandTilde(path, home: home)
        return await Task.detached(priority: .userInitiated) {
            for candidate in [expanded + ".pub", expanded] where FileManager.default.isReadableFile(atPath: candidate) {
                if let description = run(candidate) { return description }
            }
            return nil
        }.value
    }

    private static func run(_ path: String) -> SSHKeyDescription? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommandBuilder.sshKeygenPath)
        process.arguments = ["-l", "-E", "sha256", "-f", path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile().prefix(4096)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return SSHKeyDescription.parse(String(decoding: data, as: UTF8.self))
    }
}
