import ARKit
import CoreVideo
import simd

/// A single colored point in ARKit world space (meters, +Y up).
struct ColoredPoint {
    var x: Float
    var y: Float
    var z: Float
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

/// Accumulates LiDAR depth frames into a voxel-deduplicated colored point cloud.
///
/// Every processed frame is unprojected with the camera intrinsics (scaled to the depth map
/// resolution), transformed to world space with the camera pose, and colored by sampling the
/// captured YCbCr image. Points are keyed by voxel so repeated views of the same surface do not
/// explode memory; the newest sample wins.
///
/// Not thread-safe — call only from the AR session delegate queue.
final class PointCloudBuilder {
    private var voxels: [Int64: ColoredPoint] = [:]
    private var voxelSize: Float = 0.02
    private var maxPoints = 4_000_000
    private(set) var isFull = false

    var count: Int { voxels.count }

    func reset(voxelSize: Float, maxPoints: Int) {
        voxels.removeAll(keepingCapacity: false)
        voxels.reserveCapacity(min(maxPoints, 1_000_000))
        self.voxelSize = max(0.005, voxelSize)
        self.maxPoints = maxPoints
        isFull = false
    }

    func allPoints() -> [ColoredPoint] { Array(voxels.values) }

    // MARK: - Integration

    func integrate(depth: ARDepthData,
                   camera: ARCamera,
                   image: CVPixelBuffer,
                   minConfidence: Int,
                   maxDepth: Float,
                   pixelStride: Int) {
        if isFull { return }

        let depthMap = depth.depthMap
        let confMap = depth.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        if let confMap { CVPixelBufferLockBaseAddress(confMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            if let confMap { CVPixelBufferUnlockBaseAddress(confMap, .readOnly) }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        var confBase: UnsafeMutableRawPointer? = nil
        var confRowBytes = 0
        if let confMap {
            confBase = CVPixelBufferGetBaseAddress(confMap)
            confRowBytes = CVPixelBufferGetBytesPerRow(confMap)
        }

        // Captured image: 420f bi-planar (Y plane 0, interleaved CbCr plane 1).
        guard CVPixelBufferGetPlaneCount(image) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return }
        let iw = CVPixelBufferGetWidthOfPlane(image, 0)
        let ih = CVPixelBufferGetHeightOfPlane(image, 0)
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let cRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        let cPtr = cBase.assumingMemoryBound(to: UInt8.self)

        // Intrinsics are expressed for the full-resolution captured image; scale to depth map.
        let K = camera.intrinsics
        let res = camera.imageResolution
        let sx = Float(dw) / Float(res.width)
        let sy = Float(dh) / Float(res.height)
        let fx = K[0][0] * sx
        let fy = K[1][1] * sy
        let cx = K[2][0] * sx
        let cy = K[2][1] * sy
        let imgScaleX = Float(iw) / Float(dw)
        let imgScaleY = Float(ih) / Float(dh)

        let T = camera.transform
        let invVoxel = 1 / voxelSize
        let stride = max(1, pixelStride)

        var v = 0
        while v < dh {
            let depthRow = depthBase.advanced(by: v * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confRow = confBase?.advanced(by: v * confRowBytes).assumingMemoryBound(to: UInt8.self)
            var u = 0
            while u < dw {
                let d = depthRow[u]
                if d.isFinite, d > 0.15, d < maxDepth, (confRow.map { Int($0[u]) } ?? 2) >= minConfidence {
                    // Pinhole unprojection in image coordinates (x right, y down, z forward) …
                    let xc = (Float(u) - cx) / fx * d
                    let yc = (Float(v) - cy) / fy * d
                    // … flipped into ARKit camera space (x right, y up, z backward) and moved to world.
                    let world = T * SIMD4<Float>(xc, -yc, -d, 1)

                    let key = PointCloudBuilder.voxelKey(world.x, world.y, world.z, invVoxel: invVoxel)
                    // Sample color from the full-resolution image (newest sample wins per voxel).
                    let iu = min(iw - 1, Int(Float(u) * imgScaleX))
                    let iv = min(ih - 1, Int(Float(v) * imgScaleY))
                    let Y = Float(yPtr[iv * yRowBytes + iu])
                    let cIndex = (iv / 2) * cRowBytes + (iu / 2) * 2
                    let Cb = Float(cPtr[cIndex]) - 128
                    let Cr = Float(cPtr[cIndex + 1]) - 128
                    let r = PointCloudBuilder.clamp255(Y + 1.402 * Cr)
                    let g = PointCloudBuilder.clamp255(Y - 0.344136 * Cb - 0.714136 * Cr)
                    let b = PointCloudBuilder.clamp255(Y + 1.772 * Cb)

                    voxels[key] = ColoredPoint(x: world.x, y: world.y, z: world.z, r: r, g: g, b: b)
                    if voxels.count >= maxPoints {
                        isFull = true
                        return
                    }
                }
                u += stride
            }
            v += stride
        }
    }

    // MARK: - Helpers

    @inline(__always)
    private static func clamp255(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, v.rounded())))
    }

    /// Packs three signed 21-bit voxel indices into one Int64 (±1M voxels per axis).
    @inline(__always)
    private static func voxelKey(_ x: Float, _ y: Float, _ z: Float, invVoxel: Float) -> Int64 {
        let ix = Int64((x * invVoxel).rounded(.down)) & 0x1F_FFFF
        let iy = Int64((y * invVoxel).rounded(.down)) & 0x1F_FFFF
        let iz = Int64((z * invVoxel).rounded(.down)) & 0x1F_FFFF
        return (ix << 42) | (iy << 21) | iz
    }
}
