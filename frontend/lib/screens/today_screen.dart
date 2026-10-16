import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/common.dart';

class TodayScreen extends StatelessWidget {
  final VoidCallback onAsk;
  final VoidCallback onAdd;
  const TodayScreen({super.key, required this.onAsk, required this.onAdd});

  Future<List<Json>> _load() => Future.wait([Api.person(), Api.preparation(), Api.latestChange()]);

  @override
  Widget build(BuildContext context) {
    return Loader<List<Json>>(
      load: _load,
      builder: (context, d) {
        final person = d[0];
        final prep = d[1];
        final change = d[2];
        final items = (prep['items'] as List).cast<Json>();
        final appts = (person['appointments'] as List).cast<Json>();
        final pending = items.where((i) => i['status'] != 'receipt_documented').length;
        final wide = MediaQuery.sizeOf(context).width >= 1100;

        final left = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Header(person: person, pending: pending, total: items.length),
          const SizedBox(height: 20),
          if (appts.isNotEmpty) _AppointmentCard(appt: appts.first),
          const SizedBox(height: 28),
          Row(children: [
            Text('Appointment preparation', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            Text('$pending to clarify', style: const TextStyle(color: C.marigold, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 4),
          const Text('Status is derived by following graph links to receipt evidence — never guessed.',
              style: TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 14),
          if (items.isEmpty)
            const Panel(child: Text('No requested items yet. Add a visit note to get started.'))
          else
            for (final i in items) ...[_PrepItem(item: i), const SizedBox(height: 12)],
        ]);

        final right = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (change.isNotEmpty) _ChangeCard(change: change),
          if (change.isNotEmpty) const SizedBox(height: 16),
          _AskCard(onAsk: onAsk),
          const SizedBox(height: 16),
          _DemoCard(onAdd: onAdd),
        ]);

        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: wide ? 40 : 18, vertical: 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 3, child: left),
                      const SizedBox(width: 28),
                      Expanded(flex: 2, child: right),
                    ])
                  : Column(children: [left, const SizedBox(height: 24), right, const SizedBox(height: 80)]),
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final Json person;
  final int pending;
  final int total;
  const _Header({required this.person, required this.pending, required this.total});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SyntheticBadge(),
        const SizedBox(height: 18),
        Row(children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: C.marigoldSoft,
            child: Text((person['name'] ?? 'A').toString()[0],
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: C.marigold)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("${person['name']}'s care", style: Theme.of(context).textTheme.headlineLarge),
              Text('${person['relation']} · caregiver ${person['caregiver']} · ${person['records']} confirmed records',
                  style: const TextStyle(color: C.muted)),
            ]),
          ),
        ]),
      ]);
}

class _AppointmentCard extends StatelessWidget {
  final Json appt;
  const _AppointmentCard({required this.appt});

  @override
  Widget build(BuildContext context) {
    final src = (appt['sources'] as List).cast<Json>().where((s) => s['span_id'] != null).toList();
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(colors: [C.teal, Color(0xFF13806E)], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Text(appt['date'].toString().split(' ').first,
                style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, height: 1)),
            Text(appt['date'].toString().split(' ').skip(1).join(' ').toUpperCase(),
                style: const TextStyle(color: Colors.white70, fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
          ]),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Eyebrow('Next appointment', color: Colors.white70),
            const SizedBox(height: 4),
            Text('${appt['time']} · confirmed',
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
          ]),
        ),
        if (src.isNotEmpty) SourceChip(spanId: src.first['span_id'], docId: src.first['doc_id']),
      ]),
    );
  }
}

class _PrepItem extends StatelessWidget {
  final Json item;
  const _PrepItem({required this.item});

  @override
  Widget build(BuildContext context) {
    final req = (item['requested_by'] as List).cast<Json>();
    final rec = (item['receipts'] as List).cast<Json>();
    final ok = item['status'] == 'receipt_documented';
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: ok ? C.tealSoft : C.marigoldSoft, borderRadius: BorderRadius.circular(12)),
            child: Icon(item['item'] == 'bp_log' ? Icons.monitor_heart_outlined : Icons.science_outlined,
                color: ok ? C.teal : C.marigold),
          ),
          const SizedBox(width: 14),
          Expanded(child: Text(item['label'], style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
          StatusPill(item['status']),
        ]),
        const SizedBox(height: 14),
        for (final r in req)
          _EvidenceLine(icon: Icons.assignment_outlined, text: 'Requested in ${r['doc_title']} · ${r['date']}', spanId: r['span_id'], docId: r['doc_id']),
        for (final r in rec)
          _EvidenceLine(icon: Icons.inventory_2_outlined, text: 'Receipt recorded ${r['date']} · ${r['doc_title']}', spanId: r['span_id'], docId: r['doc_id']),
        if (rec.isEmpty)
          const _EvidenceLine(icon: Icons.search_off_rounded, text: 'No receipt found in confirmed records — clarify at the visit'),
        const SizedBox(height: 10),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Show graph path', style: TextStyle(fontSize: 13, color: C.muted, fontWeight: FontWeight.w600)),
            children: [Align(alignment: Alignment.centerLeft, child: PathTrail(item['path'] as List))],
          ),
        ),
      ]),
    );
  }
}

class _EvidenceLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? spanId;
  final String? docId;
  const _EvidenceLine({required this.icon, required this.text, this.spanId, this.docId});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Icon(icon, size: 17, color: C.muted),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
          if (spanId != null) SourceChip(spanId: spanId!, docId: docId!),
        ]),
      );
}

/// "What changed" — the signature demo moment: what moved, what stayed.
class _ChangeCard extends StatelessWidget {
  final Json change;
  const _ChangeCard({required this.change});

  String _s(String s) => s == 'receipt_documented' ? 'Documented' : 'Not documented';

  @override
  Widget build(BuildContext context) {
    final changed = (change['changed'] as List).cast<Json>();
    final unchanged = (change['unchanged'] as List).cast<Json>();
    final added = (change['added'] as List).cast<Json>();
    return Panel(
      color: C.plumSoft,
      border: C.plum.withValues(alpha: 0.2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Eyebrow('What changed', color: C.plum),
        const SizedBox(height: 6),
        Text('After ${change['doc_id']} · ${change['doc_title']}', style: Theme.of(context).textTheme.titleLarge),
        Text(change['doc_date'] ?? '', style: const TextStyle(color: C.muted)),
        const SizedBox(height: 14),
        for (final c in changed)
          _row(Icons.change_circle_rounded, C.teal, c['label'],
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_s(c['from']), style: const TextStyle(decoration: TextDecoration.lineThrough, color: C.muted, fontSize: 13)),
                const Icon(Icons.arrow_forward_rounded, size: 14, color: C.muted),
                Text(_s(c['to']), style: const TextStyle(color: C.teal, fontWeight: FontWeight.w700, fontSize: 13)),
              ])),
        for (final c in added)
          _row(Icons.add_circle_rounded, C.plum, c['label'],
              Text('Now tracked', style: const TextStyle(color: C.plum, fontWeight: FontWeight.w700, fontSize: 13))),
        for (final c in unchanged)
          _row(Icons.pause_circle_outline_rounded, C.muted, c['label'],
              Text('Unchanged · ${_s(c['status'])}', style: const TextStyle(color: C.muted, fontSize: 13))),
        const SizedBox(height: 6),
        SourceChip(spanId: '${change['doc_id']}-P1', docId: change['doc_id']),
      ]),
    );
  }

  Widget _row(IconData icon, Color color, String label, Widget trailing) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
          Flexible(child: Align(alignment: Alignment.centerRight, child: trailing)),
        ]),
      );
}

class _AskCard extends StatelessWidget {
  final VoidCallback onAsk;
  const _AskCard({required this.onAsk});
  @override
  Widget build(BuildContext context) => Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Eyebrow('Ask CareSaath'),
          const SizedBox(height: 6),
          Text('Questions in your language, answers with sources.', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          OutlinedButton.icon(onPressed: onAsk, icon: const Icon(Icons.forum_outlined), label: const Text('Open Ask')),
        ]),
      );
}

class _DemoCard extends StatelessWidget {
  final VoidCallback onAdd;
  const _DemoCard({required this.onAdd});
  @override
  Widget build(BuildContext context) => Panel(
        color: C.marigoldSoft,
        border: C.marigold.withValues(alpha: 0.25),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Eyebrow('Demo script', color: C.marigold),
          const SizedBox(height: 8),
          const Text('1. Both items show “not documented”.\n2. Add record → “Fill demo record (D04)”.\n3. Review and confirm.\n4. Only the lab report changes; BP log stays.',
              style: TextStyle(height: 1.6)),
          const SizedBox(height: 14),
          Wrap(spacing: 10, runSpacing: 10, children: [
            FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add_rounded), label: const Text('Add record')),
            OutlinedButton(
              onPressed: () async {
                await Api.resetDemo();
                refreshAll();
              },
              child: const Text('Reset demo data'),
            ),
          ]),
        ]),
      );
}
