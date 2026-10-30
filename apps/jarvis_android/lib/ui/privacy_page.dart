import 'dart:async';

import 'package:flutter/material.dart';

import '../model/app_info.dart';
import '../state/jarvis_controller.dart';
import 'duo_rail.dart';
import 'ios_scroll.dart';
import 'design_tokens.dart';
import 'jarvis_app.dart' show openLink;
import 'settings_widgets.dart';

/// Where the privacy policy and the support address live. Empty means "not published yet": the matching row stays
/// hidden. Both come from `AppInfo`.
class PrivacyLinks {
  const PrivacyLinks._();
  static const privacyPolicyUrl = AppInfo.privacyPolicyUrl;
  static const supportEmail = AppInfo.supportEmail;
}

/// Keeps a paragraph's last two characters on one line, so a wrap never leaves a single character (and its full stop)
/// alone on the last line ("…对话内 / 容。"): a word joiner (U+2060, invisible, no break on either side) goes between
/// them. Only between two Chinese characters; other endings are left as they are.
String noOrphan(String text) => text.replaceFirstMapped(
  RegExp(r'([一-鿿])([一-鿿][。！？；」）]*)$'),
  (m) => '${m[1]}⁠${m[2]}',
);

/// What is sent, what is kept, and how to delete it: the plain-language counterpart of the App Store privacy details.
class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key, required this.controller});
  final JarvisController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final server = controller.api.endpoint.origin;
    final policy = PrivacyLinks.privacyPolicyUrl;
    final email = PrivacyLinks.supportEmail;
    Widget para(String text, {String? title}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                title,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          Text(
            noOrphan(text),
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.5),
          ),
        ],
      ),
    );
    Widget link(IconData icon, String title, Uri uri) => ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minTileHeight: 52,
      // The icon is 22 pt in a 24 pt slot: the text starts at 56, where the dividers do.
      minLeadingWidth: 24,
      leading: Icon(icon, size: 22),
      title: Text(title),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => unawaited(openLink(context, uri)),
    );
    return DuoRailPage(
      top: [DuoRailPage.back(context)],
      child: Scaffold(
        appBar: AppBar(
          title: const Text('隐私与数据使用'),
          automaticallyImplyLeading: !DuoRailPage.active(context),
        ),
        body: SoftBottomEdge(
          keyboardUp: SoftBottomEdge.keyboardShown(context),
          child: SafeArea(
            bottom: !SoftBottomEdge.active(context),
            child: SingleChildScrollView(
              key: const Key('privacy-scroll'),
              physics: iosScrollPhysics,
              padding: EdgeInsets.fromLTRB(
                Metrics.pageMargin,
                0,
                Metrics.pageMargin,
                30 + SoftBottomEdge.inset(context),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SettingsSection(
                        title: '会发送到服务的内容',
                        footer: '服务器地址：$server',
                        children: [
                          para('你输入的文字。', title: '文字'),
                          para(
                            '你在对话里添加的图片、拍摄的照片和文件。只发送你亲自选的，应用不会浏览你的相册。',
                            title: '图片与文件',
                          ),
                          para(
                            '语音通话中，麦克风的声音会实时发送到服务，用于识别你的话并生成回答。按住说话时只在按住期间发送，静音或通话结束后不再发送。',
                            title: '通话语音',
                          ),
                          para('你选择的模型、音色和语音识别等设置，会随请求一起发送。', title: '模型与语音设置'),
                        ],
                      ),
                      SettingsSection(
                        title: '保存在这台设备上的内容',
                        children: [
                          para(
                            '会话、通话的文字记录和附件保存在本机的加密文件里，加密密钥由系统钥匙串保管。退出登录不会删除它们。',
                          ),
                        ],
                      ),
                      SettingsSection(
                        title: '关于 AI 生成的内容',
                        children: [
                          para(
                            '回复由人工智能生成，可能不准确、不完整或已过时。重要的事请自行核实，不要把它当作医疗、法律或财务方面的专业意见。',
                          ),
                        ],
                      ),
                      SettingsSection(
                        title: '如何删除数据',
                        children: [
                          para('在会话列表里可以删除单个会话。', title: '删除一个会话'),
                          para(
                            '在 设置 > 数据 > 删除全部会话，清除这台设备上的全部会话和附件。',
                            title: '删除全部',
                          ),
                          para(
                            '退出登录会中断进行中的任务和通话。已经发送到服务的内容会保留多久，由服务提供者决定。',
                            title: '退出登录',
                          ),
                        ],
                      ),
                      SettingsSection(
                        title: '遇到不当内容',
                        children: [
                          para(
                            email.isEmpty
                                ? '如果回复含有不当或有害的内容，请联系你的服务提供者，并附上相关的对话内容。'
                                : '如果回复含有不当或有害的内容，请发邮件到 $email，并附上相关的对话内容。',
                          ),
                        ],
                      ),
                      if (policy.isNotEmpty || email.isNotEmpty)
                        SettingsSection(
                          title: '更多',
                          dividerIndent: SettingsGroup.iconIndent,
                          children: [
                            if (policy.isNotEmpty)
                              link(
                                Icons.policy_outlined,
                                '隐私政策',
                                Uri.parse(policy),
                              ),
                            if (email.isNotEmpty)
                              link(
                                Icons.mail_outline,
                                '联系支持',
                                Uri(scheme: 'mailto', path: email),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The notice shown once before first use: replies come from an AI, and what leaves the device. True when the user
/// agrees; the caller remembers that and does not ask again. Pass [controller] to name the server and offer the full
/// privacy page.
Future<bool> showAiDisclosure(
  BuildContext context, {
  JarvisController? controller,
}) async {
  final agreed = await showFoldDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context, insets) {
      final server = controller?.api.endpoint.origin;
      Widget point(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: const TextStyle(height: 1.5)),
      );
      return AlertDialog(
        insetPadding: insets,
        title: const Text('使用前请知悉'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              point('JARVIS 是人工智能助手，回复由 AI 生成，可能有误。重要的事请自行核实。'),
              point(
                '你输入的文字、添加的图片和文件，以及通话中的语音，会发送到 JARVIS 服务'
                '${server == null ? '' : '（$server）'}来生成回复。',
              ),
              point('会话保存在这台设备上，可以随时在 设置 > 数据 里删除。'),
              if (controller != null)
                TextButton(
                  key: const Key('disclosure-privacy'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    // The accent (not the near-body-text primary) marks it as a link.
                    foregroundColor: JarvisColors.accent(context),
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                  ),
                  onPressed: () => unawaited(
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        settings: const RouteSettings(name: 'privacy'),
                        builder: (_) => PrivacyPage(controller: controller),
                      ),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Flexible: at the largest text sizes the label wraps instead of pushing the chevron out.
                      Flexible(
                        child: Text(
                          '查看隐私与数据使用',
                          style: TextStyle(
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 20),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(64, 44)),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('同意'),
          ),
        ],
      );
    },
  );
  return agreed == true;
}
