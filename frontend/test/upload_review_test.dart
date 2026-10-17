// An upload is a second way into the same review, not a shortcut past it. Two
// things have to hold: Add Record offers it without losing manual entry, and a
// draft whose text a model transcribed says so on the Review screen, because
// a transcription is a reading of a picture rather than the record itself.
import 'package:caresaath/api.dart';
import 'package:caresaath/screens/add_record_screen.dart';
import 'package:caresaath/screens/review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json draft({String? readBy, String? filename}) => {
      'id': 'D04',
      'title': 'Clinic front-desk note',
      'date': '2026-10-15',
      'extractor': 'rule-based-v1',
      if (readBy != null) 'read_by': readBy,
      if (filename != null) 'filename': filename,
      'spans': [
        {
          'id': 'D04-P1',
          'index': 1,
          'text': 'The vitamin D report was received at the clinic.',
        }
      ],
      'facts': [
        {
          'type': 'receipt',
          'item': 'vitamin_d_report',
          'label': 'Vitamin D report',
          'span_id': 'D04-P1',
          'date': '2026-10-15',
        }
      ],
    };

Future<void> pumpReview(WidgetTester tester, Json d) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: ReviewScreen(draft: d)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Add Record offers the upload and keeps manual entry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: AddRecordScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Upload PDF / photo'), findsOneWidget);
    // The paste-and-extract path is untouched.
    expect(find.text('Extract & review'), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'Record text'),
        findsOneWidget);
    // Nothing is read yet, so nothing claims to be.
    expect(find.textContaining('Reading '), findsNothing);
  });

  testWidgets('a transcribed draft tells the reviewer a model read it', (tester) async {
    await pumpReview(tester, draft(readBy: 'gemini', filename: 'desk-slip.jpg'));

    expect(
        find.textContaining('transcribed from desk-slip.jpg by Gemini'), findsOneWidget);
    expect(find.textContaining('Read it against the original before confirming'),
        findsOneWidget);
    // It is still an ordinary review: the facts are there to check.
    expect(find.text('Confirm 1 fact(s)'), findsOneWidget);
  });

  testWidgets('a PDF read from its own text layer claims no transcription',
      (tester) async {
    await pumpReview(tester, draft(readBy: 'pdf-text', filename: 'slip.pdf'));

    expect(find.textContaining('by Gemini'), findsNothing);
    expect(find.text('Confirm 1 fact(s)'), findsOneWidget);
  });

  testWidgets('pasted text claims no transcription either', (tester) async {
    await pumpReview(tester, draft());

    expect(find.textContaining('by Gemini'), findsNothing);
  });

  testWidgets('a transcribed draft with no filename still says it was transcribed',
      (tester) async {
    await pumpReview(tester, draft(readBy: 'gemini'));

    expect(find.textContaining('transcribed from an upload by Gemini'), findsOneWidget);
  });
}
