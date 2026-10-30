import Foundation
import CryptoKit

// Release integrity check: verify the archive with the public key embedded in the app.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3,
      let publicData = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]) else {
    fputs("签名校验参数不正确。\n", stderr)
    exit(1)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[0]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: data) else {
        fputs("更新包签名与配置的公钥不匹配。\n", stderr)
        exit(1)
    }
} catch {
    fputs("无法验证更新包签名。\n", stderr)
    exit(1)
}
