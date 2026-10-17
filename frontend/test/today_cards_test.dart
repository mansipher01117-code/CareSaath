// Two cards that used to overclaim:
//
// * "What changed" showed a single chip pointing at "<doc>-P1" — a span id it
//   guessed from the document id. Usually no such span existed, and when it
//   did it was whatever happened to be the first paragraph.
// * The appointment card called whatever came back first "Next appointment",
//   with no year and no check that the date was even still ahead.
import 'package:caresaath/screens/today_screen.dart';
import 'package:caresaath/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> change() => {
      'doc_id': 'D02',
      'doc_title': 'Front desk slip',
      'doc_date': '2026-10-15',
      'at': '2026-10-15T09:00:00+00:00',
      'changed': [
        {
          'id': 'fu:knee_physio_referral',
          'label': 'Knee physio referral',
          'from': 'receipt_not_documented',
          'to': 'receipt_documented',
          'doc_id': 'D02',
          'span_id': 'D02-P1',
        }
      ],
      'added': [
        {
          'id': 'fu:insurance_card',
          'label': 'Insurance card',
          'to': 'receipt_not_documented',
          'doc_id': 'D02',
          'span_id': 'D02-P3',
        }
      ],
      'unchanged': [
        // Nothing in this document evidences it, so it gets no chip at all.
        {'id': 'fu:old_xray', 'label': 'Old X-ray film', 'status': 'receipt_not_documented'}
      ],
    };

Map<String, dynamic> appointment({
  required String year,
  required bool upcoming,
}) =>
    {
      'date': '20 October',
      'time': '10:00 AM',
      'year': year,
      'on': year.isEmpty ? '' : '$year-10-20',
      'upcoming': upcoming,
      'sources': [
        {'span_id': 'D01-P2', 'doc_id': 'D01', 'text': 'Appointment confirmed for 20 October.'}
      ],
    };

Future<void> pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));
  await tester.pumpAndSettle();
}

void main() {
  group('What changed', () {
    testWidgets('each row cites the span that evidences it', (tester) async {
      await pump(tester, ChangeCard(change: change()));

      expect(find.text('D02-P1'), findsOneWidget);
      expect(find.text('D02-P3'), findsOneWidget);
      expect(find.byType(SourceChip), findsNWidgets(2));
    });

    testWidgets('no span id is invented from the document id', (tester) async {
      await pump(tester, ChangeCard(change: change()));

      // The old card rendered this for the whole change.
      expect(find.text('D02-P1'), findsOneWidget);
      final chips = tester.widgetList<SourceChip>(find.byType(SourceChip));
      expect(chips.map((c) => c.spanId).toSet(), {'D02-P1', 'D02-P3'});
    });

    testWidgets('an item with no evidence in this document gets no chip', (tester) async {
      await pump(tester, ChangeCard(change: change()));

      expect(find.text('Old X-ray film'), findsOneWidget);
      expect(find.byType(SourceChip), findsNWidgets(2), reason: 'not three');
    });
  });

  group('Appointment card', () {
    testWidgets('a future appointment is the next one', (tester) async {
      await pump(tester, AppointmentCard(appt: appointment(year: '2026', upcoming: true)));

      expect(find.text('NEXT APPOINTMENT'), findsOneWidget);
      expect(find.text('2026'), findsOneWidget);
    });

    testWidgets('a past appointment is not called next', (tester) async {
      await pump(tester, AppointmentCard(appt: appointment(year: '2025', upcoming: false)));

      expect(find.text('NEXT APPOINTMENT'), findsNothing);
      expect(find.text('APPOINTMENT ON RECORD'), findsOneWidget);
    });

    testWidgets('an appointment with no year says the record did not state one',
        (tester) async {
      await pump(tester, AppointmentCard(appt: appointment(year: '', upcoming: false)));

      expect(find.text('Year not stated in the record'), findsOneWidget);
      expect(find.text('NEXT APPOINTMENT'), findsNothing);
    });
  });
}
