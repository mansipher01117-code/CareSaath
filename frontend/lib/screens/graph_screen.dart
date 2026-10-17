import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../profiles.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Live view of the selected person's own subgraph in FalkorDB, laid out in
/// columns by node type.
class GraphScreen extends StatelessWidget {
  const GraphScreen({super.key});

  static const _cols = {'Person': 0, 'Document': 1, 'EvidenceSpan': 2, 'FollowUp': 3, 'Appointment': 3, 'Receipt': 4};
  static const _w = 236.0, _h = 46.0, _gapX = 64.0, _gapY = 22.0, _pad = 40.0;

  /// "source→target" for one edge, so a highlighted edge can be looked up
  /// without comparing lists.
  static String edgeKey(Object? a, Object? b) => '$a→$b';

  @override
  Widget build(BuildContext context) {
    final pid = profiles.selectedId;
    if (pid == null) return const SizedBox.shrink();
    // The slice of the graph the last Ask answer rests on, when the reader
    // asked to see it.
    return ValueListenableBuilder<Json?>(
      valueListenable: graphHighlight,
      builder: (context, highlight, _) => _build(context, pid, highlight),
    );
  }

  Widget _build(BuildContext context, String pid, Json? highlight) {
    final onPath = {
      for (final id in (highlight?['nodes'] as List? ?? const [])) '$id',
    };
    final pathEdges = {
      for (final e in (highlight?['edges'] as List? ?? const []))
        if (e is List && e.length >= 2) edgeKey(e[0], e[1]),
    };
    return Loader<Json>(
      load: () => Api.graph(pid),
      builder: (context, g) {
        final nodes = (g['nodes'] as List).cast<Json>();
        final edges = (g['edges'] as List).cast<Json>();

        final byCol = <int, List<Json>>{};
        for (final n in nodes) {
          byCol.putIfAbsent(_cols[n['type']] ?? 5, () => []).add(n);
        }
        final row = graphRows(byCol, edges);
        final rows = row.values.fold<int>(0, math.max) + 1;
        final height = _pad * 2 + rows * (_h + _gapY);
        const width = _pad * 2 + 6 * (_w + _gapX);

        final pos = <String, Offset>{};
        byCol.forEach((col, list) {
          for (final n in list) {
            pos[n['id']] = Offset(_pad + col * (_w + _gapX), _pad + row['${n['id']}']! * (_h + _gapY));
          }
        });

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${profiles.selectedName}’s context graph',
                  style: Theme.of(context).textTheme.headlineMedium),
              Text('${nodes.length} nodes · ${edges.length} relationships · live from person_$pid. '
                  'Tap a document or span to open the source.',
                  style: const TextStyle(color: C.muted)),
              if (onPath.isNotEmpty) ...[
                const SizedBox(height: 10),
                // Everything off the path is dimmed rather than removed: the
                // reader is being shown where one answer sits in the whole
                // graph, not handed a smaller graph.
                Row(children: [
                  const Icon(Icons.auto_awesome_rounded, size: 15, color: C.plum),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        '${onPath.length} node(s) behind the last answer are highlighted; '
                        'the rest of the graph is dimmed.',
                        style: const TextStyle(color: C.plum, fontSize: 13)),
                  ),
                  TextButton.icon(
                    onPressed: clearGraphHighlight,
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: const Text('Clear highlight'),
                    style: TextButton.styleFrom(foregroundColor: C.plum),
                  ),
                ]),
              ],
              const SizedBox(height: 12),
              Wrap(spacing: 14, runSpacing: 6, children: [
                for (final t in ['Person', 'Document', 'EvidenceSpan', 'FollowUp', 'Appointment', 'Receipt'])
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: nodeColor(t), shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text(t, style: const TextStyle(fontSize: 12.5)),
                  ]),
              ]),
            ]),
          ),
          if (nodes.length <= 1)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: const EmptyState(
                      icon: Icons.hub_outlined,
                      title: 'The graph is empty',
                      body: 'Only this profile exists so far. Confirm a record and its paragraphs, '
                          'follow-ups and receipts appear here as connected nodes.',
                    ),
                  ),
                ),
              ),
            )
          else
          Expanded(
            child: InteractiveViewer(
              constrained: false,
              boundaryMargin: const EdgeInsets.all(200),
              minScale: 0.4,
              maxScale: 2,
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(children: [

                  // The first child of the Stack, so every edge is drawn
                  // behind the boxes instead of across their labels.
                  CustomPaint(size: Size(width, height), painter: _EdgePainter(edges, pos, const Size(_w, _h))),

                  CustomPaint(
                      size: Size(width, height),
                      painter: _EdgePainter(
                          edges, pos, const Size(_w, _h), pathEdges, onPath.isNotEmpty)),

                  for (final n in nodes)
                    if (pos[n['id']] != null)
                      Positioned(
                        left: pos[n['id']]!.dx,
                        top: pos[n['id']]!.dy,
                        width: _w,
                        height: _h,
                        child: _NodeBox(
                            node: n,
                            onPath: onPath.contains('${n['id']}'),
                            dimmed: onPath.isNotEmpty && !onPath.contains('${n['id']}')),
                      ),
                ]),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class _NodeBox extends StatelessWidget {
  final Json node;

  /// On the highlighted answer path, or pushed into the background because
  /// some other part of the graph is.
  final bool onPath;
  final bool dimmed;
  const _NodeBox({required this.node, this.onPath = false, this.dimmed = false});

  @override
  Widget build(BuildContext context) {
    final type = node['type'] as String;
    final color = nodeColor(type);
    final label = '${node['label'] ?? ''}';
    final tappable = type == 'Document' || type == 'EvidenceSpan';

    return Tooltip(
      // A box can only be so wide, so the full title — "D02 · Clinic
      // front-desk note" — stays readable on hover however long it is.
      message: '$type · $label',
      waitDuration: const Duration(milliseconds: 300),
      child: Material(
        color: C.card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: tappable
              ? () => showSource(context, type == 'Document' ? node['id'] : node['doc_id'], type == 'EvidenceSpan' ? node['id'] : '')
              : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.5), width: 1.4),

    return Opacity(
      opacity: dimmed ? 0.3 : 1,
      child: Material(
      color: onPath ? C.plumSoft : C.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: tappable
            ? () => showSource(context, type == 'Document' ? node['id'] : node['doc_id'], type == 'EvidenceSpan' ? node['id'] : '')
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: color.withValues(alpha: onPath ? 1 : 0.5), width: onPath ? 2.6 : 1.4),
          ),
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(type, style: TextStyle(fontSize: 9.5, letterSpacing: 0.8, color: color, fontWeight: FontWeight.w800)),
                Text(node['label'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ]),

            ),
            child: Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(type, style: TextStyle(fontSize: 9.5, letterSpacing: 0.8, color: color, fontWeight: FontWeight.w800)),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
          ),
        ),
      ),
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  final List<Json> edges;
  final Map<String, Offset> pos;
  final Size box;

  /// The edges of the highlighted answer path, keyed by [GraphScreen.edgeKey],
  /// and whether a path is being shown at all — with one, the rest fades back.
  final Set<String> pathEdges;
  final bool dimRest;
  _EdgePainter(this.edges, this.pos, this.box, this.pathEdges, this.dimRest);

  bool _onPath(Json e) => pathEdges.contains(GraphScreen.edgeKey(e['source'], e['target']));

  /// FULFILLS is the link the whole app turns on — a receipt closing the
  /// follow-up it answers — so it is drawn heavier and in the receipt colour
  /// while every other edge stays quiet.
  static bool _highlighted(Json e) => e['type'] == 'FULFILLS';

  @override
  void paint(Canvas canvas, Size size) {
    final plain = Paint()

      ..color = C.muted.withValues(alpha: 0.45)
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    final strong = Paint()
      ..color = nodeColor('Receipt').withValues(alpha: 0.75)
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke;
    // Highlighted edges last, so they read on top of the quiet ones — all of
    // them still behind the boxes, which are later children of the Stack.
    for (final e in [...edges.where((e) => !_highlighted(e)), ...edges.where(_highlighted)]) {
      final a = pos[e['source']], b = pos[e['target']];
      if (a == null || b == null) continue;
      final paint = _highlighted(e) ? strong : plain;

      ..color = C.muted.withValues(alpha: dimRest ? 0.12 : 0.45)
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    final strong = Paint()
      ..color = C.plum.withValues(alpha: 0.85)
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke;
    // The path is drawn last, so it reads on top of whatever it crosses.
    for (final e in [...edges.where((e) => !_onPath(e)), ...edges.where(_onPath)]) {
      final a = pos[e['source']], b = pos[e['target']];
      if (a == null || b == null) continue;
      final paint = _onPath(e) ? strong : plain;

      final forward = b.dx >= a.dx;
      final p1 = Offset(a.dx + (forward ? box.width : 0), a.dy + box.height / 2);
      final p2 = Offset(b.dx + (forward ? 0 : box.width), b.dy + box.height / 2);
      final dx = (p2.dx - p1.dx).abs() * 0.5 + 20;
      final path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..cubicTo(p1.dx + (forward ? dx : -dx), p1.dy, p2.dx - (forward ? dx : -dx), p2.dy, p2.dx, p2.dy);
      canvas.drawPath(path, paint);
      // arrow head
      final dir = forward ? -1.0 : 1.0;
      final head = Path()
        ..moveTo(p2.dx, p2.dy)
        ..lineTo(p2.dx + dir * 7, p2.dy - 4)
        ..lineTo(p2.dx + dir * 7, p2.dy + 4)
        ..close();
      canvas.drawPath(head, Paint()..color = paint.color.withValues(alpha: 0.85));
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter old) =>
      old.edges != edges ||
      old.pos != pos ||
      old.pathEdges != pathEdges ||
      old.dimRest != dimRest;
}

/// Which row each node sits on, on one grid shared by every column, so that
/// connected nodes line up: each Receipt beside the span that documents it and
/// the FollowUp it fulfils, instead of wherever its id happened to sort.
///
/// Two familiar passes do it. The nodes inside a column are ordered by the
/// average row of their neighbours in other columns — a barycenter sweep, run
/// from both sides until the order settles. Then each node is pulled onto that
/// average row and pushed down only as far as the first row still free in its
/// column, which keeps the order the sweep found while letting a short column
/// sit opposite the middle of a long one. Ids break every tie, so the same
/// graph always lays out the same way.
///
/// `byCol` is reordered in place, so each column's list ends up in row order.
Map<String, int> graphRows(Map<int, List<Json>> byCol, List<Json> edges) {
  final nbrs = <String, Set<String>>{};
  for (final e in edges) {
    final s = '${e['source']}', t = '${e['target']}';
    if (s == t) continue;
    nbrs.putIfAbsent(s, () => <String>{}).add(t);
    nbrs.putIfAbsent(t, () => <String>{}).add(s);
  }
  final colOf = <String, int>{}, row = <String, int>{};
  byCol.forEach((col, list) {
    list.sort((a, b) => a['id'].toString().compareTo(b['id'].toString()));
    for (var i = 0; i < list.length; i++) {
      colOf['${list[i]['id']}'] = col;
      row['${list[i]['id']}'] = i;
    }
  });
  final cols = byCol.keys.toList()..sort();

  /// Average row of this node's neighbours in *other* columns, or null when
  /// it has none to line up with.
  double? pull(String id, int col) {
    final rows = [
      for (final m in nbrs[id] ?? const <String>{})
        if (colOf[m] != null && colOf[m] != col) row[m]!.toDouble()
    ];
    if (rows.isEmpty) return null;
    return rows.reduce((a, b) => a + b) / rows.length;
  }

  for (var pass = 0; pass < 6; pass++) {
    for (final col in pass.isEven ? cols : cols.reversed) {
      final list = byCol[col]!;
      final key = {
        for (final n in list) '${n['id']}': pull('${n['id']}', col) ?? row['${n['id']}']!.toDouble()
      };
      list.sort((a, b) {
        final c = key['${a['id']}']!.compareTo(key['${b['id']}']!);
        return c != 0 ? c : a['id'].toString().compareTo(b['id'].toString());
      });
      var next = 0;
      for (final n in list) {
        final id = '${n['id']}';
        row[id] = math.max((pull(id, col) ?? next.toDouble()).round(), next);
        next = row[id]! + 1;
      }
    }
  }
  // A pass can only ever push a node further down, so the picture drifts
  // away from the top; it is brought back before anything is measured.
  if (row.isEmpty) return row;
  final top = row.values.reduce(math.min);
  return {for (final e in row.entries) e.key: e.value - top};
}
