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
          _row(context, Icons.change_circle_rounded, C.teal, c,
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_s(c['from']), style: const TextStyle(decoration: TextDecoration.lineThrough, color: C.muted, fontSize: 13)),
                const Icon(Icons.arrow_forward_rounded, size: 14, color: C.muted),
                Text(_s(c['to']), style: const TextStyle(color: C.teal, fontWeight: FontWeight.w700, fontSize: 13)),
              ]),
              // Only something that moved has two ends to put side by side.
              why: true),
        for (final c in added)
          _row(context, Icons.add_circle_rounded, C.plum, c,
              const Text('Now tracked', style: TextStyle(color: C.plum, fontWeight: FontWeight.w700, fontSize: 13))),
        for (final c in unchanged)
          _row(context, Icons.pause_circle_outline_rounded, C.muted, c,
              Text('Unchanged · ${_s(c['status'])}', style: const TextStyle(color: C.muted, fontSize: 13)),
              note: 'No new evidence touched this item'),
      ]),
    );
  }

  /// Each row cites the span that actually evidences that item. The card used
  /// to show one chip for the whole change, pointing at a guessed "<doc>-P1" —
  /// a span id that often did not exist, and when it did, usually belonged to
  /// an unrelated paragraph.
  Widget _row(BuildContext context, IconData icon, Color color, Json entry, Widget trailing,
          {bool why = false, String? note}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text('${entry['label']}', style: const TextStyle(fontWeight: FontWeight.w700))),
            Flexible(child: Align(alignment: Alignment.centerRight, child: trailing)),
            if (entry['span_id'] != null) ...[
              const SizedBox(width: 8),
              SourceChip(spanId: entry['span_id'], docId: entry['doc_id']),
            ],
          ]),
          // On its own line: the status row is already as wide as it can get,
          // and a button squeezed into it pushed the chip off the card.
          if (why)
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: TextButton.icon(
                onPressed: () => showWhyChanged(context, entry),
                icon: const Icon(Icons.help_outline_rounded, size: 15),
                label: const Text('Why?'),
                style: TextButton.styleFrom(
                    foregroundColor: C.plum,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
              ),
            ),
          // An item nothing in this record touched still has a source of its
          // own, from whichever record first asked for it.
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(left: 30, top: 2),
              child: Row(children: [
                Expanded(
                  child: Text(note,
                      style: const TextStyle(color: C.muted, fontSize: 12.5, height: 1.3)),
                ),
                if (_origin(entry) != null) ...[
                  const SizedBox(width: 8),
                  SourceChip(
                      spanId: _origin(entry)!['span_id'], docId: _origin(entry)!['doc_id']),
                ],
              ]),
            ),
        ]),
      );

  /// Where an untouched item came from: the record that asked for it, or the
  /// receipt if that is all there ever was.
  static Json? _origin(Json entry) {
    for (final key in ['requested_by', 'receipt']) {
      final v = entry[key];
      if (v is Map && v['span_id'] != null) return Json.from(v);
    }
    return null;
  }
}

/// Both ends of one status change, side by side: the record that asked for
/// the item, and the record whose receipt settled it — with the graph path
/// that joins them. Everything comes from the change record the confirm
/// wrote, so this is the evidence the status was derived from, not a retelling.
Future<void> showWhyChanged(BuildContext context, Json entry) {
  final request = entry['requested_by'];
  final receipt = entry['receipt'];
  final path = (entry['path'] as List?) ?? const [];
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: C.paper,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      maxChildSize: 0.92,
      builder: (ctx, scroll) {
        final wide = MediaQuery.sizeOf(ctx).width >= 760;
        final left = _WhySide(
          eyebrow: 'Asked for in',
          empty: 'No confirmed record asks for this item.',
          tint: C.marigoldSoft,
          line: C.marigold,
          evidence: request,
        );
        final right = _WhySide(
          eyebrow: 'Receipt documented in',
          empty: 'No confirmed record documents a receipt yet.',
          tint: C.tealSoft,
          line: C.teal,
          evidence: receipt,
        );
        return ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(24, 12, 24, 32), children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(4)))),
          const SizedBox(height: 18),
          const Eyebrow('Why this changed', color: C.plum),
          const SizedBox(height: 6),
          Text('${entry['label']}', style: Theme.of(ctx).textTheme.titleLarge),
          if (entry['from'] != null && entry['to'] != null)
            Text('${_label(entry['from'])} → ${_label(entry['to'])}',
                style: const TextStyle(color: C.muted)),
          const SizedBox(height: 18),
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: left),
              const SizedBox(width: 20),
              Expanded(child: right),
            ])
          else ...[
            left,
            const SizedBox(height: 14),
            right,
          ],
          if (path.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Eyebrow('The path between them'),
            const SizedBox(height: 8),
            PathTrail(path),
          ],
          const SizedBox(height: 18),
          const Text('Status is derived by following these links to receipt evidence — '
              'it is never stored as a flag.',
              style: TextStyle(color: C.muted, fontSize: 12.5, height: 1.4)),
        ]);
      },
    ),
  );
}

String _label(Object? status) =>
    status == 'receipt_documented' ? 'Receipt documented' : 'Receipt not documented';

/// One side of the sheet: a record, the paragraph it says it in, and a chip
/// back to the original. Without evidence it says so rather than showing an
/// empty card.
class _WhySide extends StatelessWidget {
  final String eyebrow;
  final String empty;
  final Color tint;
  final Color line;
  final Object? evidence;
  const _WhySide({
    required this.eyebrow,
    required this.empty,
    required this.tint,
    required this.line,
    required this.evidence,
  });

  @override
  Widget build(BuildContext context) {
    final e = evidence is Map ? Json.from(evidence as Map) : null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: e == null ? C.card : tint,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: e == null ? C.line : line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Eyebrow(eyebrow, color: e == null ? C.muted : line),
        const SizedBox(height: 8),
        if (e == null)
          Text(empty, style: const TextStyle(color: C.muted, fontSize: 13.5, height: 1.4))
        else ...[
          Row(children: [
            Expanded(
              child: Text('${e['doc_id']} · ${e['doc_title']}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
            ),
            SourceChip(spanId: e['span_id'], docId: e['doc_id']),
          ]),
          Text('${e['date'] ?? ''}', style: const TextStyle(color: C.muted, fontSize: 12.5)),
          const SizedBox(height: 10),
          Text('“${e['text'] ?? ''}”',
              style: const TextStyle(fontSize: 14.5, height: 1.5, fontStyle: FontStyle.italic)),
        ],
      ]),
    );
  }
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
