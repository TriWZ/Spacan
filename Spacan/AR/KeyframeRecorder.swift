import ARKit
import CoreImage
import ImageIO
import simd

/// Saves sparse keyframes (JPEG + camera pose + intrinsics, optionally raw depth/confidence)
/// for downstream Gaussian-splat / NeRF training.
///
/// Poses are camera-to-world in ARKit convention (right-handed, camera looks down -Z, +Y up),
/// which is exactly the OpenGL/Blender convention that nerfstudio's transforms.json expects.
/// Images are stored in their native sensor orientation (landscape) so the intrinsics apply as-is.
///
/// Not thread-safe — call only from the AR session delegate queue.
final class KeyframeRecorder {

    struct Frame {
        var index: Int
        var imageFile: String          // relative to scan folder
        var depthFile: String?         // float32 little-endian, depthWidth*depthHeight, meters, 0 = invalid
        var confidenceFile: String?    // uint8, same layout, 0=low 1=medium 2=high
        var transform: simd_float4x4   // camera-to-world
        var fx: Float
        var fy: Float
        var cx: Float
        var cy: Float
        var width: Int
        var height: Int
        var timestamp: TimeInterval
    }

    private(set) var frames: [Frame] = []
    private(set) var depthSize: (width: Int, height: Int) = (0, 0)
    private(set) var imageSize: (width: Int, height: Int) = (0, 0)

    private var folder: URL?
    private var lastTimestamp: TimeInterval = -.infinity
    private var lastTransform: simd_float4x4?
    private var jpegQuality: Double = 0.85
    private var saveDepth = true
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func reset(folder: URL, jpegQuality: Double, saveDepth: Bool) {
        frames.removeAll()
        self.folder = folder
        self.jpegQuality = jpegQuality
        self.saveDepth = saveDepth
        lastTimestamp = -.infinity
        lastTransform = nil
        depthSize = (0, 0)
        imageSize = (0, 0)
    }

    /// Decides whether this frame becomes a keyframe (time + motion gating) and saves it if so.
    func consider(frame: ARFrame,
                  minInterval: TimeInterval,
                  minDistance: Float,
                  minAngleDegrees: Float) {
        guard let folder else { return }
        guard case .normal = frame.camera.trackingState else { return }

        let t = frame.timestamp
        guard t - lastTimestamp >= minInterval else { return }

        let T = frame.camera.transform
        if let L = lastTransform {
            let dist = simd_distance(T.translation, L.translation)
            let qa = simd_quatf(L.rotation3x3)
            let qb = simd_quatf(T.rotation3x3)
            let delta = (qa.inverse * qb).angle               // in [0, 2π]; fold to the shortest arc
            let angle = min(delta, 2 * .pi - delta) * 180 / .pi
            guard dist >= minDistance || angle >= minAngleDegrees else { return }
        }

        let index = frames.count + 1
        let name = String(format: "frame_%05d", index)

        // --- JPEG ---
        let imageFile = "images/\(name).jpg"
        let ci = CIImage(cvPixelBuffer: frame.capturedImage)
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality
        ]
        guard let jpeg = ciContext.jpegRepresentation(of: ci, colorSpace: CGColorSpaceCreateDeviceRGB(), options: opts) else { return }
        do {
            try jpeg.write(to: folder.appendingPathComponent(imageFile), options: .atomic)
        } catch {
            return
        }

        // --- Raw depth + confidence (optional) ---
        var depthFile: String? = nil
        var confFile: String? = nil
        if saveDepth, let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
            if let data = KeyframeRecorder.copyPlane(depth.depthMap, bytesPerPixel: 4) {
                depthFile = "depth/\(name).bin"
                try? data.write(to: folder.appendingPathComponent(depthFile!), options: .atomic)
                depthSize = (CVPixelBufferGetWidth(depth.depthMap), CVPixelBufferGetHeight(depth.depthMap))
            }
            if let conf = depth.confidenceMap, let data = KeyframeRecorder.copyPlane(conf, bytesPerPixel: 1) {
                confFile = "depth/\(name).conf"
                try? data.write(to: folder.appendingPathComponent(confFile!), options: .atomic)
            }
        }

        let K = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        imageSize = (Int(res.width), Int(res.height))

        frames.append(Frame(index: index,
                            imageFile: imageFile,
                            depthFile: depthFile,
                            confidenceFile: confFile,
                            transform: T,
                            fx: K[0][0], fy: K[1][1], cx: K[2][0], cy: K[2][1],
                            width: Int(res.width), height: Int(res.height),
                            timestamp: t))
        lastTimestamp = t
        lastTransform = T
    }

    /// Copies a single-plane pixel buffer into tightly packed Data (drops row padding).
    private static func copyPlane(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let rowLen = w * bytesPerPixel
        var data = Data(capacity: rowLen * h)
        for row in 0..<h {
            data.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: rowLen)
        }
        return data
    }
}
