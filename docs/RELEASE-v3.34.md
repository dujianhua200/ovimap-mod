# 3.34.0 — 底图整幅出图 + 注记排版重做

本次版本针对「导出的 DXF 建筑不全、道路缺得多、村庄名没有、字体偏移」四类投诉，重做了底图取数口径与注记排版，不是打补丁式的微调。

## 一、底图取数：从「沿线走廊」改为「整幅图框」

以前底图是沿杆路走廊（默认 `rangeM = 50` 米）裁剪的，而 1:3000 的 A3 图框覆盖约 1260×891 米 —— 图框里八成是空白，用户看到的就是「建筑没几个、路断断续续、村里名字没出现」。

现在是按图框的真实地理范围（图框尺寸 × 比例 × 分幅数）算经纬度外包框，一次抓满整幅：

- 道路、建筑、水系、绿地、地名四条数据集统一按矩形裁剪，不再按走廊收窄；
- DXF 写出端跳过二次走廊裁剪，本地底图要素上限从 20000 提到 `max(旧上限, 60000)`；
- 导出前的「底图探测」也走同一口径，探测数与最终出图一致，不会出现「探测说有 300 栋、导出只剩 40 栋」。

导出对话框新增「底图范围」选择：**整幅图框（推荐）/ 沿线走廊**，默认整幅，选择记忆沿用（`dxfCoverageFrame`）。需要窄带出图的老流程选走廊即可。

## 二、道路：全等级保留

- `parseRoads` 改为**全等级保留**，只丢弃 `steps / bridleway / construction / proposed / raceway`（这些进图只会是噪声）；无名路也保留几何（画得出线，只是不标名）；
- 新增 `footway / pedestrian / living_street_link` → `service` 等级映射，村道、机耕道、居民点内部小路都能出；
- 路名取 `name:zh / name:zh-Hans / name:zh-CN` 优先，中文名不再因为只有 `name` 标签而丢。

## 三、建筑：过滤放宽

- 由「外接矩形跨度 < 4 米丢弃」改为**按环面积判断**（`< 6 m²` 才丢），农村小院、附属房不再被整体抹掉；
- 配合整幅口径，远端建筑不再被「离线路远近」截断。

## 四、村庄与地名

- `parsePlaces` 统一走中文名优先；
- `placeLevelOf` 新增 `isolated_dwelling / locality / allotments / farm` → `hamlet`，独户、地块、农场名字也能上图；
- 地名裁剪容差按图框口径处理，不再被 `rangeM + 100` 掐掉。

## 五、注记排版：消灭字体偏移

- 文字对齐由「`72=1` 水平居中 + 手算 -0.35h 基线补偿」改为 **`72=4`（Middle）原生垂直居中**，插入点即几何中心，CAD 里不再整体偏下；
- 路名字高改为**按等级固定**（trunk 2.0 / primary 1.9 / secondary 1.7 / tertiary 1.5 / residential 1.3 / service 1.0 / other 1.0 mm），不再被 clamp 压成 0.43mm 的「蚂蚁字」；
- 路名沿路面法线偏移 `半宽 + 0.7h`，骑在双线道路上方，不再压在描边里；
- 新增 `_LabelPlacer` 注记避让：地名、建筑名、路名互相压字时按优先级让位（地名按 city → village → hamlet 排序，地名优先）；
- 建筑名、地名、指北针、配线图文字统一走新对齐逻辑。

## 六、验证

- 新增 `test/v334_frame_coverage_test.dart`：合成 40 栋建筑 + 多等级道路 + 多级地名的底图，断言建筑全出、村道存在、`李庄村 / 王湾 / 小李庄` 都在、文字为 `72=4` 居中；
- 样本 DXF 用 ezdxf 读回核对：`DaoLu` 层 `京广路 / 村前街` 的 `halign=4`、`align_pt` 与 `insert` 一致、字高 2.00 / 1.30，并渲染 PNG 目视确认图幅铺满；
- 旧测试按新口径同步：`qa_dxf_basemap_verify_test`（全等级保留）、`qa_batch22_crop_indep_test`（走廊容差）、`dxf_roadname_tuning_test`（字高固定、骑路面）、`qa_dxf_tuning_verify_test`（去 clamp 断言）、`v314_frame_colors_test`（`72=4`）。

## 七、产物

`.github/workflows/build-desktop.yml` 打 `v*` 标签触发，产出：

- `ovimap-windows-x64-3.34.0.zip`（含 VC 运行库，解压双击 `ovimap.exe`）
- `ovimap-macos-universal-3.34.0.zip`（arm64 + x86_64，解压拖入「应用程序」）

macOS 首次打开若被 Gatekeeper 拦，右键「打开」，或执行 `xattr -cr /Applications/ovimap.app`。
