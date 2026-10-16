// An answer is a list of claims, and the evidence belongs to the claim it
// backs. The bug: every line was plain text with one pooled "Sources" list
// under the whole answer, so a reader could not tell which quote backed which
// sentence — and the claims that rest on the absence of a record looked just
// as cited as the rest.
import 'package:caresaath/screens/ask_screen.dart';
import 'package:caresaath/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Claims of my own, shaped as /ask returns them.
const documented = {
  'text': 'Knee physio referral: receipt is documented (2026-10-15, R09).',
  'sources': [
    {
      'span_id': 'R09-P1',
      'doc_id': 'R09',
      'doc_title': 'Front desk slip',
      'date': '2026-10-15',
      'text': 'Knee physio referral was received at the front desk.',
    }
  ],
};
const notDocumented = {
  'text': 'Blood sugar report: receipt is not documented in the available records.',
  'sources': [],
};
const requested = {
  'text': 'Blood sugar report was requested in R07 (2026-10-12).',
  'sources': [
    {
      'span_id': 'R07-P2',
      'doc_id': 'R07',
      'doc_title': 'Physio referral note',
      'date': '2026-10-12',
      'text': 'Please bring the blood sugar report.',
    }
  ],
};

Future<void> pumpClaims(WidgetTester tester, List<Map<String, dynamic>> claims) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final c in claims) AnswerClaim(c)],
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a sourced claim shows its own span and quote', (tester) async {
    await pumpClaims(tester, [documented]);

    expect(find.text(documented['text'] as String), findsOneWidget);
    expect(find.byType(SourceChip), findsOneWidget);
    expect(find.text('R09-P1'), findsOneWidget);
    expect(find.textContaining('received at the front desk'), findsOneWidget);
  });

  testWidgets('a claim about a missing receipt shows no source at all', (tester) async {
    await pumpClaims(tester, [notDocumented]);

    expect(find.text(notDocumented['text'] as String), findsOneWidget);
    expect(find.byType(SourceChip), findsNothing,
        reason: 'nothing in the records says this, so nothing may be cited for it');
  });

  testWidgets('each claim keeps its own evidence instead of a pooled list', (tester) async {
    await pumpClaims(tester, [requested, documented, notDocumented]);

    expect(find.byType(SourceChip), findsNWidgets(2));

    // The chip for each claim sits inside that claim, not under the answer.
    for (final pair in [
      [requested, 'R07-P2'],
      [documented, 'R09-P1'],
    ]) {
      final claim = pair[0] as Map<String, dynamic>;
      expect(
        find.descendant(
          of: find.ancestor(
              of: find.text(claim['text'] as String), matching: find.byType(AnswerClaim)),
          matching: find.text(pair[1] as String),
        ),
        findsOneWidget,
      );
    }

    expect(
      find.descendant(
        of: find.ancestor(
            of: find.text(notDocumented['text'] as String), matching: find.byType(AnswerClaim)),
        matching: find.byType(SourceChip),
      ),
      findsNothing,
    );
  });

  testWidgets('a claim with no sources key still renders', (tester) async {
    await pumpClaims(tester, [
      {'text': 'No record has been confirmed yet.'}
    ]);

    expect(find.text('No record has been confirmed yet.'), findsOneWidget);
    expect(find.byType(SourceChip), findsNothing);
  });
}
