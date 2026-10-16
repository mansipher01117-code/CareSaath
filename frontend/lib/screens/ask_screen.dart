import 'package:flutter/material.dart';

import '../api.dart';
import '../profiles.dart';
import '../theme.dart';
import '../widgets/common.dart';

class AskScreen extends StatefulWidget {
  const AskScreen({super.key});
  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  final _q = TextEditingController();
  final _scroll = ScrollController();
  final List<Json> _turns = [];
  String _lang = 'en';
  bool _busy = false;

  static const _langs = {'en': 'English', 'hi': 'हिंदी / Hinglish'};
  static const _suggest = {
    'en': ['What should I clarify before the appointment?', 'What changed after the latest record?', 'When is the appointment?'],
    'hi': ['Appointment se pehle kya clarify karna hai?', 'Latest record se kya badla?', 'Appointment kab hai?'],
  };

  Future<void> _ask(String q) async {
    if (q.trim().isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _turns.add({'role': 'user', 'text': q.trim()});
    });
    _q.clear();
    try {
      final res = await Api.ask(profiles.selectedId!, q.trim(), _lang);
      setState(() => _turns.add({'role': 'agent', ...res}));
    } catch (e) {
      setState(() => _turns.add({'role': 'error', 'text': '$e'}));
    } finally {
      setState(() => _busy = false);
      await Future.delayed(const Duration(milliseconds: 50));
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 8),
            child: Row(children: [
              Expanded(
                child: Text('Ask about ${profiles.selectedName}’s records',
                    style: Theme.of(context).textTheme.headlineMedium),
              ),
              SegmentedButton<String>(
                segments: [for (final e in _langs.entries) ButtonSegment(value: e.key, label: Text(e.value, style: const TextStyle(fontSize: 12)))],
                selected: {_lang},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _lang = s.first),
              ),
            ]),
          ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
              children: [
                if (_turns.isEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                      'Answers come only from ${profiles.selectedName}’s confirmed records in the graph, '
                      'and every claim shows the record it came from.',
                      style: const TextStyle(color: C.muted)),
                  const SizedBox(height: 16),
                ],
                for (final t in _turns) _bubble(t),
                if (_busy) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator(color: C.teal)),
              ],
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 18), children: [
              for (final s in _suggest[_lang]!)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    label: Text(s),
                    backgroundColor: C.card,
                    side: const BorderSide(color: C.line),
                    onPressed: () => _ask(s),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _q,
                  onSubmitted: _ask,
                  decoration: InputDecoration(
                    hintText: _lang == 'hi' ? 'Apna sawaal likhein…' : 'Ask a question…',
                    prefixIcon: const Icon(Icons.chat_bubble_outline_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                onPressed: _busy ? null : () => _ask(_q.text),
                style: IconButton.styleFrom(backgroundColor: C.teal, padding: const EdgeInsets.all(14)),
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _bubble(Json t) {
    if (t['role'] == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 60),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            color: C.ink,
            borderRadius: BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomLeft: Radius.circular(18), bottomRight: Radius.circular(4)),
          ),
          child: Text(t['text'], style: const TextStyle(color: Colors.white, fontSize: 15)),
        ),
      );
    }
    if (t['role'] == 'error') {
      return Padding(padding: const EdgeInsets.only(bottom: 12), child: ErrorState(message: t['text']));
    }
    final lines = (t['answer'] as List).cast<Json>();
    final trace = (t['trace'] as List).cast<Json>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14, right: 40),
      child: Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.favorite_rounded, color: C.teal, size: 16),
            SizedBox(width: 6),
            Eyebrow('CareSaath', color: C.teal),
          ]),
          const SizedBox(height: 10),
          for (final l in lines) AnswerClaim(l),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: const Text('How the agent got here', style: TextStyle(fontSize: 13, color: C.muted, fontWeight: FontWeight.w600)),
              children: [
                for (var i = 0; i < trace.length; i++)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('${i + 1}. ${trace[i]['tool']}()  →  ${trace[i]['returned']}',
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, color: C.plum)),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('intent: ${t['intent']}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: C.muted)),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// One claim of an answer, with the evidence for that claim under it. A claim
/// that rests on the absence of a record ("receipt is not documented") has no
/// sources, and shows none rather than borrowing the line above's.
class AnswerClaim extends StatelessWidget {
  final Json line;
  const AnswerClaim(this.line, {super.key});

  @override
  Widget build(BuildContext context) {
    final sources = ((line['sources'] ?? const []) as List).cast<Json>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(line['text'], style: const TextStyle(fontSize: 15, height: 1.5)),
        for (final s in sources)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SourceChip(spanId: s['span_id'], docId: s['doc_id']),
              const SizedBox(width: 10),
              Expanded(
                child: Text('“${s['text']}”', maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: C.muted, fontSize: 13, fontStyle: FontStyle.italic)),
              ),
            ]),
          ),
      ]),
    );
  }
}
