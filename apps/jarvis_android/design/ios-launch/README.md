# iOS 开屏接入素材（尚未原生编译）

当前仓库只有 Android 原生 host。此目录是未来 iOS host 的素材与配置片段，不代表已生成可安装 iOS APP。

在 Mac 上将 LaunchScreen.storyboard 加入 Runner target，将 Assets.xcassets 中的 JarvisLaunchMark.imageset 合入 Runner Assets，并合并 Info-launch.fragment.plist 的 UILaunchStoryboardName。系统开屏使用静态 B1 标识及深色背景；动态部分由共用 Flutter StartupGate 接续。请用 Xcode 27 的 ibtool/实际构建核查 Storyboard 和素材，测试冷启动、横竖屏及减少动态效果。

未执行 iOS 编译、签名、实机验证；原有原生 Vault/Blobs/音频平台通道也需要 iOS 实现，不能只加入开屏就宣称完整 iOS 端已可用。

依据：https://developer.apple.com/design/human-interface-guidelines/launching
https://developer.apple.com/documentation/xcode/specifying-your-apps-launch-screen
