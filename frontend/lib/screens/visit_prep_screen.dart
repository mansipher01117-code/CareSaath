import 'package:flutter/material.dart';

import '../api.dart';
import '../printing.dart';
import '../profiles.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// A sheet to take to the appointment: when it is, what still has to be asked
/// about, and what the records already document — every line with the span it
/// came from and the words that say it, so a question can be settled by
/// pointing at the quote rather than by remembering.
///
/// Nothing is summarised into a new claim here. The sheet is the preparation
/// view in print order.
class VisitPrepScreen extends StatelessWidget {
  const VisitPrepScreen({super.key});

  Future<List<Json>> _load(String pid) =>
      Future.wait([Api.person(pid), Api.preparation(pid)]);

  @override
  Widget build(BuildContext context) {
    final pid = profiles.selectedId;
    if (pid == null) return const SizedBox.shrink();
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Visit preparation'),
        actions: [
          if (canPrint)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: printPage,
                icon: const Icon(Icons.print_outlined, size: 18),
                label: const Text('Print / Save as PDF'),
              ),
            ),
        ],
      ),
      body: Loader<List<Json>>(
        load: () => _load(pid),
        builder: (context, d) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: VisitPrepSheet(
                person: d[0],
                items: (d[1]['items'] as List).cast<Json>(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The printable body, taking the data it shows so it can be rendered — and
/// checked — without a backend.
class VisitPrepSheet extends StatelessWidget {
  final Json person;
  final List<Json> items;
  const VisitPrepSheet({super.key, required this.person, required this.items});

  static const footer = 'Generated from confirmed records only. Not medical advice.';

  /// The appointment worth printing: the next one still ahead, or the only one
  /// on record. Null when no confirmed record names one.
  Json? get _appointment {
    final appts = (person['appointments'] as List? ?? const []).cast<Json>();
    if (appts.isEmpty) return null;
    return appts.firstWhere((a) => a['upcoming'] == true, orElse: () => appts.first);
  }

  @override
  Widget build(BuildContext context) {
    final pending = items.where((i) => i['status'] != 'receipt_documented').toList();
    final documented = items.where((i) => i['status'] == 'receipt_documented').toList();
    final appt = _appointment;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${person['name'] ?? ''}', style: Theme.of(context).textTheme.headlineLarge),
      Text(
          [
            person['relation'] ?? '',
            if ('${person['caregiver'] ?? ''}'.isNotEmpty) 'caregiver ${person['caregiver']}',
          ].where((s) => '$s'.isNotEmpty).join(' · '),
          style: const TextStyle(color: C.muted)),
      const Divider(height: 28),

      const Eyebrow('Appointment'),
      const SizedBox(height: 8),
      if (appt == null)
        const Text('No confirmed record names an appointment.',
            style: TextStyle(color: C.muted, fontSize: 14.5))
      else ...[
        Text('${_when(appt)} · ${appt['time']}',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        if ('${appt['year'] ?? ''}'.trim().isEmpty)
          const Text('Year not stated in the record',
              style: TextStyle(color: C.muted, fontSize: 12.5, fontStyle: FontStyle.italic)),
        for (final s in (appt['sources'] as List? ?? const []).cast<Json>().take(1))
          _SourceLine(source: s),
      ],
      const SizedBox(height: 26),

      _Section(
        eyebrow: 'Still to clarify',
        empty: 'Nothing is waiting on a receipt.',
        children: [
          for (final i in pending)
            _ItemBlock(
              label: '${i['label']}',
              // The request is what makes this worth asking about, so it is
              // the quote to have in hand at the desk.
              source: _first(i['requested_by']),
              note: 'No receipt in the confirmed records yet',
            ),
        ],
      ),
      const SizedBox(height: 26),

      _Section(
        eyebrow: 'Already documented',
        empty: 'No receipt is documented yet.',
        children: [
          for (final i in documented)
            _ItemBlock(
              label: '${i['label']}',
              source: _first(i['receipts']),
              note: 'Receipt recorded ${_date(_first(i['receipts']))}'.trim(),
            ),
        ],
      ),

      const Divider(height: 34),
      const Text(footer, style: TextStyle(color: C.muted, fontSize: 12.5, height: 1.5)),
    ]);
  }

  /// "20 October 2026", or just "20 October" when the record never gave a
  /// year — joined rather than interpolated, so a missing year leaves no gap.
  static String _when(Json appt) => [
        '${appt['date'] ?? ''}'.trim(),
        '${appt['year'] ?? ''}'.trim(),
      ].where((s) => s.isNotEmpty).join(' ');

  static Json? _first(Object? list) {
    if (list is List && list.isNotEmpty && list.first is Map) return Json.from(list.first as Map);
    return null;
  }

  static String _date(Json? source) => '${source?['date'] ?? ''}';
}

class _Section extends StatelessWidget {
  final String eyebrow;
  final String empty;
  final List<Widget> children;
  const _Section({required this.eyebrow, required this.empty, required this.children});

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Eyebrow(eyebrow),
          const SizedBox(width: 8),
          Text('${children.length}', style: const TextStyle(color: C.muted, fontSize: 12)),
        ]),
        const SizedBox(height: 10),
        if (children.isEmpty)
          Text(empty, style: const TextStyle(color: C.muted, fontSize: 14.5))
        else
          ...children,
      ]);
}

class _ItemBlock extends StatelessWidget {
  final String label;
  final Json? source;
  final String note;
  const _ItemBlock({required this.label, required this.source, required this.note});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('☐  ', style: TextStyle(fontSize: 16)),
            Expanded(
              child: Text(label,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            Text(note, style: const TextStyle(color: C.muted, fontSize: 12.5)),
          ]),
          if (source != null) _SourceLine(source: source!),
        ]),
      );
}

/// One line of provenance: the span id, and enough of its words to recognise
/// the paragraph in the original.
class _SourceLine extends StatelessWidget {
  final Json source;
  const _SourceLine({required this.source});

  @override
  Widget build(BuildContext context) {
    final quote = '${source['text'] ?? ''}'.trim();
    final short = quote.length > 140 ? '${quote.substring(0, 140).trimRight()}…' : quote;
    return Padding(
      padding: const EdgeInsets.only(left: 26, top: 4),
      child: Text(
          [
            '${source['span_id'] ?? ''}',
            if ('${source['doc_title'] ?? ''}'.isNotEmpty) '${source['doc_title']}',
            if ('${source['date'] ?? ''}'.isNotEmpty) '${source['date']}',
          ].where((s) => s.isNotEmpty).join(' · ') +
              (short.isEmpty ? '' : '  “$short”'),
          style: const TextStyle(color: C.muted, fontSize: 12.5, height: 1.5)),
    );
  }
}
