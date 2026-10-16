import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Human review: original text on one side, suggested facts on the other.
/// Only checked facts are written to the graph on Confirm.
class ReviewScreen extends StatefulWidget {
  final Json draft;
  const ReviewScreen({super.key, required this.draft});
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final List<Json> spans = (widget.draft['spans'] as List).cast<Json>();
  late final List<Json> facts = (widget.draft['facts'] as List).map((f) => Map<String, dynamic>.from(f as Map)).toList();
  late final List<bool> keep = List.filled(facts.length, true, growable: true);
  bool _busy = false;
  String? _highlight;

  static const items = {'lab_report': 'Existing lab report', 'bp_log': 'Home BP log'};
  static const types = {'request': 'Request', 'receipt': 'Receipt', 'appointment': 'Appointment', 'absence_note': 'Note only'};

  void _addFact() {
    setState(() {
      facts.add({'type': 'receipt', 'item': 'lab_report', 'label': items['lab_report'], 'span_id': spans.first['id'], 'date': widget.draft['date'] ?? ''});
      keep.add(true);
    });
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      final chosen = [for (var i = 0; i < facts.length; i++) if (keep[i]) facts[i]];
      final res = await Api.confirm(widget.draft['id'], chosen);
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
    await Api.discard(widget.draft['id']);
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
              const Text('Uncheck anything wrong. Only checked facts are written to FalkorDB.', style: TextStyle(color: C.muted)),
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
                  label: Text(_busy ? 'Saving…' : 'Confirm ${keep.where((k) => k).length} fact(s)'),
                ),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _factCard(int i) {
    final f = facts[i];
    final type = f['type'] as String;
    final hasItem = type == 'request' || type == 'receipt';
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
                  onChanged: (v) => setState(() => f['type'] = v),
                ),
              ),
              SourceChip(spanId: f['span_id'], docId: widget.draft['id']),
            ]),
            if (hasItem)
              Padding(
                padding: const EdgeInsets.only(left: 48),
                child: DropdownButton<String>(
                  value: items.containsKey(f['item']) ? f['item'] : 'lab_report',
                  isExpanded: true,
                  items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) => setState(() {
                    f['item'] = v;
                    f['label'] = items[v];
                  }),
                ),
              ),
            if (type == 'appointment')
              Padding(padding: const EdgeInsets.only(left: 48), child: Text('${f['date']} · ${f['time']}')),
            if (type == 'receipt')
              Padding(padding: const EdgeInsets.only(left: 48, top: 4), child: Text('Receipt date: ${f['date'] ?? ''}', style: const TextStyle(color: C.muted))),
            if (type == 'absence_note')
              Padding(
                padding: const EdgeInsets.only(left: 48),
                child: Text('${f['label'] ?? ''} — kept as source text, no status change',
                    style: const TextStyle(color: C.muted, fontSize: 13)),
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
