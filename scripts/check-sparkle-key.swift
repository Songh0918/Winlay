import Foundation
import CryptoKit

guard CommandLine.arguments.count == 2,
      let plist = NSDictionary(contentsOfFile: CommandLine.arguments[1]),
      let expected = plist["SUPublicEDKey"] as? String,
      let encoded = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8),
      let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
      privateKey.publicKey.rawRepresentation.base64EncodedString() == expected else {
    fputs("更新签名密钥与应用公钥不匹配。\n", stderr)
    exit(1)
}
print("更新签名密钥与应用公钥匹配。")
