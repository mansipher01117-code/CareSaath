import 'package:flutter/material.dart';

import '../api.dart';
import '../profiles.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Human review: original text on one side, suggested facts on the other.
/// Items are free text — rename or fix anything before it becomes evidence.
/// Only checked facts are written to the graph on Confirm.
class ReviewScreen extends StatefulWidget {
  final Json draft;
  const ReviewScreen({super.key, required this.draft});
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final List<Json> spans = (widget.draft['spans'] as List).cast<Json>();
  late final List<Json> facts =
      (widget.draft['facts'] as List).map((f) => Map<String, dynamic>.from(f as Map)).toList();
  late final List<bool> keep = List.filled(facts.length, true, growable: true);
  late final List<TextEditingController> labels = [
    for (final f in facts) TextEditingController(text: '${f['label'] ?? ''}')
  ];
  /// Item name parked per fact while its type is not an item-bearing one.
  final Map<int, String> _itemNames = {};
  bool _busy = false;
  String? _highlight;

  static const types = {
    'request': 'Request',
    'receipt': 'Receipt',
    'appointment': 'Appointment',
    'absence_note': 'Note only',
  };

  /// Types whose fact is a tracked follow-up item, i.e. carries an item name.
  static bool _hasItem(String? type) => type == 'request' || type == 'receipt';

  /// An appointment is only real once it has both a date and a time; the
  /// extractor supplies them together, and nothing else can invent them.
  static bool _appointmentReady(Json f) =>
      '${f['date'] ?? ''}'.trim().isNotEmpty && '${f['time'] ?? ''}'.trim().isNotEmpty;

  /// Controllers for the date, time, year and receipt-date fields, created on
  /// demand so a fact that has no such field costs nothing.
  final Map<String, TextEditingController> _dates = {};

  TextEditingController _dateField(int i, String key) =>
      _dates.putIfAbsent('$i.$key', () {
        final c = TextEditingController(text: '${facts[i][key] ?? ''}');
        final suggested = c.text;
        c.addListener(() => setState(() {
              facts[i][key] = c.text.trim();
              // A receipt date the reviewer typed is neither the paragraph's
              // nor the document's, so it stops being labelled a fallback.
              if (key == 'date' && facts[i]['type'] == 'receipt' && c.text != suggested) {
                facts[i]['date_source'] = 'edited';
              }
            }));
        return c;
      });

  /// Drop the controllers for one fact, so a type switch does not leave the
  /// previous type's date sitting in a field the reviewer can no longer see.
  void _clearDateFields(int i) {
    for (final key in ['date', 'time', 'year']) {
      _dates.remove('$i.$key')?.dispose();
    }
  }

  /// Why this fact cannot be written yet, or null when it can be.
  String? _blocker(int i) {
    final f = facts[i];
    if (_hasItem(f['type'] as String?) && labels[i].text.trim().isEmpty) {
      return 'Name this item before it can be saved.';
    }
    if (f['type'] == 'appointment' && !_appointmentReady(f)) {
      return 'No date and time were read from this paragraph, so it cannot be saved as an '
          'appointment.';
    }
    return null;
  }

  /// Switching a fact's type must not carry the old type's fields across: a
  /// label like "Appointment" is not an item name, and a request has no time,
  /// so inheriting them silently writes junk into the graph.
  void _changeType(int i, String? newType) {
    if (newType == null) return;
    final f = facts[i];
    final oldType = f['type'] as String?;
    final next = <String, dynamic>{'type': newType, 'span_id': f['span_id']};

    // An item name is only meaningful between the two item-bearing types, so
    // it is parked rather than inherited — a detour through another type and
    // back keeps what the reviewer typed, without ever adopting that type's
    // own label as an item name.
    if (_hasItem(oldType)) _itemNames[i] = labels[i].text;
    if (_hasItem(newType)) {
      if (!_hasItem(oldType)) labels[i].text = _itemNames[i] ?? '';
    } else {
      next['label'] = _hasItem(oldType) ? labels[i].text.trim() : f['label'];
    }
    if (newType == 'receipt') {
      // Nothing was read from the paragraph for a fact the reviewer just
      // turned into a receipt, so its date starts as the document's.
      next['date'] = widget.draft['date'] ?? '';
      next['date_source'] = 'document';
    }
    if (newType == 'appointment' && oldType == 'appointment') {
      next['date'] = f['date'];
      next['time'] = f['time'];
      next['year'] = f['year'];
    }
    if (newType == 'absence_note' && f['items'] != null) next['items'] = f['items'];

    _clearDateFields(i);
    setState(() => facts[i] = next);
  }

  @override
  void dispose() {
    for (final c in labels) {
      c.dispose();
    }
    for (final c in _dates.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _addFact() {
    setState(() {
      facts.add({'type': 'request', 'span_id': spans.first['id']});
      labels.add(TextEditingController());
      keep.add(true);
    });
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      final chosen = <Json>[];
      for (var i = 0; i < facts.length; i++) {
        if (!keep[i] || _blocker(i) != null) continue;
        final f = Map<String, dynamic>.from(facts[i]);
        final label = labels[i].text.trim();
        if (label.isNotEmpty) f['label'] = label;
        chosen.add(f);
      }
      final res = await Api.confirm(profiles.selectedId!, widget.draft['id'], chosen);
      refreshAll();
      if (!mounted) return;
      await _showResult(res['change'] as Json? ?? {});
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discard() async {
    await Api.discard(profiles.selectedId!, widget.draft['id']);
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _showResult(Json change) {
    String s(String v) => v == 'receipt_documented' ? 'documented' : 'not documented';
    final changed = (change['changed'] as List? ?? []).cast<Json>();
    final unchanged = (change['unchanged'] as List? ?? []).cast<Json>();
    final added = (change['added'] as List? ?? []).cast<Json>();
    return showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: C.paper,
        title: const Text('Saved to the graph'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (changed.isEmpty && added.isEmpty) const Text('No preparation item changed.'),
          for (final c in changed) Text('✔ ${c['label']}: ${s(c['from'])} → ${s(c['to'])}', style: const TextStyle(color: C.teal, fontWeight: FontWeight.w700)),
          for (final c in added) Text('＋ ${c['label']} now tracked', style: const TextStyle(color: C.plum, fontWeight: FontWeight.w700)),
          for (final c in unchanged) Text('• ${c['label']}: unchanged', style: const TextStyle(color: C.muted)),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
      ),
    );
  }

  int get _keptCount {
    var n = 0;
    for (var i = 0; i < facts.length; i++) {
      if (keep[i] && _blocker(i) == null) n++;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final original = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Eyebrow('Original text'),
      const SizedBox(height: 10),
      for (final s in spans)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _highlight == s['id'] ? C.marigoldSoft : C.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _highlight == s['id'] ? C.marigold : C.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s['id'], style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: C.plum, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(s['text'], style: const TextStyle(fontSize: 15, height: 1.5)),
          ]),
        ),
    ]);

    final suggested = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Eyebrow('Suggested facts'),
        const Spacer(),
        Text('extractor: ${widget.draft['extractor'] ?? ''}', style: const TextStyle(fontSize: 11, color: C.muted)),
      ]),
      const SizedBox(height: 10),
      if (facts.isEmpty)
        const Panel(child: Text('Nothing extracted. Add a fact manually, or confirm to keep the record as context only.')),
      for (var i = 0; i < facts.length; i++) _factCard(i),
      TextButton.icon(onPressed: _addFact, icon: const Icon(Icons.add_rounded), label: const Text('Add fact manually')),
    ]);

    return Scaffold(
      appBar: AppBar(title: Text('Review ${widget.draft['id']}')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Check before it becomes evidence', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              const Text(
                'Rename an item, point it at a different paragraph, or uncheck it. '
                'Only checked facts are written to FalkorDB — and two items with the same name are the same item.',
                style: TextStyle(color: C.muted, height: 1.5),
              ),
              // A transcription is a model reading a picture, not the record
              // itself, so the text on the left is worth checking against the
              // original before any of it becomes evidence.
              if (widget.draft['read_by'] == 'gemini')
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Panel(
                    color: C.marigoldSoft,
                    border: C.marigold,
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      const Icon(Icons.auto_awesome_rounded, size: 16, color: C.marigold),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            'This text was transcribed from '
                            '${widget.draft['filename'] ?? 'an upload'} by Gemini. '
                            'Read it against the original before confirming.',
                            style: const TextStyle(
                                color: C.marigold, fontSize: 13, height: 1.4)),
                      ),
                    ]),
                  ),
                ),
              const SizedBox(height: 22),
              wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: original),
                      const SizedBox(width: 24),
                      Expanded(child: suggested),
                    ])
                  : Column(children: [original, const SizedBox(height: 20), suggested]),
              const SizedBox(height: 28),
              Row(children: [
                OutlinedButton(onPressed: _busy ? null : _discard, child: const Text('Discard draft')),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _busy ? null : _confirm,
                  icon: const Icon(Icons.verified_outlined),
                  label: Text(_busy ? 'Saving…' : 'Confirm $_keptCount fact(s)'),
                ),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _dateInput(int i, String key, String label, String hint) => TextField(
        controller: _dateField(i, key),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 12),
        ),
        style: const TextStyle(fontSize: 14),
      );

  Widget _factCard(int i) {
    final f = facts[i];
    final type = f['type'] as String;
    final hasItem = _hasItem(type);
    final blocker = _blocker(i);
    return MouseRegion(
      onEnter: (_) => setState(() => _highlight = f['span_id']),
      onExit: (_) => setState(() => _highlight = null),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Panel(
          padding: const EdgeInsets.all(14),
          color: keep[i] ? C.card : C.paper,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Checkbox(value: keep[i], activeColor: C.teal, onChanged: (v) => setState(() => keep[i] = v ?? false)),
              Expanded(
                child: DropdownButton<String>(
                  value: types.containsKey(type) ? type : 'request',
                  isExpanded: true,
                  underline: const SizedBox(),
                  items: [for (final e in types.entries) DropdownMenuItem(value: e.key, child: Text(e.value, style: const TextStyle(fontWeight: FontWeight.w700)))],
                  onChanged: (v) => _changeType(i, v),
                ),
              ),
              SourceChip(spanId: f['span_id'], docId: widget.draft['id']),
            ]),
            if (hasItem)
              Padding(
                padding: const EdgeInsets.only(left: 48, top: 4, bottom: 4),
                child: TextField(
                  controller: labels[i],
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Item',
                    hintText: 'e.g. Home BP log',
                    helperText: 'Rename it to whatever you call it at home.',
                  ),
                ),
              ),
            if (type == 'appointment')
              Padding(
                padding: const EdgeInsets.only(left: 48, top: 4, bottom: 4),
                child: Column(children: [
                  Row(children: [
                    Expanded(child: _dateInput(i, 'date', 'Date', 'e.g. 20 October')),
                    const SizedBox(width: 10),
                    Expanded(child: _dateInput(i, 'time', 'Time', 'e.g. 10:00 AM')),
                  ]),
                  const SizedBox(height: 6),
                  Row(children: [
                    SizedBox(width: 92, child: _dateInput(i, 'year', 'Year', 'YYYY')),
                    const SizedBox(width: 10),
                    // A record that never said the year must not have one
                    // invented for it, so an empty field is a real answer.
                    Expanded(
                      child: Text(
                          '${f['year'] ?? ''}'.trim().isEmpty
                              ? 'Year unknown — leave blank unless the record says it.'
                              : 'Year taken from the record.',
                          style: const TextStyle(color: C.muted, fontSize: 12, height: 1.3)),
                    ),
                  ]),
                ]),
              ),
            if (type == 'receipt')
              Padding(
                padding: const EdgeInsets.only(left: 48, top: 4, bottom: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _dateInput(i, 'date', 'Received on', 'YYYY-MM-DD, or blank if unknown'),
                  const SizedBox(height: 4),
                  // The day the item was received is not the day the note was
                  // filed, so the card says which of the two this is.
                  Text(
                      f['date_source'] == 'document'
                          ? 'This paragraph gives no date — the document date is standing in. '
                              'Correct it if you know the day.'
                          : f['date_source'] == 'edited'
                              ? 'Your own date, not the record’s.'
                              : 'Read from this paragraph: ${prettyDate('${f['date'] ?? ''}')}.',
                      style: const TextStyle(color: C.muted, fontSize: 12, height: 1.3)),
                ]),
              ),
            if (type == 'absence_note')
              Padding(
                padding: const EdgeInsets.only(left: 48),
                child: Text('${f['label'] ?? ''} — kept as source text, no status change',
                    style: const TextStyle(color: C.muted, fontSize: 13)),
              ),
            if (keep[i] && blocker != null)
              Padding(
                padding: const EdgeInsets.only(left: 48, top: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.info_outline_rounded, size: 15, color: C.rose),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(blocker,
                        style: const TextStyle(color: C.rose, fontSize: 13, height: 1.4)),
                  ),
                ]),
              ),
            if (spans.length > 1)
              Padding(
                padding: const EdgeInsets.only(left: 48),
                child: DropdownButton<String>(
                  value: f['span_id'],
                  isExpanded: true,
                  items: [for (final s in spans) DropdownMenuItem(value: s['id'] as String, child: Text('Cites ${s['id']}', style: const TextStyle(fontSize: 13)))],
                  onChanged: (v) => setState(() => f['span_id'] = v),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
