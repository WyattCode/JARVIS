# Spark 本机打包记录

2026-10-25，用户确认继续配置构建环境。实际全部配置在用户目录，未使用 sudo、没有安装全局系统包、没有改系统默认 Java，也没有改生产服务。

## 隔离环境

- `tools/android-env.sh`：仅为当前 shell 设置 JDK21、Android SDK、Gradle 专用缓存和私有签名路径。
- JDK/QEMU8：`/home/wyatt/.local/opt/jarvis-android-host`，从华为 Ubuntu 镜像下载有签名仓库的包并解压，不执行包安装脚本。
- x86 用户运行库：`/home/wyatt/.local/opt/jarvis-android-x64`，同样通过 Ubuntu 签名元数据校验、从国内镜像取得。
- SDK：`/home/wyatt/.local/opt/jarvis-android-sdk`，Platform36、BuildTools36.0.0、NDK28.2.13676358、Java版CommandLineTools17.0。档案保留原件及 SHA 校验记录；NDK 符号链接按档案恢复。
- SDK 档案从 Android 官方域名经阿里DNS得到的中国大陆节点直连（本次113.108.239.161），保留 TLS 校验，未走国外下载代理；每个包核对官方仓库元数据中的 SHA-1 并另记 SHA-256。
- 必需的 SDK 许可已按用户授权接受并记录；未为消除 doctor 提示而接受无关开发套件的许可。
- Gradle：`/home/wyatt/.local/state/jarvis-android-gradle`。独立 init 脚本将 Gradle 插件、Flutter included build 和普通 Maven 仓库限制到国内镜像；未改系统或其他项目的 Gradle 配置。

## ARM 主机构建兼容

Android 的若干 Linux 主机工具只提供 x86_64 二进制。本工程缓存中的原始工具保留为 `.x86_64`，入口脚本通过隔离 QEMU 运行，未改动原始二进制内容。AAPT2、NDK llvm-strip/llvm-objcopy 和 Android AOT 编译已验证可运行；ARM64 APK 的 Kotlin 编译已通过。

Flutter 工具寻找 `linux-arm64/gen_snapshot`，官方缓存仅带 `linux-x64`。本次为自己的 Flutter 缓存建立兼容入口，目标 Android 仍为原生 ARM64，并不是在手机上仿真 x86。

QEMU8.2 在读取 `/proc/self/maps` 时崩溃，与 [QEMU 上游问题2168](https://gitlab.com/qemu-project/qemu/-/issues/2168) 的路径及错误一致。AOT 快照编译改用从华为 Debian 镜像取得、经 Debian 签名元数据校验的 QEMU7.2 静态二进制，只用于本机快照编译；AAPT2 等工具保留原路径。未注册全局 binfmt、未启动虚拟机，也未改 DGX 网卡/内核。

## 固定个人签名

私有签名目录：`/home/wyatt/.local/share/jarvis-android-signing`（目录700，文件600）。私钥及密码不放进仓库、APK、交接文档或命令参数。`JARVIS_SIGNING_PROPERTIES` 只给 Gradle 私有配置文件的路径。后续升级必须沿用这一签名，避免覆盖安装失败或被迫卸载资料。

签名证书 SHA-256：`d526e100ea95679f0ef44992a4dc6eff3d89485c436eb4ae4485714f8ed69613`。签名校验日志在 `~/.local/state/jarvis-android-apk-signature.log`。

## 构建与安装

```bash
cd /home/wyatt/localrouter/apps/jarvis_android
source tools/android-env.sh
./tools/flutter-cn.sh build apk --release --target-platform android-arm64
./tools/install-phone.sh
```

小米需解锁，并可能要求用户在 HyperOS 确认通过调试安装。使用 `--no-incremental`，避免现有 Alpine ADB 包缺失 `inc-server` 的增量安装失败；普通流式安装无需这个工具。安装脚本只覆盖本应用，不卸载应用或清除资料。

构建日志在 `~/.local/state/jarvis-android-{build,release-build}.log`；下载、包元数据与校验记录在 `~/.local/state/jarvis-android-build-env/`。实机尚未完成验收时，不能用“APK 已编译”替代录音/播放、文件、加密持久化和折叠切换的验证。

## 2026-10-25 实机连接补充

手机无线端口已从32929变化为46157，使用`adb mdns services`按已知设备身份重新发现，没有连接发现列表中的其他手机。HyperOS正常安装确认已通过，固定签名覆盖升级成功。

Alpine ADB通过显式musl loader运行时，自动启动守护进程会误用loader为自身路径。已保留旧wrapper，复制ADB为`adb37-native`，仅修改这份私有副本的ELF解释器/RPATH到用户目录的musl及库，不改系统动态链接器。客户端及独立5039端口自动启动/退出检查通过；实际5038连接保持运行。安装辅助脚本现在显式选择`JARVIS_DEVICE`或唯一在线实体手机，忽略离线模拟器。

实机发现并修复：record插件默认自行申请焦点，与本机双工播放管理器冲突。改成`AudioInterruptionMode.none`由原生层统一拥有焦点，外部焦点丢失仍会暂停和释放录音；迟到配置确认不再把设备暂停误报为音色不一致。AudioTrack队列休眠前补报硬件播放结束，已观察试听从44.1kHz回到通话24kHz。

## 2026-10-27 Release 插件注册注意

iOS加入integration_test开发依赖后，不要直接复用测试阶段生成的插件列表并使用 `build apk --no-pub`。该SDK的Release Gradle会排除开发插件，但旧GeneratedPluginRegistrant仍可能引用IntegrationTestPlugin，导致Java编译失败。先 `./tools/flutter-cn.sh pub get --offline` 确认本地依赖完整，再运行上面的正常Release构建（保留默认pub步骤），让Flutter按Release模式重新生成注册列表。不要手改自动生成Java文件，也不要把测试插件移入生产依赖。


## 0.4.45 服务端统一音色配置

音色名称、顺序、默认值和试听地址直接读取 `/v1/models`，移除客户端强制置顶 Atlas 的规则及写死的音色默认编号。`voice_default_revision` 由服务端控制，每个服务地址/模型只应用一次新默认，之后保留手选；旧版本不会覆盖新版本记录。设置和音色弹窗打开时刷新，刷新失败保留旧列表，通话中不自动换声。`voice_catalog_revision` 标记名称/顺序等目录更新。当前服务端目录为8款，Sterling（Ezra）首位且默认；Nexus与Titan已由服务端移除。目录和默认策略版本均为2，客户端不写死这些值。

版本 0.4.45+77，沿用原个人签名，无需卸载或清除资料。服务端和 Web 同步协议；后续改选择项只需修改服务端配置并发布，不需再重新打客户端包。
