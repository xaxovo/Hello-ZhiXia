/// 「助手」—— 与云端模型的对话界面。
///
/// 助手不是另一个功能入口，它是**另一条操作数据的路径**：它通过工具创建与修改
/// 和手动操作完全相同的条目，因此做完之后「今日」和「条目」里立刻能看到。
library;

import 'package:material_ui/material_ui.dart';

import '../agent/assistant.dart';
import '../app.dart';

class AssistantPage extends StatefulWidget {
  const AssistantPage({super.key, required this.controller, required this.onOpenSettings});

  final AppController controller;
  final VoidCallback onOpenSettings;

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  final TextEditingController _input = TextEditingController();
  final List<ChatTurn> _turns = [];
  final ScrollController _scroll = ScrollController();
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;

    setState(() {
      _turns.add(ChatTurn(role: 'user', text: text));
      _busy = true;
    });
    _input.clear();
    _scrollToEnd();

    try {
      final reply = await widget.controller.assistant.ask(
        text,
        onTurn: (turn) {
          if (!mounted) return;
          setState(() => _turns.add(turn));
          _scrollToEnd();
        },
      );
      if (!mounted) return;
      setState(() => _turns.add(ChatTurn(role: 'assistant', text: reply)));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _turns.add(ChatTurn(role: 'assistant', text: '出错了：$error')));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _scrollToEnd();
      }
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final configured = widget.controller.settings.isConfigured;

    return Scaffold(
      appBar: AppBar(
        title: const Text('知夏'),
        actions: [
          IconButton(
            tooltip: '清空对话上下文',
            onPressed: () => setState(() {
              _turns.clear();
              widget.controller.assistant.reset();
            }),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!configured) _SetupBanner(onTap: widget.onOpenSettings),
          Expanded(
            child: _turns.isEmpty
                ? const _EmptyChat()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: _turns.length + (_busy ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _turns.length) return const _ThinkingBubble();
                      return _Bubble(turn: _turns[index]);
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(hintText: '说点什么…'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : _send,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    ),
                    child: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});

  final ChatTurn turn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = turn.isUser;
    final isTool = turn.role == 'tool';

    final background = isUser
        ? theme.colorScheme.primaryContainer
        : isTool
            ? theme.colorScheme.surfaceContainerHighest
            : theme.colorScheme.surfaceContainerLow;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          turn.text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: isTool ? theme.colorScheme.onSurfaceVariant : null,
            fontStyle: isTool ? FontStyle.italic : null,
          ),
        ),
      ),
    );
  }
}

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble();

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: ListTile(
        leading: const Icon(Icons.key_outlined),
        title: const Text('还没有配置模型'),
        subtitle: const Text('填入任意 OpenAI 兼容接口的地址与密钥即可开始使用'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const hints = [
      '明天上午十点提醒我交周报',
      '把「想读的书」建成一条笔记',
      '这周还有哪些没做完的待办？',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('可以这样问', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          for (final hint in hints)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '· $hint',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
