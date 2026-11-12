# 滑洲云图 ovimap v3.0.2 桌面版

**首个桌面端稳定版。** 同一套 Flutter 代码开始产出 Windows / macOS 桌面应用 ——
现场用手机采集，回办公室用电脑成图出图，两边数据通过自建云同步打通。

---

## 📦 下载

| 平台 | 文件 | 体积 | 用法 |
|---|---|---|---|
| **Windows x64** | `ovimap-windows-x64-3.0.2.zip` | ≈14 MB | 解压到任意目录 → 双击 `ovimap.exe`（免安装绿色版） |
| **macOS** | `ovimap-macos-universal-3.0.2.zip` | ≈21 MB | 解压得到 `ovimap.app` → 拖入「应用程序」 |

**Windows 注意**
- 必须**整个目录一起解压**，不要只把 `ovimap.exe` 拖出来（它依赖同级的 `data\` 目录与若干 dll）。
- 包内已自带 `MSVCP140.dll` / `VCRUNTIME140.dll` / `VCRUNTIME140_1.dll`，目标机器无需再装 VC++ 运行库。
- 想双击 `.ovimap` 工程文件直接打开：管理员 PowerShell 跑一次 `scripts\install_association.ps1`。

**macOS 注意**
- 首次打开会被 Gatekeeper 拦住（ad-hoc 签名，无 Apple 开发者证书）：
  **右键 → 打开 → 弹窗里再点「打开」**，或执行
  `xattr -dr com.apple.quarantine /Applications/ovimap.app`。
- 通用二进制（`x86_64` + `arm64`），Intel 与 Apple Silicon 都能跑，最低 macOS 12.0。

---

## ✨ 这个版本带来了什么

### 桌面端基建
- **双平台构建**：GitHub Actions 一套工作流出 Windows + macOS 两个包，两个平台**各自跑测试门禁**，测试不过不出包
- **桌面壳（当前仅 Windows 生效）**：原生菜单栏（文件 / 编辑 / 工程 / 底图 / 同步 / 帮助）、工具栏、7 个快捷键、地图右键上下文菜单、左右栏一键折叠
- **原生能力**：Windows 系统拖放打开文件、原生「另存为」对话框、`.ovimap` 文件关联、VC++ 运行库自动补齐
- **平台能力降级**：桌面无 GPS / 无罗盘 / 无相机，统一走 `PlatformCaps` 收口，不会出现"点了没反应"

### 业务功能（与移动端同源）
- **现场采集**：16 种工程符号（杆 / 井 / 各类箱体 / 机房 / 基站…），符号形态对齐 YD/T 5015 制图标准；自动编号、连续打点、轨迹记录、测距测面积
- **成图算量**：拓扑连线（按分光器 / 分纤盒 / ONU / 交接箱等拓扑角色自动分层）、**自动布杆**（等距落杆 + 自动编号）、档距与总长实时计算、杆路轨迹核查、批量编辑
- **导出 7 类**：DXF 路由图（默认 **R12 最广兼容**，可选 R2000）、KML、杆点坐标 CSV、芯线占用表 CSV（含校验）、配线拓扑图 PNG、材料统计表 CSV、**工程量清单 CSV（451 号文口径：技工 114 元/工日、辅助材料 0.3%）**
- **DXF 进阶**：里程桩号（`K0+000`）、图例栏自动生成、竣工图红色描边、拉直分幅、管廊双线（可设走廊宽度）、周边底图矢量（道路分级双线 + 居中路名 / 建筑轮廓 / 建筑填充 HATCH）、天地图地名兜底
- **底图**：14 个图源（联通自建 / 高德 / 星图地球 / OSM / 天地图 / 自定义 XYZ），三级瓦片缓存，离线预下载，GeoJSON 本地矢量底图导入
- **坐标系**：WGS-84 ↔ GCJ-02 ↔ BD-09 双向转换；数据统一以 WGS-84 存储，切换图源自动偏移对齐
- **竣工资料**：设计↔竣工变更对照、竣工照片册 ZIP、**竣工资料一键成册**
- **云同步**：自建 Cloudflare Worker（D1 存索引 + R2 存快照），基于 `rev` 的乐观并发，冲突生成副本不静默覆盖，支持版本历史回滚

---

## ✅ 质量验证

**本 Release 的两个压缩包由 GitHub Actions 在门禁通过后构建**
（run `35353588357`，Windows 与 macOS 两个任务全绿，含最后一步自动挂载 Release）。
也就是说：**页面上这份包 = CI 跑完 analyze + test 后产出的那一份**，不是本机手工塞进来的。

| 检查项 | 结果 |
|---|---|
| CI 流水线 | 双平台**全绿**：静态分析 → 单元测试 → 构建 → 打包 → 上传产物 → 挂载 Release |
| 单元测试 | `flutter test` **502 通过 / 1 跳过 / 0 失败** |
| 静态分析 | `flutter analyze` 无 error / warning（仅放行 info 级 lint） |
| macOS 架构 | `lipo -info` → `x86_64 arm64`（真 universal） |
| macOS 签名 | `codesign --verify --strict` → `valid on disk` + `satisfies its Designated Requirement` |
| macOS 沙箱权限 | 实际含 `app-sandbox` / `network.client` / `files.user-selected.read-write`（另有 Xcode 注入的 `get-task-allow`，见下方已知限制） |
| macOS 可运行 | **已实测**：解包 CI 产物 → `open ovimap.app` → 进程稳定存活 12 秒以上，无新增崩溃报告 |
| Windows 依赖闭包 | `ovimap.exe` 导入表逐项核对完整；`flutter_windows.dll` + 4 个插件 dll + `data/` + VC++ 运行库齐全 |
| Windows 体积 | 解压后 33.7 MB，zip 14 MB |

**下载后校验（可选）**

| 文件 | 大小 | sha256 |
|---|---|---|
| `ovimap-macos-universal-3.0.2.zip` | 21 685 883 B | `d9405c049dd5aa5d7c76c8199c9e9ec542e998e0684eabf9be26ae641b4f2448` |
| `ovimap-windows-x64-3.0.2.zip` | 14 280 867 B | `9381f491d5f0107d6eeb816dc18ad187423e5f7b4bfaa68c08688f23ffc6365b` |

```bash
shasum -a 256 ovimap-*.zip      # macOS
certutil -hashfile ovimap-windows-x64-3.0.2.zip SHA256   # Windows
```

---

## ⚠️ 已知限制

- **macOS 包目前是「移动竖屏壳」，不是与 Windows 一致的桌面体验。**
  顶层界面壳的分支条件是 `Platform.isWindows`（`lib/main.dart:87`），macOS 落到了移动壳
  `HomePage` —— **全部业务功能可用**（打点、连线、自动布杆、导出 DXF/CSV/KML/PNG、云同步…），
  但**没有**菜单栏、工具栏、快捷键、右键菜单与三栏布局。
  修复是一行改动：`Platform.isWindows` → `PlatformCaps.isDesktop`（该常量已含 macOS），
  计划在下一版本统一。购买/部署前请按此预期评估。
- macOS 包为 **ad-hoc 签名**，未做 Apple 公证（notarization），首次打开需手动放行。
- macOS 包的签名里带了一条 `com.apple.security.get-task-allow`（Xcode 在 ad-hoc 签名下
  注入的基础授权，工程 `Release.entitlements` 源文件里没有）。它允许调试器附加进程，
  属开发期授权、正式包通常不该有。对内部工程工具属**低风险**，不影响功能与分发；
  若要按安全基线收口，在 Release 配置里加 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`
  重新构建即可（收口方法已写进 `docs/BUILD-macos.md` §7.3）。
- 桌面端的**位置能力受限**：设计定位是室内成图与出图；现场采集建议用 Android 版，桌面端可手动落点。
- macOS 无系统级文件拖放（`WM_DROPFILES` 是 Windows 专属），应用内拖拽仍可用。
- macOS 无原生「另存为」对话框（`supportsFileSaveDialog=false`），导出落盘到数据目录 / 走分享。
- Windows 包的**真机启动**未在 Windows 机器上验证（构建环境无 Windows），
  仅核对了导入表依赖闭包与文件完整性。

---

## 📖 文档

| 文档 | 内容 |
|---|---|
| [README](https://github.com/dujianhua200/ovimap#readme) | 项目总览、功能全清单、下载安装、界面导航、FAQ |
| [使用手册](https://github.com/dujianhua200/ovimap/blob/main/docs/USAGE.md) | 分场景操作流程（架空 / 管道 / 箱体配线 / 竣工）+ 功能详解 + 数据备份 |
| [Windows 构建](https://github.com/dujianhua200/ovimap/blob/main/docs/BUILD-windows.md) | VS 2022 + Flutter 本地构建、绿色版制作、文件关联 |
| [macOS 构建](https://github.com/dujianhua200/ovimap/blob/main/docs/BUILD-macos.md) | Xcode + Flutter 本地构建、签名与沙箱、ditto 打包 |
| [CI 构建与发布](https://github.com/dujianhua200/ovimap/blob/main/docs/BUILD-desktop-ci.md) | GitHub Actions 双平台流水线、版本发布流程 |
| [云同步部署](https://github.com/dujianhua200/ovimap/blob/main/docs/DEPLOY-sync.md) | Cloudflare Worker / D1 / R2 部署 |

---

## 🔧 版本号约定

版本号唯一真源是 `pubspec.yaml` 的 `version: <name>+<number>`（本版为 `3.0.2+8`），
CI 自动解析并传给 `flutter build --build-name --build-number`。
升级版本时只改这一处，标签名与产物文件名会自动跟上。

**完整变更历史**：https://github.com/dujianhua200/ovimap/commits/main
