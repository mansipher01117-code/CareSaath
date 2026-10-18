// The graph used to order each column by node id and centre each column on
// its own, so a Receipt could sit rows away from the span that documents it
// and its edge crossed the boxes in between. Rows are now one grid shared by
// every column, and connected nodes are pulled onto neighbouring rows.
import 'package:caresaath/api.dart';
import 'package:caresaath/screens/graph_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Json node(String id, String type) => {'id': id, 'type': type};
Json edge(String a, String b, String type) => {'source': a, 'target': b, 'type': type};

/// Two items in one profile: each is requested by a span of D01 and received
/// in a span of D02. The ids deliberately sort against the connections —
/// D01-P1 requests the follow-up whose receipt sorts *second* — so a layout
/// that just sorts by id cannot pass.
({Map<int, List<Json>> byCol, List<Json> edges}) twoItems() => (
      byCol: {
        0: [node('nilofer', 'Person')],
        1: [node('D01', 'Document'), node('D02', 'Document')],
        2: [
          node('D01-P1', 'EvidenceSpan'),
          node('D01-P2', 'EvidenceSpan'),
          node('D02-P1', 'EvidenceSpan'),
          node('D02-P2', 'EvidenceSpan'),
        ],
        3: [node('fu:insurance_card', 'FollowUp'), node('fu:referral', 'FollowUp')],
        4: [
          node('fu:insurance_card@D02-P2', 'Receipt'),
          node('fu:referral@D02-P1', 'Receipt'),
        ],
      },
      edges: [
        edge('nilofer', 'D01', 'HAS_DOCUMENT'),
        edge('nilofer', 'D02', 'HAS_DOCUMENT'),
        edge('D01', 'D01-P1', 'HAS_SPAN'),
        edge('D01', 'D01-P2', 'HAS_SPAN'),
        edge('D02', 'D02-P1', 'HAS_SPAN'),
        edge('D02', 'D02-P2', 'HAS_SPAN'),
        edge('D01-P1', 'fu:referral', 'REQUESTS'),
        edge('D01-P2', 'fu:insurance_card', 'REQUESTS'),
        edge('D02-P1', 'fu:referral@D02-P1', 'DOCUMENTS_RECEIPT'),
        edge('D02-P2', 'fu:insurance_card@D02-P2', 'DOCUMENTS_RECEIPT'),
        edge('fu:referral@D02-P1', 'fu:referral', 'FULFILLS'),
        edge('fu:insurance_card@D02-P2', 'fu:insurance_card', 'FULFILLS'),
        edge('nilofer', 'fu:referral', 'HAS_FOLLOWUP'),
        edge('nilofer', 'fu:insurance_card', 'HAS_FOLLOWUP'),
      ],
    );

void main() {
  test('every edge joins rows that are neighbours', () {
    // The point of the ordering: an edge never reaches past a node it has
    // nothing to do with. Under the old id order the receipt of the insurance
    // card sat two rows from the span that documents it.
    final g = twoItems();
    final row = graphRows(g.byCol, g.edges);

    for (final e in g.edges) {
      final d = (row['${e['source']}']! - row['${e['target']}']!).abs();
      expect(d, lessThanOrEqualTo(1), reason: '${e['source']} → ${e['target']} spans $d rows');
    }
  });

  test('each receipt is next to the follow-up it fulfils', () {
    final g = twoItems();
    final row = graphRows(g.byCol, g.edges);

    expect((row['fu:referral@D02-P1']! - row['fu:referral']!).abs(), lessThanOrEqualTo(1));
    expect((row['fu:insurance_card@D02-P2']! - row['fu:insurance_card']!).abs(),
        lessThanOrEqualTo(1));
  });

  test('each receipt is next to the span that documents it', () {
    final g = twoItems();
    final row = graphRows(g.byCol, g.edges);

    expect((row['fu:referral@D02-P1']! - row['D02-P1']!).abs(), lessThanOrEqualTo(1));
    expect((row['fu:insurance_card@D02-P2']! - row['D02-P2']!).abs(), lessThanOrEqualTo(1));
  });

  test('each follow-up is on the row of the span that requested it', () {
    final g = twoItems();
    final row = graphRows(g.byCol, g.edges);

    expect(row['fu:referral'], row['D01-P1']);
    expect(row['fu:insurance_card'], row['D01-P2']);
  });

  test('id order does not decide the rows', () {
    final g = twoItems();
    final row = graphRows(g.byCol, g.edges);

    // Among the spans, D01-P2 sorts second but is laid out first, because the
    // follow-up it requests is the one the receipt column starts with.
    expect(row['D01-P2'], lessThan(row['D01-P1']!));
  });

  test('every node keeps a row of its own inside its column', () {
    final g = twoItems();
    final row = graphRows(g.byCol, g.edges);

    for (final list in g.byCol.values) {
      final rows = [for (final n in list) row['${n['id']}']!];
      expect(rows.toSet().length, rows.length, reason: 'two nodes share a row in one column');
      expect(rows, equals([...rows]..sort()), reason: 'the column list is not in row order');
    }
  });

  test('rows start at the top, so nothing is laid out above the canvas', () {
    final g = twoItems();
    final row = graphRows(g.byCol, g.edges);

    expect(row.values.reduce((a, b) => a < b ? a : b), 0);
  });

  test('the person sits opposite the middle of the documents, not above them', () {
    final g = twoItems();
    final row = graphRows(g.byCol, g.edges);

    expect(row['nilofer'], greaterThan(0));
  });

  test('a graph with no edges at all still lays out', () {
    final byCol = {
      0: [node('nilofer', 'Person')],
      1: [node('D01', 'Document')],
    };
    final row = graphRows(byCol, []);

    expect(row, {'nilofer': 0, 'D01': 0});
  });
}
