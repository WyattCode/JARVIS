# 原D与原A衍生六版（供选形）

用户已认可原D和原A，分别要求衍生三个版本，D系和A系均保留。默认不选定、不发布到App。

D-A：去掉外围刻度；D-B：增加中间圆环并保留线圈；D-C：三段开环。
A-A：减少外圈细节；A-B：双线线圈；A-C：开环与六处短刻度。

三角/圆形核心的位置与基础构图保持，六版统一画幅、配色。create_variants.py生成SVG与schemes.json，tools/preview_reactor.dart读取该目录导出48/96/512px用于检查。

网页：http://192.168.1.101:18765/?v=reactor-six-v1
当前未改App、未编译APK、未改后台服务。
