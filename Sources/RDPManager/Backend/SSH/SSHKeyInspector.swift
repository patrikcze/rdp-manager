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

/// Asks OpenSSH (`ssh -G`, which never connects) whether `~/.ssh/config` sends a target through
/// a jump host or proxy command, off the main actor.
enum SSHConfigProbe {
    static func usesProxy(_ target: SSHTarget) async -> Bool {
        guard let arguments = try? SSHCommandBuilder.configQueryArguments(for: target) else { return false }
        let environment = SSHCommandBuilder.environment(from: ProcessInfo.processInfo.environment, terminalType: "dumb",
                                                        sendEnvironment: [], askpassHelper: "/usr/bin/false", askpassSocket: "")
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: SSHCommandBuilder.sshPath)
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile().prefix(256 * 1024)
            process.waitUntilExit()
            return SSHCommandBuilder.configUsesProxy(String(decoding: data, as: UTF8.self))
        }.value
    }
}
