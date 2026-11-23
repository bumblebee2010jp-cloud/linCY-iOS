# linCY iOS — 出未签名 ipa 的完整流程

这个仓库只做一件事：**在 GitHub 的 macOS runner 上编译出未签名 ipa，签名留给你在手机上完成。**
CI 里不存任何证书，不碰你的 p12 和描述文件。

---

## 工程现状（已核对）

| 项 | 值 |
|---|---|
| 工程 | `linCY.xcodeproj` |
| Target / Scheme | `linCY` |
| Bundle ID | `com.lincy.ios` |
| 版本 | `0.1.0` (build `1`) |
| 语言 | Swift 5.0，SwiftUI + UIKit + WebKit + Photos + Security |
| 最低 iOS | 16.0 |
| 设备族 | iPhone + iPad |
| 依赖 | 无（无 CocoaPods、无 SPM，纯系统框架） |
| 架构 | arm64（真机） |
| Entitlements | 无专用 entitlements 文件，用的是 Info.plist 里的权限说明 |
| App 图标 | 单尺寸 1024×1024，无 alpha，合规 |

因为没有任何第三方依赖，CI 里不需要 `pod install`，构建链路最短。

---

## 功能一览

### 备份（手机 → 服务器）

- 手动触发，勾选相册后点「开始备份」
- 自动对比服务器同名文件夹，缺则新建
- 按原始文件名跳过已有文件，不覆盖、不删除
- 先并发查重，再串行上传缺失文件

### 同步（服务器 → 手机）

- 「从服务器同步到相册」，二次确认后开始
- 遍历服务器上所有相册文件夹
- 手机上没有同名相册就新建（`PHAssetCollectionChangeRequest`）
- 只下载手机相册里没有的文件，按原始文件名比对
- 与手机上「已隐藏」同名的相册会跳过

依赖服务端三个已有接口，Windows / Ubuntu / fnOS 三个版本一致：

| 接口 | 用途 |
|---|---|
| `GET /api/albums` | 列出服务器相册文件夹 |
| `GET /api/album/photos?album=&offset=` | 分页列出相册文件（每页 12 条，`kind` 为 `image`/`video`） |
| `GET /api/album/photo?album=&name=` | 下载单个原始文件 |

### 隐藏相册

- 长按相册 → 「隐藏此相册」
- 隐藏后移出主列表、取消勾选，收进底部「已隐藏相册」分组
- 展开分组可查看并恢复
- 隐藏状态持久化，重启 App 保留
- 同步时与隐藏相册同名的服务器相册一并跳过

### 对比性能

原来每个文件一次串行 `exists` 查询，往返次数等于文件数。现在改为固定窗口（6 路）并发查询，往返次数降到 1/6：

| 文件数 | 改前（串行，按 80ms/次估算） | 改后（6 路并发） |
|---|---|---|
| 500 | 约 40 秒 | 约 7 秒 |
| 2000 | 约 2.7 分钟 | 约 27 秒 |
| 10000 | 约 13 分钟 | 约 2.2 分钟 |

上传仍然串行（后台 URLSession 单任务模型），这部分取决于带宽。同步侧的服务器分页列表也用 5 路并发拉取。

---

## 零、推送前先做本地预检

Windows 上没有 `xcodebuild`，但工程结构可以在本地静态验一遍，避免推上去跑一次才发现工程坏了：

```powershell
python .\scripts\verify_project.py .\linCY.xcodeproj
```

已经跑过一遍，当前结果：

```
[ OK ] 对象引用完整（28 个对象，无悬空引用）
[ OK ] 磁盘文件齐全（8 个 file reference）
[ OK ] 所有 .swift 都参与编译（5 个）
[ OK ] Info.plist 未被误加入 Resources
[ OK ] Assets.xcassets 已加入 Resources
── 关键 build settings ──
  PRODUCT_BUNDLE_IDENTIFIER              = com.lincy.ios
  INFOPLIST_FILE                         = linCY/Info.plist
  IPHONEOS_DEPLOYMENT_TARGET             = 16.0
  SWIFT_VERSION                          = 5.0
  TARGETED_DEVICE_FAMILY                 = 1,2
  ASSETCATALOG_COMPILER_APPICON_NAME     = AppIcon
  SDKROOT                                = iphoneos
结论: 工程结构完整，CI 上编译的前置条件都满足。
```

它检查的正是会让 CI 第一次就翻车的东西：悬空 ID 引用、漏提交的源文件、`.swift` 没进 Sources phase、`Info.plist` 被误打包、资源未加入 Resources、关键 build settings 缺失。

需要 Python 3.8+。没装就跳过这一步，直接走推送。

---

## 一、推到 GitHub

```powershell
cd "D:\DeepSeek Work\linCY-X-iOS"
.\scripts\push-repo.ps1 -RepoUrl https://github.com/YOURNAME/linCY-iOS.git
```

脚本会自动 `git init`、提交、推送。第一次会要你输 GitHub 账号密码/Token。

> **仓库建议选 public**：macOS runner 在公开仓库免费且不限次数；私有仓库每月的免费 macOS 额度只有约 200 分钟（按 10 倍系数折算），一次构建约 3–6 分钟。不想公开代码就把仓库设为 private，用 `workflow_dispatch` 手动触发，别每次 push 都跑。

---

## 二、触发构建

**方式 1：网页点击**

仓库页 → `Actions` → 左侧 `unsigned-ipa` → 右侧 `Run workflow` → 选 `Release` → 绿色按钮。

**方式 2：打 tag（同时生成可直链下载的 Release）**

```powershell
.\scripts\push-repo.ps1 -RepoUrl https://github.com/YOURNAME/linCY-iOS.git -Tag v0.1.0
```

**方式 3：命令行（装了 GitHub CLI）**

```powershell
gh workflow run unsigned-ipa.yml -f configuration=Release
gh run watch
```

构建大约 3–6 分钟。第一次跑大概率会暴露环境问题，日志里有分步输出（Xcode 版本、SDK 版本、scheme 列表、产物路径、ipa 结构、lipo 架构、sha256），失败时把日志贴出来就能定位。

---

## 三、取 ipa

两种入口：

- **Actions 页面**：点进这次运行 → 页面底部 `Artifacts` → 下载 `linCY-0.1.0-1-unsigned.zip` → 解压得到 `.ipa`。
- **Releases 页面**（打了 tag 才有）：直接点 `linCY-0.1.0-1-Release-unsigned.ipa` 下载。**这个链接在手机 Safari 里能直接下载**，比在手机上下载 artifact 方便得多。

拿到后先在 Windows 上自检一遍：

```powershell
python .\scripts\check_ipa.py .\linCY-0.1.0-1-Release-unsigned.ipa
```

输出会告诉你：Bundle ID、版本、最低 iOS、主二进制架构、是否真的未签名、有没有内嵌 Framework、需要哪些权限说明。结构有问题它会直接 FAIL，不用等装到手机上才发现。

---

## 四、手机上签名安装

### 工具

任选其一：**轻松签（ESign）**、**全能签**、**Gbox**、**TrollStore**（若系统版本在支持范围内，免证书）。

### 步骤（以轻松签/全能签这类为例）

1. **导入证书**
   - 把 `cert.p12` 和 `profile.mobileprovision` 传到手机（微信文件传输 / 局域网 / iCloud Drive 都行）
   - 工具里 → 证书管理 → 导入 p12（输入密码）→ 导入描述文件 → 确认两者配对成功

2. **导入 ipa**
   - 从「文件」App 或聊天记录里选 ipa → 用签名工具打开
   - 或者工具内「导入 ipa」选文件

3. **签名选项必须这样勾**
   | 选项 | 设成 | 原因 |
   |---|---|---|
   | 移除原有签名 | ✅ 勾 | 这个包本来就没签，勾上更保险 |
   | 重签所有 Framework | ✅ 勾 | 本工程无内嵌 Framework，但勾上无副作用 |
   | Bundle ID | 保持 `com.lincy.ios` | 改了必须和描述文件的 App ID 一致 |
   | entitlements | 用描述文件自带的 | 不要手动清空 |
   | 安装后信任 | 装完去设置里信任 | 见下 |

4. **安装**
   签完点安装 → 回到桌面 → `设置 → 通用 → VPN与设备管理 → 开发者 App → 点你的证书 → 信任` → 打开 App。

### 关于权限

这个 App 会请求：相册读写、相机、麦克风、本地网络。这些都是 Info.plist 里声明的普通权限，**不需要特殊 entitlement**，普通开发者证书签出来就能用。

唯一需要注意的是 **后台 URLSession**（`com.lincy.ios.album-upload`）：

- 它不要求额外 entitlement，但要求 **App 的 Bundle ID 与提交上传任务时一致**。
- 如果你在签名时改了 Bundle ID，后台会话标识不会跟着变，但功能不受影响（会话 ID 是硬编码字符串）。
- 免费证书 7 天过期后，后台任务会失效，重签重装即可。

### 设备 UDID

你的描述文件是 development / ad-hoc 类型的话，**目标设备的 UDID 必须在名单里**，否则装的时候报 `Unable to Install` 或 `integrity could not be verified`。

- 查 UDID：爱思助手连上手机，首页「设备标识」直接复制。
- 加设备：`developer.apple.com` → Devices → 注册 → 回到 Profiles 编辑对应 App ID 的 profile，勾上新设备 → 重新下载 `.mobileprovision`。
- 用的是"共享证书/企业证书"就跳过这步，那种 profile 通常已带大量 UDID 或用企业分发。

---

## 五、想省事：Windows 本地直接签

不想在手机上点来点去，就在 Windows 上用 `zsign`：

1. 下载 `zsign.exe`：<https://github.com/zhlynn/zsign/releases>，放到 `scripts\` 目录或加入 PATH。
2. 运行：

```powershell
cd "D:\DeepSeek Work\linCY-X-iOS"
.\scripts\sign-ipa.ps1 `
  -Ipa .\linCY-0.1.0-1-Release-unsigned.ipa `
  -P12 .\cert.p12 `
  -P12Password '你的p12密码' `
  -Profile .\profile.mobileprovision
```

脚本会依次：调 zsign 签名 → `zsign -t` 校验 → 调 `check_ipa.py` 做结构复核 → 打印安装方式。

产物在 `signed\` 目录。装法：爱思助手把 ipa 拖进主界面即可。

---

## 六、故障对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| `xcodebuild: error: The project does not contain a scheme named "linCY"` | scheme 没被 git 收录 | 确认 `linCY.xcodeproj/xcshareddata/xcschemes/linCY.xcscheme` 已提交（本项目已含） |
| `Signing for "linCY" requires a development team` | 签名开关没生效 | 确认 workflow 里 `CODE_SIGNING_ALLOWED=NO` 和 `DEVELOPMENT_TEAM=""` 都在 |
| `No such module 'UIKit'` | 缺 `import UIKit` | 已在 `WebScreen.swift` 补上 |
| artifact 里没有 ipa | `find` 没匹配到 `.app` | 看「构建」步骤日志里 `产物:` 那行是否为空；为空说明编译失败，往上翻报错 |
| 手机上装到一半失败 `integrity could not be verified` | 证书与 profile 不匹配，或 UDID 不在名单 | 重新导出成对的 p12 + profile；核对 UDID |
| 装好了但一打开就闪退 | Framework 没重签全，或 entitlements 不匹配 | 签名时勾「重签所有 Framework」；entitlements 用 profile 自带的 |
| 7 天后打不开 | 免费 Apple ID 证书过期 | 重签重装；换付费账号可到 1 年 |
| `Provisioning profile doesn't include signing certificate` | p12 里的证书不在 profile 列表 | 开发者后台重新生成 profile，勾选这张证书 |

---

## 七、我改了什么

| 文件 | 改动 | 原因 |
|---|---|---|
| `.github/workflows/unsigned-ipa.yml` | 新增 | 未签名构建流水线 |
| `scripts/verify_project.py` | 新增 | 本地静态校验 .xcodeproj 完整性（Windows 可跑） |
| `scripts/check_ipa.py` | 新增 | 本地校验 ipa 结构（Windows 可跑） |
| `scripts/sign-ipa.ps1` | 新增 | 本地 zsign 重签 + 自检 |
| `scripts/push-repo.ps1` | 新增 | 一键推仓库 / 打 tag |
| `.gitignore` | 新增 | 排除 build/DerivedData/证书类产物 |
| `linCY/WebScreen.swift` | 加了一行 `import UIKit` | 文件里用了 `UIViewController`、`UIActivityViewController`、`UIAlertController`，只靠 `import SwiftUI` 在部分 Xcode 版本下能过、部分不过，显式导入消除不确定性。逻辑零改动 |

业务代码一行没动。

---

## 八、一个诚实的前提
Windows 上没有 `xcodebuild`，所以**本地没法验证"真的能编过"**。第一次真实编译发生在 GitHub 的 macOS runner 上。

我在本地能做的验证都做了：

- `.xcodeproj` 结构完整性 → `verify_project.py` 全绿（28 个对象、8 个文件引用、5 个 Swift 源文件、资源阶段、build settings）
- workflow YAML 语法 → 解析通过，8 个 step
- 两个 PowerShell 脚本 → 语法解析通过（并已转成 UTF-8 BOM，PowerShell 5.1 下中文不乱码）
- `check_ipa.py` → 用构造的模拟 ipa 跑过正例与「含 Framework + 残留签名」负例，两条路径输出都正确

剩下唯一无法在本地消除的变量就是 Swift 编译器本身。所以 workflow 被写成自检型：每步都打印 Xcode 版本、iOS SDK 版本、scheme 列表、产物路径、ipa 结构、lipo 架构、sha256。第一次失败时，日志会直接指向原因。

跑完第一次，把失败的 step 名和最后 30 行贴给我，我按日志改。
