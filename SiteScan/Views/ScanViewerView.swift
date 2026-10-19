import SceneKit
import SwiftUI

/// Lightweight in-app viewer: orbit the LiDAR mesh (OBJ via Model I/O) or the colored point cloud.
/// Geometry is parsed on a background queue; `isLoading` drives a progress overlay in the parent.
struct ScanViewerView: UIViewRepresentable {
    enum Mode: String, CaseIterable, Identifiable {
        case mesh = "Mesh"
        case points = "点云"
        var id: String { rawValue }
    }

    let folder: URL
    let mode: Mode
    @Binding var isLoading: Bool

    final class Coordinator {
        var requestedMode: Mode?
        var cache: [Mode: SCNNode] = [:]
        var generation = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling2X
        view.backgroundColor = UIColor(white: 0.09, alpha: 1)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.requestedMode != mode else { return }
        coordinator.requestedMode = mode
        coordinator.generation += 1
        let generation = coordinator.generation

        if let cached = coordinator.cache[mode] {
            Self.show(cached, in: view)
            return
        }

        let folder = self.folder
        let mode = self.mode
        let loading = $isLoading
        DispatchQueue.main.async { loading.wrappedValue = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let node: SCNNode?
            switch mode {
            case .mesh: node = Self.loadMesh(folder.appendingPathComponent("mesh.obj"))
            case .points: node = Self.loadPoints(folder.appendingPathComponent("cloud.ply"))
            }
            DispatchQueue.main.async {
                // Ignore stale results if the user switched modes while loading.
                guard coordinator.generation == generation else { return }
                loading.wrappedValue = false
                guard let node else { return }
                coordinator.cache[mode] = node
                Self.show(node, in: view)
            }
        }
    }

    private static func show(_ node: SCNNode, in view: SCNView) {
        guard let scene = view.scene else { return }
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        scene.rootNode.addChildNode(node)
        frameCamera(view: view, around: node)
    }

    // MARK: Loading (background)

    private static func loadMesh(_ url: URL) -> SCNNode? {
        guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
        let root = SCNNode()
        for child in scene.rootNode.childNodes { root.addChildNode(child) }

        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.78, alpha: 1)
        material.lightingModel = .blinn
        material.isDoubleSided = true
        root.enumerateHierarchy { n, _ in
            n.geometry?.materials = [material]
        }
        return root
    }

    private static func loadPoints(_ url: URL) -> SCNNode? {
        let pts = PointCloudExporter.readPLY(at: url, maxPoints: 1_500_000)
        guard !pts.isEmpty else { return nil }

        var verts: [SCNVector3] = []
        verts.reserveCapacity(pts.count)
        var colors = [Float](repeating: 0, count: pts.count * 3)
        for (i, p) in pts.enumerated() {
            verts.append(SCNVector3(p.x, p.y, p.z))
            colors[i * 3] = Float(p.r) / 255
            colors[i * 3 + 1] = Float(p.g) / 255
            colors[i * 3 + 2] = Float(p.b) / 255
        }

        let vSource = SCNGeometrySource(vertices: verts)
        let cData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let cSource = SCNGeometrySource(data: cData,
                                        semantic: .color,
                                        vectorCount: pts.count,
                                        usesFloatComponents: true,
                                        componentsPerVector: 3,
                                        bytesPerComponent: MemoryLayout<Float>.size,
                                        dataOffset: 0,
                                        dataStride: MemoryLayout<Float>.size * 3)
        let indices = Array(0..<Int32(pts.count))
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 3
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 4

        let geometry = SCNGeometry(sources: [vSource, cSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func frameCamera(view: SCNView, around node: SCNNode) {
        let (center, radius) = node.boundingSphere
        let r = max(radius, 0.5)
        let camera = SCNCamera()
        camera.zNear = 0.02
        camera.zFar = Double(r) * 20
        camera.fieldOfView = 60
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(center.x + r * 1.2, center.y + r * 0.9, center.z + r * 1.6)
        camNode.look(at: center)
        view.scene?.rootNode.addChildNode(camNode)
        view.pointOfView = camNode
    }
}
