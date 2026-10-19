import SwiftUI

struct ScanListView: View {
    @State private var scans: [ScanMeta] = []
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            Group {
                if scans.isEmpty {
                    ContentUnavailableView {
                        Label("还没有扫描", systemImage: "cube.transparent")
                    } description: {
                        Text("点右上角 + 开始第一次 LiDAR 扫描。\n每次扫描会导出 mesh、点云和用于 Gaussian splat 的关键帧。")
                    } actions: {
                        Button("开始扫描") { showScanner = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(scans) { meta in
                            NavigationLink(value: meta) {
                                ScanRow(meta: meta)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("SiteScan")
            .navigationDestination(for: ScanMeta.self) { meta in
                ScanDetailView(meta: meta)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showScanner = true } label: { Image(systemName: "plus") }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScanView(onSaved: { _ in reload() })
            }
            .onAppear {
                ScanStore.purgeIncomplete()
                reload()
            }
        }
    }

    private func reload() {
        scans = ScanStore.listScans()
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { ScanStore.delete(id: scans[i].id) }
        reload()
    }
}

private struct ScanRow: View {
    let meta: ScanMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meta.name).font(.headline)
            Text(meta.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline).foregroundStyle(.secondary)
            Text("\(NumberFormat.count(meta.meshVertexCount)) 顶点 · \(NumberFormat.count(meta.pointCount)) 点 · \(meta.keyframeCount) 帧 · \(Int(meta.durationSeconds)) s")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Viewer + stats + export for one finished scan.
struct ScanDetailView: View {
    let meta: ScanMeta

    @State private var mode: ScanViewerView.Mode = .mesh
    @State private var viewerLoading = false
    @State private var zipURL: URL?
    @State private var zipping = false
    @State private var zipError: String?
    @State private var folderSize: Int64 = 0

    var body: some View {
        VStack(spacing: 0) {
            ScanViewerView(folder: meta.folder, mode: mode, isLoading: $viewerLoading)
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .overlay {
                    if viewerLoading {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("加载 \(mode.rawValue)…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .overlay(alignment: .top) {
                    Picker("", selection: $mode) {
                        ForEach(ScanViewerView.Mode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .padding(10)
                    .frame(maxWidth: 240)
                }

            List {
                Section("内容") {
                    row("网格", "\(meta.meshAnchorCount) 块 · \(NumberFormat.count(meta.meshVertexCount)) 顶点 · \(NumberFormat.count(meta.meshFaceCount)) 面")
                    row("点云", "\(NumberFormat.count(meta.pointCount)) 点 · 体素 \(String(format: "%.1f", meta.voxelSizeMeters * 100)) cm")
                    row("关键帧", "\(meta.keyframeCount) 张 · \(meta.imageWidth)×\(meta.imageHeight)")
                    row("深度图", meta.depthWidth > 0 ? "\(meta.depthWidth)×\(meta.depthHeight) float32" : "未保存")
                    row("时长", "\(Int(meta.durationSeconds)) s")
                    row("设备", meta.deviceModel)
                    row("大小", NumberFormat.bytes(folderSize))
                }
                Section("导出") {
                    if let zipURL {
                        ShareLink(item: zipURL) {
                            Label("分享 \(zipURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            makeZip()
                        } label: {
                            HStack {
                                Label("打包为 ZIP", systemImage: "doc.zipper")
                                if zipping { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(zipping)
                    }
                    Text("也可以在「文件」App → 我的 iPhone → SiteScan → Scans 里直接取整个文件夹，或连 Mac 用访达拷贝。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let zipError {
                    Section { Text(zipError).foregroundStyle(.red).font(.footnote) }
                }
                Section("坐标系") {
                    Text(meta.coordinateSystem).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(meta.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            folderSize = ScanStore.folderSize(id: meta.id)
            let existing = ScanStore.zipURL(for: meta.id)
            if FileManager.default.fileExists(atPath: existing.path) { zipURL = existing }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func makeZip() {
        zipping = true
        zipError = nil
        let id = meta.id
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try ScanStore.makeZip(id: id)
                DispatchQueue.main.async { zipURL = url; zipping = false }
            } catch {
                DispatchQueue.main.async { zipError = "打包失败：\(error.localizedDescription)"; zipping = false }
            }
        }
    }
}
