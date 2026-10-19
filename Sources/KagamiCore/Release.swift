import Foundation

/// A dotted version: "1.2.3" or a tag like "v1.2.3".
public struct Version: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ s: String) {
        let p = s.split(separator: ".").map { Int($0) }
        guard (2...4).contains(p.count), p.allSatisfy({ $0 != nil && $0! >= 0 && $0! < 10_000 }) else { return nil }
        parts = p.compactMap { $0 }
    }

    /// Only plain tags like v1.2.3: the tag ends up in a file name and a gh argument.
    public init?(tag: String) {
        guard tag.wholeMatch(of: #/v\d{1,4}(\.\d{1,4}){1,3}/#) != nil else { return nil }
        self.init(String(tag.dropFirst()))
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    /// 1.0 and 1.0.0 are the same version.
    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}


public enum ReleaseStatus {
    /// True when gpg's --status-fd lines carry a VALIDSIG whose primary key is the pinned one.
    public static func signedBy(_ fingerprint: String, status: String) -> Bool {
        status.split(separator: "\n").contains { line in
            let f = line.split(separator: " ")
            // [GNUPG:] VALIDSIG <fpr> <date> <ts> <exp> <ver> <res> <pk-algo> <hash-algo> <class> <primary-fpr>
            return f.count >= 12 && f[1] == "VALIDSIG" && f[11].uppercased() == fingerprint.uppercased()
        }
    }
}
