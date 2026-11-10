import AppKit
import CryptoKit
import CoreImage

/// QR pairing: this Mac has one random id + 256-bit key. The phone scans
/// `phonecast:pair?v=1&id=…&k=…&n=…` once; afterwards both prove they know the key (HMAC over a nonce
/// the phone picks), so no PIN is typed and nothing secret crosses the network.
enum Pairing {
    static var id: String { ensure().0 }
    static var key: Data { ensure().1 }

    private static func ensure() -> (String, Data) {
        let d = UserDefaults.standard
        if let i = d.string(forKey: "pairId"), let k = d.data(forKey: "pairKey"), k.count == 32 { return (i, k) }
        var b = [UInt8](repeating: 0, count: 40)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        let i = b[0..<8].map { String(format: "%02x", $0) }.joined()
        let k = Data(b[8..<40])
        d.set(i, forKey: "pairId"); d.set(k, forKey: "pairKey")
        return (i, k)
    }

    /// New id + key: every phone paired by QR has to scan again.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: "pairId"); UserDefaults.standard.removeObject(forKey: "pairKey")
        UserDefaults.standard.removeObject(forKey: "qrPaired")
    }

    static var name: String { Host.current().localizedName ?? "Mac" }

    static var uri: String {
        let n = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Mac"
        return "phonecast:pair?v=1&id=\(id)&k=\(key.map { String(format: "%02x", $0) }.joined())&n=\(n)"
    }

    /// HMAC-SHA256(key, nonce || label [|| extra]) — the proofs both sides send.
    static func proof(_ nonce: Data, _ label: String, _ extra: String = "") -> Data {
        var h = HMAC<SHA256>(key: SymmetricKey(data: key))
        h.update(data: nonce); h.update(data: Data(label.utf8)); h.update(data: Data(extra.utf8))
        return Data(h.finalize())
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// The QR code as a crisp image.
    static func qrImage(size: CGFloat) -> NSImage {
        let f = CIFilter(name: "CIQRCodeGenerator")!
        f.setValue(Data(uri.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return NSImage() }
        let scale = size / out.extent.width
        let img = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: img)
        let ns = NSImage(size: rep.size); ns.addRepresentation(rep)
        return ns
    }
}
