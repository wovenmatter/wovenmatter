import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(65)
}

final class Enclosures: NSObject, XMLParserDelegate {
    var signatures: [(String, String)] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard elementName == "enclosure", let url = attributes["url"],
              let signature = attributes["sparkle:edSignature"] else { return }
        signatures.append((URL(string: url)!.lastPathComponent, signature))
    }
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let encodedKey = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "fuIqCE9IUmecB8Hjj44IcBz2XrVX/fMxenjhsTJIglI="
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: encodedKey)!)
let delegate = Enclosures()
let parser = XMLParser(contentsOf: folder.appending(path: "appcast.xml"))!
parser.delegate = delegate
guard parser.parse(), !delegate.signatures.isEmpty else { fail("No signed update enclosures") }
for (name, signature) in delegate.signatures {
    let data = try Data(contentsOf: folder.appending(path: name), options: .mappedIfSafe)
    guard let signature = Data(base64Encoded: signature), key.isValidSignature(signature, for: data) else {
        fail("Invalid update signature: \(name)")
    }
}
print("Verified Ed25519 signatures for \(delegate.signatures.count) update archive(s).")
