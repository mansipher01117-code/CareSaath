import 'package:flutter/material.dart';

import '../api.dart';
import '../profiles.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'profiles_screen.dart';

class TodayScreen extends StatelessWidget {
  final VoidCallback onAsk;
  final VoidCallback onAdd;
  const TodayScreen({super.key, required this.onAsk, required this.onAdd});

  Future<List<Json>> _load(String pid) =>
      Future.wait([Api.person(pid), Api.preparation(pid), Api.latestChange(pid)]);

  @override
  Widget build(BuildContext context) {
    final pid = profiles.selectedId;
    if (pid == null) return const SizedBox.shrink();
    return Loader<List<Json>>(
      load: () => _load(pid),
      builder: (context, d) {
        final person = d[0];
        final prep = d[1];
        final change = d[2];
        final items = (prep['items'] as List).cast<Json>();
        final appts = (person['appointments'] as List).cast<Json>();
        final pending = items.where((i) => i['status'] != 'receipt_documented').length;
        final wide = MediaQuery.sizeOf(context).width >= 1100;

        final left = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Header(person: person),
          const SizedBox(height: 20),
          // The backend returns appointments soonest first; "Next" is only
          // honest about one that is still ahead.
          if (appts.isNotEmpty)
            AppointmentCard(appt: appts.firstWhere((a) => a['upcoming'] == true,
                orElse: () => appts.first))
          else
            const EmptyState(
              icon: Icons.event_busy_outlined,
              title: 'No appointment on record',
              body: 'When a record says an appointment is confirmed, it shows up here with its source.',
            ),
          const SizedBox(height: 28),
          Row(children: [
            Text('Appointment preparation', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            if (items.isNotEmpty)
              Text('$pending to clarify', style: const TextStyle(color: C.marigold, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 4),
          const Text('Status is derived by following graph links to receipt evidence — never guessed.',
              style: TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 14),
          if (items.isEmpty)
            EmptyState(
              icon: Icons.checklist_rounded,
              title: 'Nothing to follow up yet',
              body: 'Add a visit note that asks you to bring something, and it will be tracked here '
                  'until a record shows it was received.',
              action: FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add a record'),
              ),
            )
          else
            for (final i in items) ...[_PrepItem(item: i), const SizedBox(height: 12)],
        ]);

        final right = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (change.isNotEmpty) ChangeCard(change: change),
          if (change.isNotEmpty) const SizedBox(height: 16),
          _AskCard(onAsk: onAsk, name: (person['name'] ?? '').toString()),
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

/// "Receipt recorded 20 Nov 2026 · Clinic front-desk note".
///
/// The date is when the item was received, which the extractor reads from the
/// sentence that records it. Only when that sentence named no date at all does
/// the document's own date stand in, and then the line says so instead of
/// letting the filing date pass for the event date.
String receiptLine(Json receipt) {
  final date = prettyDate('${receipt['date'] ?? ''}');
  final title = '${receipt['doc_title'] ?? ''}'.trim();
  final marked = receipt['date_source'] == 'document' ? '$date (document date)' : date;
  return [
    date.isEmpty ? 'Receipt recorded' : 'Receipt recorded $marked',
    if (title.isNotEmpty) title,
  ].join(' · ');
}

/// A recognisable icon for whatever the item turned out to be.
IconData itemIcon(String key) {
  final k = key.toLowerCase();
  bool has(List<String> words) => words.any(k.contains);
  if (has(['bp', 'pressure', 'sugar', 'glucose', 'ecg', 'pulse'])) return Icons.monitor_heart_outlined;
  if (has(['card', 'insurance', 'policy', 'aadhaar', 'id'])) return Icons.badge_outlined;
  if (has(['x_ray', 'xray', 'scan', 'mri', 'ct', 'ultrasound', 'sonography'])) return Icons.image_outlined;
  if (has(['prescription', 'medicine', 'medication', 'tablet', 'dose'])) return Icons.medication_outlined;
  if (has(['lab', 'blood', 'test', 'profile', 'thyroid', 'report'])) return Icons.science_outlined;
  return Icons.description_outlined;
}

class _Header extends StatelessWidget {
  final Json person;
  const _Header({required this.person});

  @override
  Widget build(BuildContext context) {
    final name = (person['name'] ?? '').toString();
    final caregiver = (person['caregiver'] ?? '').toString();
    final records = person['records'] ?? 0;
    return Row(children: [
      Avatar(name: name, radius: 26),
      const SizedBox(width: 14),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$name’s care', style: Theme.of(context).textTheme.headlineLarge),
          Text(
            [
              person['relation'] ?? '',
              if (caregiver.isNotEmpty) 'caregiver $caregiver',
              '$records confirmed ${records == 1 ? 'record' : 'records'}',
            ].join(' · '),
            style: const TextStyle(color: C.muted),
          ),
        ]),
      ),
    ]);
  }
}

class AppointmentCard extends StatelessWidget {
  final Json appt;
  const AppointmentCard({super.key, required this.appt});

  @override
  Widget build(BuildContext context) {
    final src = (appt['sources'] as List).cast<Json>().where((s) => s['span_id'] != null).toList();
    final year = '${appt['year'] ?? ''}'.trim();
    final upcoming = appt['upcoming'] == true;
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
            // Only an appointment still ahead is the "next" one. Anything else
            // gets a label that claims nothing about when it is.
            Eyebrow(upcoming ? 'Next appointment' : 'Appointment on record',
                color: Colors.white70),
            const SizedBox(height: 4),
            Text('${appt['time']} · confirmed',
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
            Text(year.isEmpty ? 'Year not stated in the record' : year,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: year.isEmpty ? 0.6 : 0.8),
                    fontSize: 12,
                    fontStyle: year.isEmpty ? FontStyle.italic : FontStyle.normal)),
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
            child: Icon(itemIcon('${item['item']}'), color: ok ? C.teal : C.marigold),
          ),
          const SizedBox(width: 14),
          Expanded(child: Text(item['label'], style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
          StatusPill(item['status']),
        ]),
        const SizedBox(height: 14),
        for (final r in req)
          _EvidenceLine(icon: Icons.assignment_outlined, text: 'Requested in ${r['doc_title']} · ${r['date']}', spanId: r['span_id'], docId: r['doc_id']),
        for (final r in rec)
          _EvidenceLine(icon: Icons.inventory_2_outlined, text: receiptLine(r), spanId: r['span_id'], docId: r['doc_id']),
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

/// "What changed" after the last confirmed record: what moved, what stayed.
class ChangeCard extends StatelessWidget {
  final Json change;
  const ChangeCard({super.key, required this.change});

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
          _row(Icons.change_circle_rounded, C.teal, c,
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_s(c['from']), style: const TextStyle(decoration: TextDecoration.lineThrough, color: C.muted, fontSize: 13)),
                const Icon(Icons.arrow_forward_rounded, size: 14, color: C.muted),
                Text(_s(c['to']), style: const TextStyle(color: C.teal, fontWeight: FontWeight.w700, fontSize: 13)),
              ])),
        for (final c in added)
          _row(Icons.add_circle_rounded, C.plum, c,
              const Text('Now tracked', style: TextStyle(color: C.plum, fontWeight: FontWeight.w700, fontSize: 13))),
        for (final c in unchanged)
          _row(Icons.pause_circle_outline_rounded, C.muted, c,
              Text('Unchanged · ${_s(c['status'])}', style: const TextStyle(color: C.muted, fontSize: 13))),
      ]),
    );
  }

  /// Each row cites the span that actually evidences that item. The card used
  /// to show one chip for the whole change, pointing at a guessed "<doc>-P1" —
  /// a span id that often did not exist, and when it did, usually belonged to
  /// an unrelated paragraph.
  Widget _row(IconData icon, Color color, Json entry, Widget trailing) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text('${entry['label']}', style: const TextStyle(fontWeight: FontWeight.w700))),
          Flexible(child: Align(alignment: Alignment.centerRight, child: trailing)),
          if (entry['span_id'] != null) ...[
            const SizedBox(width: 8),
            SourceChip(spanId: entry['span_id'], docId: entry['doc_id']),
          ],
        ]),
      );
}

class _AskCard extends StatelessWidget {
  final VoidCallback onAsk;
  final String name;
  const _AskCard({required this.onAsk, required this.name});
  @override
  Widget build(BuildContext context) => Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Eyebrow('Ask CareSaath'),
          const SizedBox(height: 6),
          Text('Questions in your language, answers with sources.', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text('Only $name’s confirmed records are used.', style: const TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 14),
          OutlinedButton.icon(onPressed: onAsk, icon: const Icon(Icons.forum_outlined), label: const Text('Open Ask')),
        ]),
      );
}
