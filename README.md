# linCY iOS 源码

本版修正相册双向同步的重复文件问题，并把手机相册原有时间随上传保存到服务器，同步回来时使用该时间。
截图、下载图和收到的图片同样适用。需要配套更新后的 Windows／fnOS／Ubuntu 服务端。
没有新增恢复工具或恢复页面；已经丢失的旧相册时间不会自动恢复。

编译 IPA：将源码放入 GitHub 仓库，在 Actions 中运行 unsigned-ipa 工作流；或使用 macOS/Xcode 打开 linCY.xcodeproj 编译。
工作流产物为未签名 IPA，需按自己的证书签名后安装。
本机仅完成工程结构检查，尚未进行 Xcode 编译和真机验证。
