/// 外壳：底部导航 + 全局的新建入口 + 到点提醒的弹出。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../domain/entry.dart';
import 'assistant_page.dart';
import 'entries_page.dart';
import 'entry_editor_page.dart';
import 'settings_page.dart';
import 'today_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;
  StreamSubscription<Entry>? _fireSubscription;

  @override
  void initState() {
    super.initState();
    // 先订阅再补发：这样「启动时补报的错过提醒」与「运行中新到的提醒」都不会漏。
    _fireSubscription = widget.controller.fires.listen(_announce);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final entry in widget.controller.drainPendingFires()) {
        _announce(entry);
      }
    });
  }

  @override
  void dispose() {
    _fireSubscription?.cancel();
    super.dispose();
  }

  void _announce(Entry entry) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 6),
      content: Row(
        children: [
          const Icon(Icons.alarm, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(child: Text('提醒：${entry.title}')),
        ],
      ),
    ));
  }

  Future<void> _createEntry() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EntryEditorPage(controller: widget.controller),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final showFab = _index == 0 || _index == 1;

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          TodayPage(controller: widget.controller),
          EntriesPage(controller: widget.controller),
          AssistantPage(
            controller: widget.controller,
            onOpenSettings: () => setState(() => _index = 3),
          ),
          SettingsPage(controller: widget.controller),
        ],
      ),
      floatingActionButton: showFab
          ? FloatingActionButton(
              onPressed: _createEntry,
              tooltip: '新建',
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.wb_sunny_outlined),
            selectedIcon: Icon(Icons.wb_sunny),
            label: '今日',
          ),
          NavigationDestination(
            icon: Icon(Icons.inbox_outlined),
            selectedIcon: Icon(Icons.inbox),
            label: '条目',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: '助手',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
