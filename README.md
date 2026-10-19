# SiteScan — iPhone LiDAR 三维扫描（as-built 进度验证的第一步）

用 iPhone Pro / iPad Pro 的 LiDAR 走一圈，得到三样东西，全部**米制、同一坐标系**：

| 输出 | 文件 | 用途 |
|---|---|---|
| 场景网格 | `mesh.obj` | 量尺寸、对图纸、算体积，Blender / Revit / CloudCompare 直接打开 |
| 彩色点云 | `cloud.ply` | 进度比对的基础数据；也是 Gaussian splat 的初始点（跳过 COLMAP SfM） |
| 关键帧 + 位姿 | `images/`、`transforms.json`、`depth/` | 训练 Gaussian splat（nerfstudio / gsplat）做可视化展示 |

**这一版只做采集和导出。** 进度比对、图纸对齐、报告生成是后面的事，但所有数据已经按那个目标准备好了。

---

## 1. 环境要求

- 带 LiDAR 的设备：iPhone 12 Pro 及以后的所有 Pro / Pro Max，或 2020 年后的 iPad Pro
- iOS 17 或更高
- 编译：Mac + Xcode 15 或更高；**没有 Mac 看第 1.5 节**，用 GitHub 的云端 Mac 编译，Windows 电脑装机

## 1.5 没有 Mac 的做法（Windows + iPhone）

iOS 包只能在 macOS 上编译，但 GitHub Actions 免费提供 macOS 机器。仓库里的 `.github/workflows/build-ipa.yml` 会在云端编译出一个**未签名** `SiteScan-unsigned.ipa`，然后在 Windows 上用 Sideloadly 用你自己的 Apple ID 签名并装到手机。全程不需要 Mac，不需要付费开发者账号。

**第一步：把代码放到 GitHub（一次性，10 分钟）**

1. 注册/登录 [github.com](https://github.com) → 右上角 + → New repository → 名字 `sitescan`，选 **Public**（Actions 的 macOS 机器对公开仓库免费不限时；私有仓库每月只有约 200 分钟，够 20 次编译）→ Create
2. 页面上点 *uploading an existing file* → 把解压后 `SiteScan/` 文件夹里的**所有内容**（包括 `.github` 文件夹，Windows 资源管理器里要勾选「查看 → 隐藏的项目」才看得见）拖进浏览器 → Commit changes
3. 仓库顶部 **Actions** 标签 → 左侧 *Build unsigned IPA* → 右侧 *Run workflow*。约 6–10 分钟后变绿
4. 点进这次运行 → 底部 *Artifacts* → 下载 `SiteScan-unsigned-ipa`（一个 zip，里面是 `.ipa`）

以后每次改代码只重复 2–4 步；或者在 Windows 装 [GitHub Desktop](https://desktop.github.com) 用 push 代替拖文件。

**第二步：Windows 上装到 iPhone（Sideloadly）**

1. 装 Apple 官网版 [iTunes](https://support.apple.com/zh-cn/HT210384)（不要用 Microsoft Store 版）和 [iCloud for Windows](https://support.apple.com/zh-cn/HT204283)（同样用 Apple 官网版）
2. 装 [Sideloadly](https://sideloadly.io)
3. iPhone 用数据线连电脑，解锁，点「信任此电脑」
4. 打开 Sideloadly：把 `.ipa` 拖进去 → 填你的 Apple ID → Start → 弹窗输入密码（和双重认证码）→ 等它签名安装
5. iPhone：*设置 → 隐私与安全性 → 开发者模式* 打开（重启一次）；*设置 → 通用 → VPN 与设备管理* → 信任你的 Apple ID
6. 桌面上出现 SiteScan

免费 Apple ID 签的包 **7 天失效**，到期重新拖一次 Sideloadly 即可（扫描数据在沙盒里不会丢）；Sideloadly 有 Wi-Fi 自动续签选项。免费账号最多同时装 3 个这样的 App。换成付费开发者账号后，同样的 IPA 签出来 1 年有效。

[AltStore](https://altstore.io) 是同类工具（Windows 版 AltServer），步骤一样，可以替代 Sideloadly。

**其他选项，按成本排**

| 方案 | 成本 | 适合 |
|---|---|---|
| GitHub Actions + Sideloadly（上面） | 免费 | 自己测、改代码频率不高 |
| 租云 Mac：MacinCloud、Scaleway Mac mini、AWS EC2 Mac | $25–100/月 | 需要真正的 Xcode 界面、要用 Xcode Cloud / TestFlight 上传 |
| 二手 Mac mini M1 / 新 M4（$599） | 一次性 | 后面要持续做 iOS，这是最省心的 |
| Windows 上跑 macOS 虚拟机 | 免费 | 违反 Apple 许可协议，Xcode 跑不稳，不推荐 |

TestFlight 内测分发需要付费开发者账号；有账号后，GitHub Actions 也能自动上传 TestFlight（要在仓库 Secrets 里放 App Store Connect API Key），到时候我再给你那版 workflow。

## 2. 生成 Xcode 工程（有 Mac 时）

### 方式 A — XcodeGen（推荐，一条命令）

```bash
brew install xcodegen
cd SiteScan
xcodegen generate
open SiteScan.xcodeproj
```

### 方式 B — 手动

1. Xcode → File → New → Project → iOS App，Product Name `SiteScan`，Interface SwiftUI，Language Swift
2. 删掉模板里的 `ContentView.swift` 和 `SiteScanApp.swift`
3. 把本仓库 `SiteScan/SiteScan/` 下的 `App`、`AR`、`Export`、`Models`、`Support`、`Views` 六个文件夹拖进工程（勾选 *Copy items if needed* 和 *Create groups*）
4. Target → Info 里加 `NSCameraUsageDescription`、`UIFileSharingEnabled = YES`、`LSSupportsOpeningDocumentsInPlace = YES`；Deployment Target 设为 iOS 17.0

### 签名并装到手机

**最快**：手机连上 Mac，然后

```bash
TEAM_ID=你的10位TeamID ./install_to_iphone.sh
```

脚本会生成工程、编译、注册设备、签名、装机、启动。Team ID 在 Xcode → Settings → Accounts 里（免费 Apple ID 也有一个 Personal Team）。不传 `TEAM_ID` 就只生成工程并打开 Xcode，手动选 Team 后 ⌘R。

第一次需要在手机 *设置 → 通用 → VPN 与设备管理* 里信任开发者证书。

| 账号 | 签名有效期 | 能装几台 | 能用 TestFlight |
|---|---|---|---|
| 免费 Apple ID（Personal Team） | 7 天，到期重跑脚本 | 3 台 | 否 |
| Apple Developer Program（$99/年） | 1 年 | 100 台 | 是 |

### TestFlight 内测（需要付费开发者账号）

1. [developer.apple.com](https://developer.apple.com/programs/enroll/) 加入 Developer Program（个人即可，审核约 1–2 天）
2. [App Store Connect](https://appstoreconnect.apple.com) → My Apps → + → New App，Bundle ID 选 `com.triphorium.sitescan`（先在 Certificates, Identifiers & Profiles 里注册这个 ID）
3. Xcode → Product → Archive → Distribute App → **TestFlight Internal Only** → Upload。几分钟后在 App Store Connect 的 TestFlight 页出现
4. TestFlight → Internal Testing → 建一个组，加自己和同事的 Apple ID（最多 100 人，不用审核）
5. 手机装 TestFlight App，接受邀请即可安装；每个 build 有效 90 天

之后每次改代码只重复第 3 步。想全自动的话 Xcode → Product → Xcode Cloud → Create Workflow，每次 push 自动打包上传 TestFlight，免费额度每月 25 小时。

> 如果 Mac 上装了 Claude Code，直接在 `SiteScan/` 目录里说"生成 Xcode 工程并 build 到我的 iPhone"也行。
> 这套代码是在没有 Xcode 的环境里写的，没有编译验证过；第一次 build 如果有少量报错，把报错贴回来即可。

## 3. 怎么扫

1. 打开 App → 右上角 **+**
2. 画面上会实时显示 LiDAR 网格线框。等顶部状态变成绿色 **跟踪正常**
3. 按红色按钮开始录制。**此刻设备的位置和朝向就是坐标原点**，建议从房间门口、面对房间中心按下
4. 走动规则：
   - 慢。每秒不超过半米，转身不要快
   - 离表面 1–3 m，LiDAR 超过 5 m 就不记点了
   - 每个面从至少两个方向扫到，角落和柱子绕一圈
   - 玻璃、镜面、纯白墙、强逆光会丢跟踪；状态变橙色时停下来回到刚才扫过的地方
   - 大空间分段扫，每段 2–4 分钟。一次扫太久点云会达到上限（默认 400 万点，设置里可调）
5. 按停止 → 起名字 → 保存。写 mesh 需要几秒到几十秒

**设置建议**

| 场景 | 体素 | 置信度 | 关键帧 |
|---|---|---|---|
| 单个房间 as-built（默认） | 2 cm | 高 | 0.4 s / 10 cm |
| 整层楼粗扫 | 3–5 cm | 中 | 0.6 s / 20 cm |
| 做高质量 splat 展示 | 2 cm | 高 | 0.3 s / 8 cm，JPEG 95% |

## 4. 拿出数据

三种方式任选：
- App 内 → 扫描详情 → **打包为 ZIP** → AirDrop / 存到 iCloud
- 手机 **文件** App → 我的 iPhone → SiteScan → `Scans/` 文件夹
- 连 Mac → 访达 → 设备 → 文件 → SiteScan，直接拖文件夹

目录结构：

```
Scan_20261019_083000/
├── meta.json          扫描信息、内参、坐标系说明
├── mesh.obj           LiDAR 网格，世界坐标，米
├── cloud.ply          彩色点云（binary little-endian：xyz float32 + rgb uint8）
├── transforms.json    nerfstudio / instant-ngp 格式相机文件，含 ply_file_path
├── images/            frame_00001.jpg …（传感器横向原始方向，内参直接适用）
└── depth/             frame_00001.bin（float32 深度，米）+ .conf（uint8 置信度）
```

**坐标系**：右手系，米，+Y 朝上（重力对齐），原点 = 按下录制时的设备位置。相机位姿是 camera-to-world，OpenGL 约定（相机看 −Z）。这和 nerfstudio / Blender 一致。

## 5. 训练 Gaussian splat

LiDAR 点云直接当初始点，不用跑 COLMAP 特征匹配，省掉通常最慢最容易失败的一步。

### 方式 A — nerfstudio（最省事）

```bash
pip install nerfstudio            # 需要 CUDA GPU，或用云端 GPU
ns-train splatfacto --data /path/to/Scan_20261019_083000
ns-viewer --load-config outputs/.../config.yml
ns-export gaussian-splat --load-config outputs/.../config.yml --output-dir splat/
```

`transforms.json` 里的 `ply_file_path: cloud.ply` 会被 splatfacto 自动用作种子点。

### 方式 B — gsplat / 原版 3DGS（需要 COLMAP 格式）

```bash
python tools/prepare_splat.py /path/to/Scan_20261019_083000 --out /path/to/Scan_colmap --max-points 600000
# 然后
python gsplat/examples/simple_trainer.py default --data_dir /path/to/Scan_colmap --data_factor 1
# 或
python gaussian-splatting/train.py -s /path/to/Scan_colmap
```

`tools/prepare_splat.py` 只依赖 numpy，会把 ARKit 位姿转成 COLMAP 的 world-to-camera 四元数，并把点云写成 `points3D.txt`。加 `--depth-png` 可把原始深度转成 16 位 PNG（毫米）。

## 6. 下一步（不在这版里）

- 对齐图纸：在 mesh 上点 2–3 个已知点（柱网交点、门边）求一个 2D 相似变换，之后所有扫描共享图纸坐标
- 多次扫描叠合：同一房间不同日期的 `cloud.ply` 用 ICP 对齐，差分出新增工作
- SOV 逐行比对：按 G703 行号给每个区域/工种定义"完成"的几何判据，再让视觉模型对关键帧做房间级问答

## 代码结构

```
SiteScan/
├── App/SiteScanApp.swift                 入口
├── AR/ScanSessionController.swift        AR 会话、录制状态机、导出调度
├── AR/PointCloudBuilder.swift            深度图 → 世界坐标彩色点云（体素去重）
├── AR/KeyframeRecorder.swift             关键帧 JPEG + 位姿 + 原始深度
├── Export/MeshExporter.swift             ARMeshAnchor → OBJ
├── Export/PointCloudExporter.swift       PLY 读写
├── Export/ScanBundleWriter.swift         transforms.json + meta.json
├── Models/ScanStore.swift                扫描目录管理、ZIP
├── Views/ScanView.swift                  采集界面 + 设置
├── Views/ScanListView.swift              列表、详情、导出
├── Views/ScanViewerView.swift            SceneKit 查看器
└── Views/ARViewContainer.swift
tools/prepare_splat.py                    bundle → COLMAP
```
