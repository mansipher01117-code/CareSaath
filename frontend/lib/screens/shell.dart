import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api.dart';
import '../theme.dart';
import 'add_record_screen.dart';
import 'ask_screen.dart';
import 'graph_screen.dart';
import 'records_screen.dart';
import 'today_screen.dart';

/// Responsive shell: side rail on wide screens (web), bottom nav on phones.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int index = 0;

  static const _dest = [
    (Icons.wb_sunny_outlined, Icons.wb_sunny_rounded, 'Today'),
    (Icons.history_edu_outlined, Icons.history_edu_rounded, 'Records'),
    (Icons.forum_outlined, Icons.forum_rounded, 'Ask'),
    (Icons.hub_outlined, Icons.hub_rounded, 'Graph'),
  ];

  void go(int i) => setState(() => index = i);

  Future<void> addRecord() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddRecordScreen()));
    refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final pages = [
      TodayScreen(onAsk: () => go(2), onAdd: addRecord),
      const RecordsScreen(),
      const AskScreen(),
      const GraphScreen(),
    ];
    final body = IndexedStack(index: index, children: pages);

    if (wide) {
      return Scaffold(
        body: Row(children: [
          Container(
            width: 240,
            decoration: const BoxDecoration(border: Border(right: BorderSide(color: C.line))),
            padding: const EdgeInsets.fromLTRB(16, 28, 16, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const _Brand(),
              const SizedBox(height: 32),
              for (var i = 0; i < _dest.length; i++)
                _RailItem(
                  icon: index == i ? _dest[i].$2 : _dest[i].$1,
                  label: _dest[i].$3,
                  selected: index == i,
                  onTap: () => go(i),
                ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(onPressed: addRecord, icon: const Icon(Icons.add_rounded), label: const Text('Add record')),
              ),
              const Spacer(),
              const _HealthDot(),
            ]),
          ),
          Expanded(child: body),
        ]),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const _Brand(), actions: const [_HealthDot(), SizedBox(width: 12)]),
      body: body,
      floatingActionButton: index <= 1
          ? FloatingActionButton.extended(
              onPressed: addRecord,
              backgroundColor: C.teal,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add record'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: go,
        backgroundColor: C.card,
        indicatorColor: C.tealSoft,
        destinations: [
          for (final d in _dest) NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2, color: C.teal), label: d.$3),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: C.teal, borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.favorite_rounded, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Text('CareSaath', style: GoogleFonts.fraunces(fontSize: 22, fontWeight: FontWeight.w700, color: C.ink)),
      ]);
}

class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _RailItem({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Material(
          color: selected ? C.tealSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Icon(icon, color: selected ? C.teal : C.muted, size: 21),
                const SizedBox(width: 12),
                Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: selected ? C.teal : C.ink)),
              ]),
            ),
          ),
        ),
      );
}

/// Shows whether the API and FalkorDB are reachable.
class _HealthDot extends StatelessWidget {
  const _HealthDot();
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: dataVersion,
        builder: (context, v, _) => FutureBuilder<Json>(
          key: ValueKey(v),
          future: Api.health(),
          builder: (context, snap) {
            final ok = snap.hasData && snap.data!['graph'] == 'ok';
            final label = snap.hasError ? 'API offline' : (ok ? 'FalkorDB connected' : (snap.hasData ? 'Graph unavailable' : 'Checking…'));
            final color = ok ? C.teal : (snap.hasData || snap.hasError ? C.rose : C.muted);
            return Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
            ]);
          },
        ),
      );
}
