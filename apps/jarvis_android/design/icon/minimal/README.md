# Jarvis 极简品牌符号

用户明确的新方向：参考TikTok、Grok、GitHub、Gemini的简洁与辨识度，不再沿用复杂天体插画。黑底、平面、清楚轮廓，仅白色与一处冰蓝强调；不复制参考品牌的具体商标。

三款为原创路径：A Prism（折光）、B Echo（回声）、C Visor（智瞳）。options.json为单一几何来源，SVG与Android向量从同一组路径导出；tools/minimal_icon_options.dart负责实际像素渲染。已检查512px以及48/96px效果。默认推荐C已用于本轮图标；A、B保留为可选源稿。tools/export_minimal_icon.dart从同一JSON导出Android前景/单色/旧版向量与各密度PNG及应用内小标识。

公开参考：
- https://brand.github.com/foundations/logo ：高对比、留白、单一符号识别。
- https://developers.tiktok.com/docs/en/getting-started-design-guidelines ：品牌/官方图形参考。
- https://x.ai/legal/brand-guidelines ：Grok品牌参考。
- https://gemini.google/about/ ：AI助手品牌与图形语言参考。

设计资产使用本地矢量绘制，没有使用生成式位图和纹理，也没有安装新图形依赖。48px识别度与单色轮廓优先于大图装饰效果。
