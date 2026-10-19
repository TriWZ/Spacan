import Foundation
import simd

extension SIMD4 where Scalar == Float {
    /// Drops the homogeneous component.
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}

extension simd_float4x4 {
    /// Row-major nested array (what transforms.json / COLMAP tooling expects).
    /// simd matrices are column-major: self[column][row].
    var rowMajor: [[Double]] {
        (0..<4).map { r in (0..<4).map { c in Double(self[c][r]) } }
    }

    var translation: SIMD3<Float> { columns.3.xyz }

    /// Upper-left 3x3 (rotation for rigid transforms).
    var rotation3x3: simd_float3x3 {
        simd_float3x3(columns: (columns.0.xyz, columns.1.xyz, columns.2.xyz))
    }
}

enum DeviceInfo {
    /// e.g. "iPhone16,1" — more useful than UIDevice.model for provenance.
    static var machine: String {
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }
}

enum NumberFormat {
    /// Fast fixed-point formatter with 4 decimals (0.1 mm). Avoids String(format:) cost on millions of values.
    @inline(__always)
    static func fixed4(_ v: Float) -> String {
        let scaled = Int((v * 10_000).rounded())
        let sign = scaled < 0 ? "-" : ""
        let a = abs(scaled)
        let intPart = a / 10_000
        let frac = a % 10_000
        let fracStr = String(frac)
        return sign + String(intPart) + "." + String(repeating: "0", count: 4 - fracStr.count) + fracStr
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func count(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return String(n)
    }
}
