import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Longitudinal timeline of confirmed records.
class RecordsScreen extends StatelessWidget {
  const RecordsScreen({super.key});

  static const _kind = {
    'REQUESTS': ('Request', C.marigold, C.marigoldSoft),
    'DOCUMENTS_RECEIPT': ('Receipt', C.teal, C.tealSoft),
    'CONFIRMS': ('Appointment', C.rose, C.roseSoft),
  };

  @override
  Widget build(BuildContext context) {
    return Loader<List<dynamic>>(
      load: Api.records,
      builder: (context, recs) {
        final docs = recs.cast<Json>().reversed.toList(); // newest first
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 28, 18, 100),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Health timeline', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Text('${docs.length} confirmed records · drafts awaiting review are not shown or used',
                      style: const TextStyle(color: C.muted)),
                  const SizedBox(height: 24),
                  if (docs.isEmpty) const Panel(child: Text('No records yet.')),
                  for (var i = 0; i < docs.length; i++) _TimelineEntry(doc: docs[i], last: i == docs.length - 1),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TimelineEntry extends StatelessWidget {
  final Json doc;
  final bool last;
  const _TimelineEntry({required this.doc, required this.last});

  @override
  Widget build(BuildContext context) {
    final kinds = (doc['kinds'] as List).cast<String>();
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 86,
          child: Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text(doc['date'] ?? '', style: const TextStyle(color: C.muted, fontWeight: FontWeight.w600, fontSize: 12.5)),
          ),
        ),
        Column(children: [
          const SizedBox(height: 20),
          Container(width: 12, height: 12, decoration: BoxDecoration(color: C.teal, shape: BoxShape.circle, border: Border.all(color: C.tealSoft, width: 3))),
          if (!last) Expanded(child: Container(width: 2, color: C.line)),
        ]),
        const SizedBox(width: 16),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => showSource(context, doc['id'], ''),
              child: Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(doc['id'], style: const TextStyle(fontFamily: 'monospace', color: C.plum, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(doc['title'] ?? '', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                    const Icon(Icons.open_in_new_rounded, size: 16, color: C.muted),
                  ]),
                  const SizedBox(height: 8),
                  Text(doc['text'] ?? '', maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, height: 1.45)),
                  if (kinds.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, children: [
                      for (final k in kinds)
                        if (RecordsScreen._kind.containsKey(k))
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(color: RecordsScreen._kind[k]!.$3, borderRadius: BorderRadius.circular(99)),
                            child: Text(RecordsScreen._kind[k]!.$1,
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: RecordsScreen._kind[k]!.$2)),
                          ),
                    ]),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
