# linCY iOS 源码

## 0.2.14 修正：原版功能 → 备份文件 → 选取文件，没有图库选项

- 根因：`WebScreen.swift` 自行实现网页文件选择代理，始终弹出 `UIDocumentPickerViewController`（文件 App），没有图库来源，还把多选固定关闭。
- 移除这段自定义代理及私有选择器/KVC 兼容代码，恢复 WebKit 默认文件上传面板。图库、拍摄、文件来源及多选按网页 `input` 的 `accept` / `multiple` 和系统版本决定；不会强行只打开文件 App。
- 保留 0.2.13 相册检查、备份和同步逻辑。下载、分享、网页登录及 JavaScript 弹窗实现保留。
- 移除原自定义代理时也取消了它的“选文件夹自动跳 Safari”处理，连接帮助文字相应修正。文件夹如在 App 内不可用，需手动用 Safari 打开相同地址。
- 未修改服务端网页。如果网页明确限制只能选非图片文件，系统菜单仍遵守该限制。

Apple/WebKit 明确说明：iOS 上不实现 open-panel 代理时会提供默认上传行为，匹配 Safari 的文件上传处理：
https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:runopenpanelwith:initiatedbyframe:completionhandler:)
https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKUIDelegate.h

本次已做工程结构、文件引用和改动范围检查；没有 macOS / Xcode，未编译或真机验证。重新编译安装后，请依次测试：备份文件 → 选取文件 → 图库，单张及多张照片、视频选择，取消后再次选择，以及从“文件”上传普通文件。

本版修正相册双向同步的重复文件问题，并把手机相册原有时间随上传保存到服务器，同步回来时使用该时间。
截图、下载图和收到的图片同样适用。需要配套更新后的 Windows／fnOS／Ubuntu 服务端。
没有新增恢复工具或恢复页面；已经丢失的旧相册时间不会自动恢复。

## 0.2.12 修正：误报「服务端未确认保存原相册时间」

- 服务端（original-time 版）把拍摄时间写进相册目录下的 `.lincy-photo-dates/<文件名>`，
  内容是 `{"version":1,"date_ms":…,"size":…,"modified":…}`，同时把文件 mtime 设为拍摄时间，
  但**上传响应里不一定回 `creation_date_ms` 字段**。原逻辑把「响应缺字段」当成失败，
  于是出现「文件已被接收，但服务端未确认保存原相册时间」——文件其实已经正确落盘。
- 现在：响应里的确认字段存在且与发送值不一致才判失败；字段缺失不判失败，只在日志提示一次。
- 确认字段兼容数字与字符串两种写法。
- 0.2.11 的只读「检查同名不同大小」保留：勾选相册 → 点按钮 → 逐张导出比对 → 列表 + 可复制清单。

## 0.2.13 修正：检查同名不同大小永远报 0

- 根因：相册目录不在「备份根」下。备份根是 `mobile.json` 的 `upload_dir`（如 `E:\iPhone15Pro\Backup`），
  相册实际在 `album_dir`（如 `E:\iPhone15Pro\Video\Photos`）。
  之前用 `/api/upload-contents?path=<相册名>` 查的是备份根，返回空清单，
  所有文件都没进入比对，结果永远是 0。
- 改用与反向同步同一条路径：`/api/album/photos?album=&offset=` 分页拿相册文件列表，
  并用 `GET /api/albums` 的目录名做匹配（先按安全目录名，再按相册标题，大小写不敏感）。
- 服务器端大小改为 `HEAD /api/album/photo?album=&name=` 读 `Content-Length`，
  不再为了比大小把整张照片重新下载一遍。
- 新增诊断日志：每个相册一行「服务器 N 个文件（目录 X）」，
  结束时一行「检查汇总：同名 A 个，读到服务器大小 B 个，不一致 C 个」。

编译 IPA：将源码放入 GitHub 仓库，在 Actions 中运行 unsigned-ipa 工作流；或使用 macOS/Xcode 打开 linCY.xcodeproj 编译。
工作流产物为未签名 IPA，需按自己的证书签名后安装。
本机仅完成工程结构检查，尚未进行 Xcode 编译和真机验证。
