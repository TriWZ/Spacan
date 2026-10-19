import SwiftUI

/// Full-screen capture UI: live AR view with mesh wireframe, HUD, record/stop, settings.
struct ScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = ScanSessionController()

    @State private var showSettings = false
    @State private var showSaveDialog = false
    @State private var scanName = ""
    @State private var errorMessage: String?

    var onSaved: (ScanMeta) -> Void = { _ in }

    var body: some View {
        ZStack {
            if ScanSessionController.isSupported {
                ARViewContainer(controller: controller)
                    .ignoresSafeArea()
            } else {
                unsupported
            }

            VStack(spacing: 12) {
                hud
                Spacer()
                if let warn = controller.warning {
                    Text(warn)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.yellow.opacity(0.9), in: Capsule())
                        .foregroundStyle(.black)
                }
                controls
            }
            .padding()

            if let p = controller.exportProgress {
                exportOverlay(progress: p)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(settings: $controller.settings)
                .presentationDetents([.medium, .large])
        }
        .alert("保存扫描", isPresented: $showSaveDialog) {
            TextField("名称（如 3F East Wing）", text: $scanName)
            Button("保存") { save() }
            Button("丢弃", role: .destructive) {
                controller.discard()
                dismiss()
            }
            Button("继续扫描", role: .cancel) {}
        } message: {
            Text("\(NumberFormat.count(controller.pointCount)) 点 · \(controller.keyframeCount) 关键帧 · \(controller.meshAnchorCount) 网格块")
        }
        .alert("出错了", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: controller.sessionError) { _, new in
            if let new { errorMessage = new }
        }
        .onAppear { scanName = defaultName() }
    }

    // MARK: Subviews

    private var hud: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(controller.trackingOK ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(controller.trackingText)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if controller.isRecording {
                    Text(timeString(controller.elapsed))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 14) {
                stat("网格", "\(controller.meshAnchorCount) 块 / \(NumberFormat.count(controller.meshVertexCount)) 顶点")
                stat("点云", NumberFormat.count(controller.pointCount))
                stat("关键帧", "\(controller.keyframeCount)")
            }
            .font(.caption)
            if !controller.isRecording {
                Text("按下录制后世界原点会重置到当前位置。慢走，离表面 1–3 m，每个面从两个以上角度扫。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
    }

    private var controls: some View {
        HStack {
            Button {
                controller.discard()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(controller.exportProgress != nil)

            Spacer()

            Button {
                if controller.isRecording {
                    showSaveDialog = true
                } else {
                    controller.startRecording()
                }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                    if controller.isRecording {
                        RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 32, height: 32)
                    } else {
                        Circle().fill(.red).frame(width: 64, height: 64)
                    }
                }
            }
            .disabled(!ScanSessionController.isSupported || controller.exportProgress != nil)

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(controller.isRecording)
        }
    }

    private func exportOverlay(progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text(controller.exportStage)
                    .font(.subheadline)
                Text("大场景写入 mesh 可能需要十几秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var unsupported: some View {
        VStack(spacing: 12) {
            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.system(size: 44))
            Text("此设备不支持 LiDAR 场景重建")
                .font(.headline)
            Text("需要 iPhone 12 Pro / 13 Pro / 14 Pro / 15 Pro / 16 Pro 及以后的 Pro 机型，或带 LiDAR 的 iPad Pro。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("关闭") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: Actions

    private func save() {
        controller.finish(name: scanName) { result in
            switch result {
            case .success(let meta):
                onSaved(meta)
                dismiss()
            case .failure(let error):
                errorMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func defaultName() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "扫描 " + f.string(from: Date())
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Capture parameters. Changes apply to the next recording.
struct SettingsSheet: View {
    @Binding var settings: ScanSessionController.Settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("点云") {
                    LabeledSlider(title: "体素大小", value: $settings.voxelSize, range: 0.01...0.05, step: 0.005, format: { String(format: "%.1f cm", $0 * 100) })
                    LabeledSlider(title: "最大深度", value: $settings.maxDepth, range: 2...8, step: 0.5, format: { String(format: "%.1f m", $0) })
                    Picker("置信度阈值", selection: $settings.minConfidence) {
                        Text("高（最干净）").tag(2)
                        Text("中").tag(1)
                        Text("低（最密）").tag(0)
                    }
                    Stepper("每 \(settings.depthFrameStride) 帧处理一次", value: $settings.depthFrameStride, in: 1...10)
                    Stepper("像素步长 \(settings.pixelStride)", value: $settings.pixelStride, in: 1...4)
                }
                Section("关键帧（用于 Gaussian splat）") {
                    LabeledSlider(title: "最小间隔", value: $settings.keyframeInterval, range: 0.2...1.5, step: 0.1, format: { String(format: "%.1f s", $0) })
                    LabeledSlider(title: "最小位移", value: $settings.keyframeMinDistance, range: 0.05...0.5, step: 0.05, format: { String(format: "%.0f cm", $0 * 100) })
                    LabeledSlider(title: "最小转角", value: $settings.keyframeMinAngleDeg, range: 3...30, step: 1, format: { String(format: "%.0f°", $0) })
                    LabeledSlider(title: "JPEG 质量", value: $settings.jpegQuality, range: 0.5...1.0, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
                    Toggle("保存原始深度 / 置信度", isOn: $settings.saveDepth)
                }
                Section {
                    Button("恢复默认") { settings = .init() }
                } footer: {
                    Text("体素 2 cm + 高置信度适合房间级 as-built；大空间可放宽到 3–5 cm。关键帧 0.4 s / 10 cm 走一圈 2 分钟大约 200–300 张。")
                }
            }
            .navigationTitle("扫描设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct LabeledSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let title: String
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride
    let format: (V) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
