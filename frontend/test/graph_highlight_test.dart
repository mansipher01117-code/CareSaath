// "Show in graph" is the one place the Ask screen and the Graph screen talk to
// each other, and they do it through a notifier rather than a shared parent.
// What matters: only an answer that cites something the graph holds offers the
// button, pressing it hands over that exact path, and the Graph tab is asked
// for at the same moment.
import 'package:caresaath/api.dart';
import 'package:caresaath/screens/ask_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json answer({Json? path}) => {
      'question': 'Was the referral received?',
      'lang': 'en',
      'intent': 'item',
      'engine': 'llm',
      'answer': ['D02 documents that it was received.'],
      'claims': [
        {
          'text': 'D02 documents that it was received.',
          'sources': [
            {
              'span_id': 'D02-P1',
              'doc_id': 'D02',
              'doc_title': 'Front desk slip',
              'date': '2026-10-15',
              'text': 'The knee physio referral was received at the front desk.',
            }
          ],
        }
      ],
      'sources': const <Json>[],
      'trace': const <Json>[],
      if (path != null) 'path': path,
    };

Json realPath() => {
      'nodes': ['nilofer', 'D02', 'D02-P1', 'fu:referral@D02-P1', 'fu:referral'],
      'edges': [
        ['nilofer', 'D02'],
        ['D02', 'D02-P1'],
        ['D02-P1', 'fu:referral@D02-P1'],
        ['fu:referral@D02-P1', 'fu:referral'],
      ],
    };

Future<void> pump(WidgetTester tester, Json a, {VoidCallback? onShow}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: AnswerCard(answer: a, onShowInGraph: onShow)),
    ),
  ));
}

void main() {
  setUp(clearGraphHighlight);
  tearDown(clearGraphHighlight);

  testWidgets('an answer with a path offers to show it in the graph', (tester) async {
    await pump(tester, answer(path: realPath()), onShow: () {});
    expect(find.text('Show in graph'), findsOneWidget);
  });

  testWidgets('pressing it hands the graph that exact path and asks for the tab',
      (tester) async {
    var switched = 0;
    await pump(tester, answer(path: realPath()), onShow: () => switched++);

    await tester.tap(find.text('Show in graph'));
    await tester.pumpAndSettle();

    expect(switched, 1, reason: 'the Graph tab was not asked for');
    expect(graphHighlight.value?['nodes'], realPath()['nodes']);
    expect(graphHighlight.value?['edges'], realPath()['edges']);
  });

  testWidgets('clearing the highlight puts the whole graph back', (tester) async {
    await pump(tester, answer(path: realPath()), onShow: () {});
    await tester.tap(find.text('Show in graph'));
    await tester.pumpAndSettle();
    expect(graphHighlight.value, isNotNull);

    clearGraphHighlight();

    expect(graphHighlight.value, isNull);
  });

  testWidgets('an answer that cites nothing offers no button', (tester) async {
    // A refusal, or an answer whose every citation the backend dropped: the
    // path comes back empty and there is nothing to light up.
    await pump(tester, answer(path: {'nodes': <String>[], 'edges': <List>[]}), onShow: () {});
    expect(find.text('Show in graph'), findsNothing);
    expect(graphHighlight.value, isNull);
  });

  testWidgets('an answer from a backend that sends no path offers no button',
      (tester) async {
    await pump(tester, answer(), onShow: () {});
    expect(find.text('Show in graph'), findsNothing);
  });

  testWidgets('a card with nowhere to switch to offers no button', (tester) async {
    await pump(tester, answer(path: realPath()));
    expect(find.text('Show in graph'), findsNothing);
  });
}
