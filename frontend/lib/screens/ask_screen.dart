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
  /// Starting points, not a menu: any question in your own words is answered.
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
                      'Ask anything in your own words. Answers come only from '
                      '${profiles.selectedName}’s confirmed records in the graph, with a source '
                      'for every claim.',
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 14, right: 40),
      child: AnswerCard(answer: t),
    );
  }
}

/// Which engine wrote the answer: the Gemini agent, or the deterministic rules
/// fallback. Worth showing — the two are grounded the same way, but only one of
/// them phrases things itself.
class EngineBadge extends StatelessWidget {
  final String engine;
  const EngineBadge(this.engine, {super.key});

  @override
  Widget build(BuildContext context) {
    final ai = engine == 'llm';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: ai ? C.tealSoft : C.paper,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ai ? C.teal : C.line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ai ? Icons.auto_awesome_rounded : Icons.rule_rounded,
            size: 11, color: ai ? C.teal : C.muted),
        const SizedBox(width: 4),
        Text(ai ? 'AI' : 'Rules',
            style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
                color: ai ? C.teal : C.muted)),
      ]),
    );
  }
}

/// One agent answer: its claims, the evidence under each claim, and the tool
/// calls behind it. A claim with no chips is one the graph did not evidence —
/// the backend drops any citation its tools did not return, so an empty row
/// here is the honest outcome, not a rendering gap.
class AnswerCard extends StatelessWidget {
  final Json answer;
  const AnswerCard({super.key, required this.answer});

  List<Json> get _claims {
    final claims = answer['claims'];
    if (claims is List && claims.isNotEmpty) return claims.cast<Json>();
    // Older backend, or the contract without per-claim sources: fall back to the
    // flat lines with the whole source list hanging off the last one.
    final lines = (answer['answer'] as List? ?? const []).cast<String>();
    final sources = (answer['sources'] as List? ?? const []).cast<Json>();
    return [
      for (var i = 0; i < lines.length; i++)
        {'text': lines[i], 'sources': i == lines.length - 1 ? sources : const []},
    ];
  }

  static String _args(Object? args) {
    if (args is! Map || args.isEmpty) return '';
    return args.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final trace = (answer['trace'] as List? ?? const []).cast<Json>();
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.favorite_rounded, color: C.teal, size: 16),
          const SizedBox(width: 6),
          const Eyebrow('CareSaath', color: C.teal),
          const Spacer(),
          EngineBadge((answer['engine'] as String?) ?? 'rules'),
        ]),
        const SizedBox(height: 10),
        for (final claim in _claims) ...[
          Text(claim['text'] as String? ?? '',
              style: const TextStyle(fontSize: 15, height: 1.5)),
          for (final s in (claim['sources'] as List? ?? const []).cast<Json>())
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SourceChip(spanId: s['span_id'], docId: s['doc_id']),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('“${s['text']}”',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: C.muted, fontSize: 13, fontStyle: FontStyle.italic)),
                ),
              ]),
            ),
          const SizedBox(height: 10),
        ],
        // The Panel paints its own background, which would otherwise swallow the
        // tile's ink splash — so the tile gets a Material of its own.
        Material(
          color: Colors.transparent,
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: const Text('How the agent got here',
                  style: TextStyle(fontSize: 13, color: C.muted, fontWeight: FontWeight.w600)),
              children: [
                for (var i = 0; i < trace.length; i++)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                          '${i + 1}. ${trace[i]['tool']}(${_args(trace[i]['args'])})'
                          '  →  ${trace[i]['returned']}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12.5, color: C.plum)),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('intent: ${answer['intent']}   ·   engine: ${answer['engine']}',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12, color: C.muted)),
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
