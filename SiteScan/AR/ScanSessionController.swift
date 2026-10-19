import ARKit
import Combine
import Foundation
import RealityKit

/// Owns the AR session, accumulates mesh anchors / point cloud / keyframes while recording,
/// and finalizes everything into a scan bundle. UI state is published on the main thread;
/// all capture work happens on a private serial queue (ARKit delivers frames there).
final class ScanSessionController: NSObject, ObservableObject, ARSessionDelegate {

    // MARK: Settings

    struct Settings: Equatable {
        /// Point cloud voxel size in meters (dedup grid). 2 cm is a good default for rooms.
        var voxelSize: Float = 0.02
        /// 0 = low, 1 = medium, 2 = high. LiDAR confidence threshold for point cloud.
        var minConfidence: Int = 2
        /// Max depth (m) accepted into the point cloud. LiDAR is reliable to ~5 m.
        var maxDepth: Float = 5.0
        /// Process every Nth frame for the point cloud (ARKit runs at 60 fps; depth at 60).
        var depthFrameStride: Int = 3
        /// Sample every Nth depth pixel (256x192 map → stride 2 ≈ 12k candidates/frame).
        var pixelStride: Int = 2
        var maxPoints: Int = 4_000_000

        var keyframeInterval: Double = 0.4
        var keyframeMinDistance: Float = 0.10
        var keyframeMinAngleDeg: Float = 8
        var saveDepth: Bool = true
        var jpegQuality: Double = 0.85
    }

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    // MARK: Published UI state (main thread)

    @Published var settings = Settings()
    @Published private(set) var isRecording = false
    @Published private(set) var trackingText = "初始化中…"
    @Published private(set) var trackingOK = false
    @Published private(set) var meshAnchorCount = 0
    @Published private(set) var meshVertexCount = 0
    @Published private(set) var pointCount = 0
    @Published private(set) var keyframeCount = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var warning: String?
    @Published private(set) var exportProgress: Double?
    @Published private(set) var exportStage = ""
    @Published private(set) var sessionError: String?

    weak var arView: ARView?

    // MARK: Private capture state (session queue only)

    private let queue = DispatchQueue(label: "com.triphorium.sitescan.session", qos: .userInitiated)
    private var active = Settings()
    private var recording = false
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private let cloud = PointCloudBuilder()
    private let keyframes = KeyframeRecorder()
    private var frameIndex = 0
    private var startTimestamp: TimeInterval = -1
    private var lastTimestamp: TimeInterval = 0
    private var lastUIPush: TimeInterval = 0
    private var scanID = ""
    private var scanFolder: URL?

    // MARK: Session lifecycle

    func attach(to arView: ARView) {
        self.arView = arView
        arView.automaticallyConfigureSession = false
        arView.session.delegate = self
        arView.session.delegateQueue = queue
        arView.debugOptions = [.showSceneUnderstanding]           // live mesh wireframe
        arView.renderOptions = [.disablePersonOcclusion, .disableMotionBlur, .disableDepthOfField, .disableHDR]
        arView.session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])
    }

    func pause() {
        arView?.session.pause()
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .none
        config.worldAlignment = .gravity
        config.isAutoFocusEnabled = true
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        return config
    }

    // MARK: Recording

    /// Resets the world origin to the current device pose and starts accumulating data.
    func startRecording() {
        let snapshot = settings
        let id = ScanStore.makeID()
        let folder: URL
        do {
            folder = try ScanStore.createScanFolder(id: id)
        } catch {
            sessionError = "无法创建扫描目录：\(error.localizedDescription)"
            return
        }

        isRecording = true
        warning = nil
        elapsed = 0
        arView?.session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])

        queue.async {
            self.active = snapshot
            self.scanID = id
            self.scanFolder = folder
            self.meshAnchors.removeAll()
            self.cloud.reset(voxelSize: snapshot.voxelSize, maxPoints: snapshot.maxPoints)
            self.keyframes.reset(folder: folder, jpegQuality: snapshot.jpegQuality, saveDepth: snapshot.saveDepth)
            self.frameIndex = 0
            self.startTimestamp = -1
            self.recording = true
        }
    }

    /// Stops recording and deletes everything captured so far.
    func discard() {
        isRecording = false
        queue.async {
            self.recording = false
            if let folder = self.scanFolder {
                try? FileManager.default.removeItem(at: folder)
            }
            self.scanFolder = nil
            self.meshAnchors.removeAll()
            self.cloud.reset(voxelSize: self.active.voxelSize, maxPoints: self.active.maxPoints)
        }
    }

    /// Stops recording and writes the bundle. Completion is delivered on the main thread.
    func finish(name: String, completion: @escaping (Result<ScanMeta, Error>) -> Void) {
        isRecording = false
        exportProgress = 0
        exportStage = "准备导出…"
        // Stop the camera first so ARKit does not keep queuing frames behind the export.
        arView?.session.pause()

        queue.async {
            self.recording = false
            guard let folder = self.scanFolder else {
                DispatchQueue.main.async {
                    self.exportProgress = nil
                    completion(.failure(ScanError.noActiveScan))
                }
                return
            }

            let anchors = Array(self.meshAnchors.values)
            let points = self.cloud.allPoints()
            let frames = self.keyframes.frames
            let duration = self.startTimestamp >= 0 ? max(0, self.lastTimestamp - self.startTimestamp) : 0

            let input = ScanBundleWriter.Input(
                folder: folder,
                id: self.scanID,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? self.scanID : name,
                durationSeconds: duration,
                anchors: anchors,
                points: points,
                frames: frames,
                depthSize: self.keyframes.depthSize,
                imageSize: self.keyframes.imageSize,
                voxelSize: self.active.voxelSize,
                minConfidence: self.active.minConfidence,
                maxDepth: self.active.maxDepth
            )

            do {
                let meta = try ScanBundleWriter.write(input) { p, stage in
                    DispatchQueue.main.async {
                        self.exportProgress = p
                        self.exportStage = stage
                    }
                }
                self.scanFolder = nil
                DispatchQueue.main.async {
                    self.exportProgress = nil
                    completion(.success(meta))
                }
            } catch {
                DispatchQueue.main.async {
                    self.exportProgress = nil
                    completion(.failure(error))
                }
            }
        }
    }

    enum ScanError: LocalizedError {
        case noActiveScan
        var errorDescription: String? {
            switch self {
            case .noActiveScan: return "没有正在进行的扫描"
            }
        }
    }

    // MARK: ARSessionDelegate (called on `queue`)

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors { meshAnchors[mesh.identifier] = mesh }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors { meshAnchors[mesh.identifier] = mesh }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors { meshAnchors.removeValue(forKey: mesh.identifier) }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameIndex += 1
        lastTimestamp = frame.timestamp

        var text: String
        var ok = false
        var warn: String? = nil
        switch frame.camera.trackingState {
        case .normal:
            text = "跟踪正常"
            ok = true
        case .notAvailable:
            text = "跟踪不可用"
        case .limited(let reason):
            switch reason {
            case .initializing: text = "初始化中…"
            case .excessiveMotion: text = "移动过快"; warn = "放慢速度，LiDAR 需要稳定的镜头"
            case .insufficientFeatures: text = "特征不足"; warn = "对准有纹理的表面，避开白墙、玻璃和强反光"
            case .relocalizing: text = "重定位中…"; warn = "回到刚才扫过的区域让系统重新定位"
            @unknown default: text = "跟踪受限"
            }
        }

        if recording {
            if startTimestamp < 0 { startTimestamp = frame.timestamp }
            if frameIndex % max(1, active.depthFrameStride) == 0,
               let depth = frame.smoothedSceneDepth ?? frame.sceneDepth {
                cloud.integrate(depth: depth,
                                camera: frame.camera,
                                image: frame.capturedImage,
                                minConfidence: active.minConfidence,
                                maxDepth: active.maxDepth,
                                pixelStride: active.pixelStride)
                if cloud.isFull { warn = "点云已达上限（\(NumberFormat.count(active.maxPoints))），已停止累积新点" }
            }
            keyframes.consider(frame: frame,
                               minInterval: active.keyframeInterval,
                               minDistance: active.keyframeMinDistance,
                               minAngleDegrees: active.keyframeMinAngleDeg)
        }

        // Throttle UI updates to ~4 Hz.
        if frame.timestamp - lastUIPush > 0.25 {
            lastUIPush = frame.timestamp
            let anchorCount = meshAnchors.count
            let vertexCount = meshAnchors.values.reduce(0) { $0 + $1.geometry.vertices.count }
            let pts = cloud.count
            let kf = keyframes.frames.count
            let el = (recording && startTimestamp >= 0) ? frame.timestamp - startTimestamp : 0
            DispatchQueue.main.async {
                self.trackingText = text
                self.trackingOK = ok
                self.warning = warn
                self.meshAnchorCount = anchorCount
                self.meshVertexCount = vertexCount
                self.pointCount = pts
                self.keyframeCount = kf
                if self.isRecording { self.elapsed = el }
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.sessionError = error.localizedDescription }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { self.warning = "AR 会话被中断（来电/切换应用）" }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { self.warning = nil }
    }
}
