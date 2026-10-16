import 'package:flutter/material.dart';

import '../api.dart';
import '../profiles.dart';
import '../theme.dart';

/// White rounded panel used everywhere.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final Color border;
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(20), this.color = C.card, this.border = C.line});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border),
        ),
        child: child,
      );
}

class Eyebrow extends StatelessWidget {
  final String text;
  final Color color;
  const Eyebrow(this.text, {super.key, this.color = C.muted});
  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: TextStyle(fontSize: 11.5, letterSpacing: 1.4, fontWeight: FontWeight.w700, color: color),
      );
}

/// "Receipt documented" / "Receipt not documented" pill.
class StatusPill extends StatelessWidget {
  final String status;
  const StatusPill(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final ok = status == 'receipt_documented';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: ok ? C.tealSoft : C.marigoldSoft,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ok ? Icons.check_circle_rounded : Icons.help_outline_rounded, size: 15, color: ok ? C.teal : C.marigold),
        const SizedBox(width: 5),
        Text(
          ok ? 'Receipt documented' : 'Receipt not documented',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: ok ? C.teal : C.marigold),
        ),
      ]),
    );
  }
}

/// Small tappable chip that opens the original evidence.
class SourceChip extends StatelessWidget {
  final String spanId;
  final String docId;
  const SourceChip({super.key, required this.spanId, required this.docId});

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => showSource(context, docId, spanId),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: C.plumSoft,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.format_quote_rounded, size: 14, color: C.plum),
            const SizedBox(width: 4),
            Text(spanId, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: C.plum, fontFamily: 'monospace')),
          ]),
        ),
      );
}

/// The graph path behind an answer, e.g. Person → Document → Span → FollowUp.
class PathTrail extends StatelessWidget {
  final List<dynamic> path;
  const PathTrail(this.path, {super.key});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < path.length; i++) {
      final s = path[i].toString();
      final type = s.split(':').first;
      children.add(Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: nodeColor(type).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(s, style: TextStyle(fontSize: 11.5, color: nodeColor(type), fontWeight: FontWeight.w600)),
      ));
      if (i < path.length - 1) {
        children.add(const Icon(Icons.arrow_right_alt_rounded, size: 16, color: C.muted));
      }
    }
    return Wrap(spacing: 4, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: children);
  }
}

Color nodeColor(String type) {
  switch (type) {
    case 'Person':
      return C.ink;
    case 'Document':
      return C.plum;
    case 'Span':
    case 'EvidenceSpan':
      return const Color(0xFF7A6A4F);
    case 'FollowUp':
      return C.marigold;
    case 'Receipt':
      return C.teal;
    case 'Appointment':
      return C.rose;
    default:
      return C.muted;
  }
}

/// Bottom sheet showing the original record with the cited paragraph
/// highlighted. Always reads from the profile currently selected.
Future<void> showSource(BuildContext context, String docId, String spanId) {
  final pid = profiles.selectedId;
  if (pid == null) return Future.value();
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: C.paper,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (ctx, scroll) => FutureBuilder<Json>(
        future: Api.record(pid, docId),
        builder: (ctx, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final d = snap.data!;
          final spans = (d['spans'] as List).cast<Map<String, dynamic>>();
          return ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(24, 12, 24, 32), children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(4)))),
            const SizedBox(height: 18),
            const Eyebrow('Original source'),
            const SizedBox(height: 6),
            Text('${d['id']} · ${d['title']}', style: Theme.of(ctx).textTheme.titleLarge),
            Text(d['date'] ?? '', style: const TextStyle(color: C.muted)),
            const SizedBox(height: 18),
            for (final s in spans) ...[
              Container(
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: s['id'] == spanId ? C.marigoldSoft : C.card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: s['id'] == spanId ? C.marigold : C.line, width: s['id'] == spanId ? 1.6 : 1),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${s['id']} · paragraph ${s['index']}',
                      style: const TextStyle(fontSize: 11.5, color: C.muted, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(s['text'] ?? '', style: const TextStyle(fontSize: 15, height: 1.5)),
                ]),
              ),
            ],
          ]);
        },
      ),
    ),
  );
}

/// Loads data and rebuilds whenever [dataVersion] changes.
class Loader<T> extends StatelessWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T) builder;
  const Loader({super.key, required this.load, required this.builder});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: dataVersion,
        builder: (context, v, _) => FutureBuilder<T>(
          key: ValueKey(v),
          future: load(),
          builder: (context, snap) {
            if (snap.hasError) return ErrorState(message: '${snap.error}');
            if (!snap.hasData) {
              return const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()));
            }
            return builder(context, snap.data as T);
          },
        ),
      );
}

class ErrorState extends StatelessWidget {
  final String message;
  const ErrorState({super.key, required this.message});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Panel(
          color: C.roseSoft,
          border: C.rose.withValues(alpha: 0.3),
          child: Row(children: [
            const Icon(Icons.cloud_off_rounded, color: C.rose),
            const SizedBox(width: 12),
            Expanded(child: Text(message, style: const TextStyle(color: C.rose, fontWeight: FontWeight.w600))),
            TextButton(onPressed: refreshAll, child: const Text('Retry')),
          ]),
        ),
      );
}

/// Shown wherever there is genuinely nothing yet — no records, no follow-ups,
/// no appointment, no profiles.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
        child: Column(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: C.paper, borderRadius: BorderRadius.circular(16)),
            child: Icon(icon, color: C.muted, size: 24),
          ),
          const SizedBox(height: 14),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(body,
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.muted, fontSize: 13.5, height: 1.5)),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ]),
      );
}
