import Foundation

/// Binary little-endian PLY writer (x y z float32, r g b uint8) — readable by CloudCompare,
/// Open3D, nerfstudio (`ply_file_path`), gsplat, and the Python tool in `tools/`.
enum PointCloudExporter {

    static let bytesPerPoint = 15

    static func writePLY(points: [ColoredPoint], to url: URL) throws {
        let header = """
        ply
        format binary_little_endian 1.0
        comment Spacan LiDAR point cloud — meters, ARKit world frame (+Y up)
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        var data = Data(header.utf8)
        var body = [UInt8](repeating: 0, count: points.count * bytesPerPoint)
        body.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            for p in points {
                base.storeBytes(of: p.x.bitPattern.littleEndian, toByteOffset: off, as: UInt32.self)
                base.storeBytes(of: p.y.bitPattern.littleEndian, toByteOffset: off + 4, as: UInt32.self)
                base.storeBytes(of: p.z.bitPattern.littleEndian, toByteOffset: off + 8, as: UInt32.self)
                base.storeBytes(of: p.r, toByteOffset: off + 12, as: UInt8.self)
                base.storeBytes(of: p.g, toByteOffset: off + 13, as: UInt8.self)
                base.storeBytes(of: p.b, toByteOffset: off + 14, as: UInt8.self)
                off += bytesPerPoint
            }
        }
        data.append(contentsOf: body)
        try data.write(to: url, options: .atomic)
    }

    /// Reads back a PLY written by `writePLY` (used by the in-app viewer). Returns at most `maxPoints`
    /// points by uniform striding.
    static func readPLY(at url: URL, maxPoints: Int) -> [ColoredPoint] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        guard let endRange = data.range(of: Data("end_header\n".utf8)) else { return [] }
        let header = String(decoding: data[data.startIndex..<endRange.lowerBound], as: UTF8.self)
        guard let line = header.split(separator: "\n").first(where: { $0.hasPrefix("element vertex") }),
              let n = Int(line.split(separator: " ").last ?? "") else { return [] }

        let body = data[endRange.upperBound...]
        guard body.count >= n * bytesPerPoint else { return [] }
        let step = max(1, Int((Double(n) / Double(max(1, maxPoints))).rounded(.up)))

        var out: [ColoredPoint] = []
        out.reserveCapacity(n / step + 1)
        body.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var i = 0
            while i < n {
                let off = i * bytesPerPoint
                let x = Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
                let y = Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)))
                let z = Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self)))
                let r = base.load(fromByteOffset: off + 12, as: UInt8.self)
                let g = base.load(fromByteOffset: off + 13, as: UInt8.self)
                let b = base.load(fromByteOffset: off + 14, as: UInt8.self)
                out.append(ColoredPoint(x: x, y: y, z: z, r: r, g: g, b: b))
                i += step
            }
        }
        return out
    }
}
