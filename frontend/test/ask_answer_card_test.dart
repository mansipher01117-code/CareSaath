// The Ask screen has to be honest about two things at a glance: which engine
// wrote the answer, and which claim each source actually backs. A claim whose
// citation the backend dropped must render with no chip rather than borrowing
// the neighbouring claim's evidence.
import 'package:caresaath/screens/ask_screen.dart';
import 'package:caresaath/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> llmAnswer() => {
      'question': 'Is the knee physio referral sorted?',
      'lang': 'en',
      'intent': 'item',
      'engine': 'llm',
      'answer': [
        'The 12 October note asked for the Knee physio referral.',
        'D02 (2026-10-15) documents that it was received.',
        'An MRI was also requested.',
      ],
      'claims': [
        {
          'text': 'The 12 October note asked for the Knee physio referral.',
          'sources': [
            {
              'span_id': 'D01-P1',
              'doc_id': 'D01',
              'doc_title': 'Physio referral note',
              'date': '2026-10-12',
              'text': 'Please bring the knee physio referral to the next appointment.',
            }
          ],
        },
        {
          'text': 'D02 (2026-10-15) documents that it was received.',
          'sources': [
            {
              'span_id': 'D02-P1',
              'doc_id': 'D02',
              'doc_title': 'Front desk slip',
              'date': '2026-10-15',
              'text': 'The knee physio referral was received at the front desk.',
            }
          ],
        },
        // The backend dropped this one's invented citation.
        {'text': 'An MRI was also requested.', 'sources': <Map<String, dynamic>>[]},
      ],
      'sources': [
        {
          'span_id': 'D01-P1',
          'doc_id': 'D01',
          'doc_title': 'Physio referral note',
          'date': '2026-10-12',
          'text': 'Please bring the knee physio referral to the next appointment.',
        },
        {
          'span_id': 'D02-P1',
          'doc_id': 'D02',
          'doc_title': 'Front desk slip',
          'date': '2026-10-15',
          'text': 'The knee physio referral was received at the front desk.',
        },
      ],
      'trace': [
        {'tool': 'list_unresolved_followups', 'args': <String, dynamic>{}, 'returned': '1 item(s)'},
        {
          'tool': 'inspect_source_span',
          'args': {'doc_id': 'D02', 'span_id': 'D02-P1'},
          'returned': 'D02-P1, 58 chars',
        },
      ],
      'matched_items': <String>[],
    };

Future<void> pump(WidgetTester tester, Map<String, dynamic> answer) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: AnswerCard(answer: answer)),
    ),
  ));
}

void main() {
  testWidgets('an LLM answer is badged AI and chips sit under their own claim',
      (tester) async {
    await pump(tester, llmAnswer());

    expect(find.text('AI'), findsOneWidget);
    expect(find.text('Rules'), findsNothing);

    // Every claim is rendered, including the one left without evidence.
    expect(find.text('An MRI was also requested.'), findsOneWidget);

    // Two chips for three claims: the dropped citation leaves no chip behind.
    expect(find.text('D01-P1'), findsOneWidget);
    expect(find.text('D02-P1'), findsOneWidget);
    expect(find.byType(SourceChip), findsNWidgets(2));
  });

  testWidgets('the rules fallback is badged Rules', (tester) async {
    await pump(tester, {...llmAnswer(), 'engine': 'rules'});

    expect(find.text('Rules'), findsOneWidget);
    expect(find.text('AI'), findsNothing);
  });

  testWidgets('the trace shows each tool call with its arguments', (tester) async {
    await pump(tester, llmAnswer());

    await tester.tap(find.text('How the agent got here'));
    await tester.pumpAndSettle();

    expect(find.text('1. list_unresolved_followups()  →  1 item(s)'), findsOneWidget);
    expect(
        find.text('2. inspect_source_span(doc_id: D02, span_id: D02-P1)  →  D02-P1, 58 chars'),
        findsOneWidget);
    expect(find.text('intent: item   ·   engine: llm'), findsOneWidget);
  });

  testWidgets('an answer without claims still renders its lines and sources',
      (tester) async {
    final old = llmAnswer()..remove('claims');
    await pump(tester, old);

    expect(find.text('The 12 October note asked for the Knee physio referral.'),
        findsOneWidget);
    expect(find.text('D01-P1'), findsOneWidget);
    expect(find.text('D02-P1'), findsOneWidget);
  });
}
