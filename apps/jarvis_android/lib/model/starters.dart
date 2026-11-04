import 'dart:math';

class Starter {
  const Starter(this.title, this.prompt, {this.requires, this.description});
  final String title, prompt;
  final String? requires;

  /// One-line explanation under the title on the foldable welcome screen: the web client's SUGGEST_HINTS, verbatim
  /// (src/voice/voice.html).
  final String? description;
}

/// The web client's greeting: before 5 "还没休息吗？", before 12 "早上好", before 18 "下午好", otherwise "晚上好".
String timeGreeting(DateTime now) {
  final h = now.hour;
  return h < 5
      ? '还没休息吗？'
      : h < 12
      ? '早上好'
      : h < 18
      ? '下午好'
      : '晚上好';
}

// Same four capability groups as the web client. Pick once per app session.
const starterGroups = [
  [
    Starter('拆解一个问题', '我有一个问题想理清，请先问我最关键的三个问题。', description: '抓住核心，找到下一步'),
    Starter('比较两个选择', '帮我比较两个选择，先了解我的目标、预算和限制。', description: '按你的目标和限制权衡'),
    Starter('把概念讲明白', '我想学懂一个概念，请先问主题，再用例子解释。', description: '用直观的例子理解新知识'),
    Starter('检查我的想法', '我想让你检查一个想法，找出假设和可能忽略的风险。', description: '找盲点，也找可行的改进'),
  ],
  [
    Starter('把灵感写下来', '我有一点创作灵感，请先问我内容和用途，再帮我展开。', description: '把模糊的想法变成草稿'),
    Starter('写得更自然', '帮我润色一段话，保留我的意思。请先让我发原文。', description: '保留你的意思，表达更清楚'),
    Starter(
      '画一幅水彩',
      '帮我设计一幅水彩画，请先问我想画什么和希望的氛围。',
      requires: 'image',
      description: '一起定主体、色彩和氛围',
    ),
    Starter(
      '设计一张海报',
      '我想做一张海报，请先了解主题、受众和需要的文字。',
      requires: 'image',
      description: '从主题和用途开始构图',
    ),
    Starter('开始一个故事', '和我一起构思一个故事，请先问我喜欢的题材。', description: '从一个人物或场景开始'),
  ],
  [
    Starter('一起查个 Bug', '帮我排查代码问题，请先问错误现象、环境和相关代码。', description: '从现象和线索定位问题'),
    Starter('做一个小工具', '我想做一个实用的小工具，请先了解需要解决的问题。', description: '编写处理重复工作的工具代码'),
    Starter('读懂一段代码', '帮我理解一段代码，请先让我贴代码，再解释它的作用。', description: '讲清逻辑与关键细节'),
    Starter('审查实现方案', '帮我审查一个技术方案，请先问目标、约束和当前实现。', description: '检查约束、取舍和风险'),
  ],
  [
    Starter('理清今天的事', '帮我安排接下来的事情，先了解我的任务、时间和优先级。', description: '分清轻重，安排时间'),
    Starter(
      '把资料变成行动',
      '我有一份资料需要整理，请先让我发内容，再提取重点和下一步。',
      description: '提炼重点和待办事项',
    ),
    Starter(
      '准备一次沟通',
      '帮我准备一次重要沟通，请先问对象、目标和担心的地方。',
      description: '理清目的，组织好要说的话',
    ),
    Starter(
      '把目标拆成步骤',
      '帮我把一个目标拆成可执行的步骤，请先了解目标和期限。',
      description: '从目标走到可执行的行动',
    ),
  ],
];

class SessionStarters {
  SessionStarters()
    : order = [
        for (final group in starterGroups) (List.of(group)..shuffle(Random())),
      ];
  final List<List<Starter>> order;
  List<Starter> available(bool Function(String) supports) => [
    for (final group in order)
      group.firstWhere((s) => s.requires == null || supports(s.requires!)),
  ];
}
