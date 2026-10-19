import ARKit
import Foundation
import simd

/// Writes ARKit's scene-reconstruction mesh (all ARMeshAnchors) as a single Wavefront OBJ
/// in world coordinates (meters, +Y up). Each anchor becomes an `o` group so you can still
/// tell chunks apart in Blender / CloudCompare.
enum MeshExporter {

    struct Stats {
        var anchors = 0
        var vertices = 0
        var faces = 0
    }

    static func writeOBJ(anchors: [ARMeshAnchor], to url: URL, progress: (Double) -> Void) throws -> Stats {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        fm.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var stats = Stats()
        stats.anchors = anchors.count

        try handle.write(contentsOf: Data("# SiteScan mesh export — ARKit LiDAR scene reconstruction\n# units: meters, right-handed, +Y up (ARKit world), origin = recording start\n".utf8))

        var indexOffset = 0
        for (i, anchor) in anchors.enumerated() {
            let g = anchor.geometry
            let T = anchor.transform
            let R = T.rotation3x3

            let vCount = g.vertices.count
            let fCount = g.faces.count
            var s = ""
            s.reserveCapacity(vCount * 52 + fCount * 44)
            s += "o anchor_\(i)\n"

            // Vertices (packed float3, stride typically 12)
            let vb = g.vertices.buffer.contents()
            let vOff = g.vertices.offset
            let vStride = g.vertices.stride
            for v in 0..<vCount {
                let p = vb.advanced(by: vOff + v * vStride)
                let x = p.loadUnaligned(as: Float.self)
                let y = p.loadUnaligned(fromByteOffset: 4, as: Float.self)
                let z = p.loadUnaligned(fromByteOffset: 8, as: Float.self)
                let w = T * SIMD4<Float>(x, y, z, 1)
                s += "v \(NumberFormat.fixed4(w.x)) \(NumberFormat.fixed4(w.y)) \(NumberFormat.fixed4(w.z))\n"
            }

            // Normals
            let nb = g.normals.buffer.contents()
            let nOff = g.normals.offset
            let nStride = g.normals.stride
            let hasNormals = g.normals.count == vCount
            if hasNormals {
                for v in 0..<vCount {
                    let p = nb.advanced(by: nOff + v * nStride)
                    let n = SIMD3<Float>(p.loadUnaligned(as: Float.self),
                                         p.loadUnaligned(fromByteOffset: 4, as: Float.self),
                                         p.loadUnaligned(fromByteOffset: 8, as: Float.self))
                    let wn = simd_normalize(R * n)
                    s += "vn \(NumberFormat.fixed4(wn.x)) \(NumberFormat.fixed4(wn.y)) \(NumberFormat.fixed4(wn.z))\n"
                }
            }

            // Faces (1-based OBJ indices)
            let fb = g.faces.buffer.contents()
            let bpi = g.faces.bytesPerIndex
            let ipp = g.faces.indexCountPerPrimitive
            for f in 0..<fCount {
                s += "f"
                for k in 0..<ipp {
                    let off = (f * ipp + k) * bpi
                    let raw: Int = bpi == 4
                        ? Int(fb.loadUnaligned(fromByteOffset: off, as: UInt32.self))
                        : Int(fb.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                    let idx = raw + indexOffset + 1
                    s += hasNormals ? " \(idx)//\(idx)" : " \(idx)"
                }
                s += "\n"
            }

            indexOffset += vCount
            stats.vertices += vCount
            stats.faces += fCount
            try handle.write(contentsOf: Data(s.utf8))
            progress(Double(i + 1) / Double(max(1, anchors.count)))
        }
        return stats
    }
}
