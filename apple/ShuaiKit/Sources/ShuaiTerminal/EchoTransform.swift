import Foundation

/// Turns bytes typed into the terminal into what a local echo would display (debug echo mode).
public enum EchoTransform {
    public static func transform(_ input: Data) -> Data {
        var out = Data()
        for byte in input {
            switch byte {
            case 0x0D: out.append(contentsOf: Array("\r\n".utf8))
            case 0x7F: out.append(contentsOf: [0x08, 0x20, 0x08])
            case 0x09: out.append(byte)
            case 0x00 ..< 0x20: out.append(contentsOf: Array("^".utf8) + [byte + 0x40])
            default: out.append(byte)
            }
        }
        return out
    }
}
