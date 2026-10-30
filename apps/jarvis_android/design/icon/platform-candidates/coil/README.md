# Jarvis 平台图标候选

用户已选定 B 双线线圈，并将其集成至 Android 0.2.4+16；两台手机覆盖升级及系统版本核对已完成，锁屏下的实际桌面显示与动态性能验收尚待解锁。三角款仍为备选。三角款移除外圈和三角之间的三条连接线，保留原内外三角；双线线圈保持选定图形。

Android：android/res 为自适应图标资源，包含独立背景、108dp 前景和 monochrome 图层；主体位于中心 66dp 安全区。五档 PNG 为旧版启动器兼容资源，play-store-512.png 为完整正方形商店素材。AndroidManifest.xml 是资源验证示例，集成已有应用时请仅合并资源及 icon/roundIcon 引用，勿覆盖应用 manifest。已使用 Android SDK 36 aapt2 编译和链接验证；未执行真机安装验证。

macOS 27：macos/*.icon 为分层 Icon Composer 工程候选，1024×1024 SVG 图层不含烘焙圆角、阴影或高光。请在 Mac 上用 Icon Composer 2 打开，核查图层、默认/深色/单色外观及 27 渲染，再导入 Xcode 27 的目标工程编译验证。当前 Linux 主机无法运行这些 Apple 工具，故原生校验尚未完成，不作已符合全部 macOS 27 要求的声明。兼容目录提供实际 ICNS、十尺寸 iconset 和 AppIcon.appiconset，可用于传统图标接入；不能替代现代分层工程的校验。

preview 下 PNG 为平台外形/材质模拟，非 Apple 原生截图，不应当作 Icon Composer 的源图层。Android 的最终遮罩、主题色和动态效果由启动器决定。

官方依据：
- https://developer.apple.com/design/human-interface-guidelines/app-icons
- https://developer.apple.com/icon-composer/
- https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
- https://developer.android.google.cn/develop/ui/compose/system/icon_design_adaptive
