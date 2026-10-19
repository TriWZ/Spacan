import ARKit
import Foundation

/// Finalizes a recording into a self-contained bundle folder:
///
///     Scan_YYYYMMDD_HHMMSS/
///       meta.json          scan metadata (counts, intrinsics, coordinate-system note)
///       mesh.obj           LiDAR scene mesh, world coords, meters
///       cloud.ply          colored point cloud, world coords, meters
///       transforms.json    nerfstudio / instant-ngp camera file (+ ply_file_path seed points)
///       images/            keyframe JPEGs (sensor orientation)
///       depth/             raw float32 depth + uint8 confidence per keyframe
enum ScanBundleWriter {

    struct Input {
        var folder: URL
        var id: String
        var name: String
        var durationSeconds: Double
        var anchors: [ARMeshAnchor]
        var points: [ColoredPoint]
        var frames: [KeyframeRecorder.Frame]
        var depthSize: (width: Int, height: Int)
        var imageSize: (width: Int, height: Int)
        var voxelSize: Float
        var minConfidence: Int
        var maxDepth: Float
    }

    static func write(_ input: Input, progress: @escaping (Double, String) -> Void) throws -> ScanMeta {
        progress(0.02, "写入 mesh…")
        let meshStats = try MeshExporter.writeOBJ(anchors: input.anchors,
                                                  to: input.folder.appendingPathComponent("mesh.obj")) { p in
            progress(0.02 + 0.45 * p, "写入 mesh…")
        }

        progress(0.5, "写入点云…")
        try PointCloudExporter.writePLY(points: input.points,
                                        to: input.folder.appendingPathComponent("cloud.ply"))

        progress(0.85, "写入相机位姿…")
        try writeTransforms(frames: input.frames,
                            depthSize: input.depthSize,
                            to: input.folder.appendingPathComponent("transforms.json"))

        progress(0.95, "写入元数据…")
        let meta = ScanMeta(
            id: input.id,
            name: input.name,
            createdAt: Date(),
            durationSeconds: input.durationSeconds,
            deviceModel: DeviceInfo.machine,
            appVersion: ScanStore.appVersion,
            meshAnchorCount: meshStats.anchors,
            meshVertexCount: meshStats.vertices,
            meshFaceCount: meshStats.faces,
            pointCount: input.points.count,
            keyframeCount: input.frames.count,
            voxelSizeMeters: input.voxelSize,
            minConfidence: input.minConfidence,
            maxDepthMeters: input.maxDepth,
            imageWidth: input.imageSize.width,
            imageHeight: input.imageSize.height,
            depthWidth: input.depthSize.width,
            depthHeight: input.depthSize.height,
            coordinateSystem: "ARKit world: right-handed, meters, +Y up (gravity), origin = device pose at record start. Camera poses are camera-to-world, OpenGL convention (camera looks -Z, +Y up). Images in sensor (landscape) orientation; intrinsics apply to that orientation.",
            notes: ""
        )
        try ScanStore.saveMeta(meta)
        progress(1, "完成")
        return meta
    }

    /// nerfstudio / instant-ngp style camera file. Per-frame intrinsics are included because
    /// autofocus can change them slightly during a walk.
    private static func writeTransforms(frames: [KeyframeRecorder.Frame],
                                        depthSize: (width: Int, height: Int),
                                        to url: URL) throws {
        var root: [String: Any] = [
            "camera_model": "OPENCV",
            "k1": 0, "k2": 0, "p1": 0, "p2": 0,
            "ply_file_path": "cloud.ply",
            "applied_transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]],
            "sitescan": [
                "convention": "camera_to_world, OpenGL (x right, y up, z backward)",
                "units": "meters",
                "depth_raw_format": "float32 little-endian row-major, meters, 0 = invalid",
                "depth_width": depthSize.width,
                "depth_height": depthSize.height,
                "confidence_raw_format": "uint8 row-major, 0=low 1=medium 2=high"
            ]
        ]
        if let f = frames.first {
            root["fl_x"] = Double(f.fx)
            root["fl_y"] = Double(f.fy)
            root["cx"] = Double(f.cx)
            root["cy"] = Double(f.cy)
            root["w"] = f.width
            root["h"] = f.height
        }
        root["frames"] = frames.map { f -> [String: Any] in
            var d: [String: Any] = [
                "file_path": f.imageFile,
                "transform_matrix": f.transform.rowMajor,
                "fl_x": Double(f.fx), "fl_y": Double(f.fy),
                "cx": Double(f.cx), "cy": Double(f.cy),
                "w": f.width, "h": f.height,
                "timestamp": f.timestamp
            ]
            if let depth = f.depthFile { d["depth_raw"] = depth }
            if let conf = f.confidenceFile { d["confidence_raw"] = conf }
            return d
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
