// Update signing for DayStack. The private key never leaves this Mac; the app only trusts
// updates signed with it.
//   swift scripts/sign-update.swift pubkey          → prints the public key (creates the key once)
//   swift scripts/sign-update.swift sign <file>     → prints a base64 signature of <file>
//   swift scripts/sign-update.swift verify <file> <signature>
import CryptoKit
import Foundation

let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/DayStack-Publisher", isDirectory: true)
let keyURL = dir.appendingPathComponent("update-signing.key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sign-update: \(message)\n".utf8))
    exit(1)
}

func loadOrCreateKey() -> Curve25519.Signing.PrivateKey {
    if let data = try? Data(contentsOf: keyURL) {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("key file is corrupt: \(keyURL.path)") }
        return key
    }
    let key = Curve25519.Signing.PrivateKey()
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: keyURL.path, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600])
    } catch {
        fail("couldn't save key: \(error)")
    }
    FileHandle.standardError.write(Data("sign-update: created a new signing key at \(keyURL.path). Back it up; without it you can't publish updates friends will accept.\n".utf8))
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "pubkey":
    print(loadOrCreateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 2, let data = FileManager.default.contents(atPath: args[args.startIndex + 1]) else { fail("usage: sign <file>") }
    guard let sig = try? loadOrCreateKey().signature(for: data) else { fail("signing failed") }
    print(sig.base64EncodedString())
case "verify":
    guard args.count == 3, let data = FileManager.default.contents(atPath: args[args.startIndex + 1]),
          let sig = Data(base64Encoded: args[args.startIndex + 2]) else { fail("usage: verify <file> <signature>") }
    let ok = loadOrCreateKey().publicKey.isValidSignature(sig, for: data)
    print(ok ? "valid" : "INVALID")
    exit(ok ? 0 : 1)
default:
    fail("usage: pubkey | sign <file> | verify <file> <signature>")
}
