// Switching a fact's type on the Review screen must rebuild the fact instead
// of keeping the previous type's fields. Inheriting them is the bug: an
// appointment relabelled as a receipt arrived with "Appointment" sitting in
// the item field, which then became a follow-up item of that name.
import 'package:caresaath/screens/review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A draft of my own: one paragraph asking for a referral, one confirming an
/// appointment. Two spans, so the span picker is rendered too.
Map<String, dynamic> draft({required List<Map<String, dynamic>> facts}) => {
      'id': 'R07',
      'title': 'Physio referral note',
      'date': '2026-10-12',
      'extractor': 'rule-based-v1',
      'spans': [
        {
          'id': 'R07-P1',
          'index': 1,
          'text': 'Please bring the knee physio referral to the next appointment.',
        },
        {'id': 'R07-P2', 'index': 2, 'text': 'Appointment confirmed for 20 October at 10:00 AM.'},
      ],
      'facts': facts,
    };

final requestFact = {
  'type': 'request',
  'item': 'knee_physio_referral',
  'label': 'Knee physio referral',
  'span_id': 'R07-P1',
};
final appointmentFact = {
  'type': 'appointment',
  'span_id': 'R07-P2',
  'date': '20 October',
  'time': '10:00 AM',
  'label': 'Appointment',
};
final absenceFact = {
  'type': 'absence_note',
  'span_id': 'R07-P1',
  'items': ['discharge_summary'],
  'label': 'Receipt not documented: Discharge summary',
};

Future<void> pumpReview(WidgetTester tester, Map<String, dynamic> d) async {
  await tester.binding.setSurfaceSize(const Size(1200, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: ReviewScreen(draft: d)));
  await tester.pumpAndSettle();
}

/// The type dropdown is the first one in the card; the span picker follows.
Future<void> switchTypeTo(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButton<String>).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// A card now holds several text fields (item, date, time, year), so each is
/// addressed by its own label rather than by position.
Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label);

String fieldText(WidgetTester tester, String label) =>
    tester.widget<TextField>(field(label)).controller!.text;

String itemFieldText(WidgetTester tester) => fieldText(tester, 'Item');

void main() {
  testWidgets('a request keeps its item name when corrected to a receipt', (tester) async {
    await pumpReview(tester, draft(facts: [requestFact]));
    expect(itemFieldText(tester), 'Knee physio referral');

    await switchTypeTo(tester, 'Receipt');

    expect(itemFieldText(tester), 'Knee physio referral',
        reason: 'a genuine request/receipt correction should keep the item name');
    expect(find.text('Confirm 1 fact(s)'), findsOneWidget);
  });

  testWidgets('an appointment switched to a receipt does not inherit "Appointment" as the item',
      (tester) async {
    await pumpReview(tester, draft(facts: [appointmentFact]));
    expect(fieldText(tester, 'Date'), '20 October');
    expect(fieldText(tester, 'Time'), '10:00 AM');

    await switchTypeTo(tester, 'Receipt');

    expect(itemFieldText(tester), isEmpty,
        reason: '"Appointment" is the old type\'s label, not an item name');
    expect(find.text('Confirm 0 fact(s)'), findsOneWidget);
    expect(find.textContaining('Name this item'), findsOneWidget,
        reason: 'the fact is skipped, so it must say so rather than drop silently');
  });

  testWidgets('a note switched to a request does not inherit its sentence as the item',
      (tester) async {
    await pumpReview(tester, draft(facts: [absenceFact]));

    await switchTypeTo(tester, 'Request');

    expect(itemFieldText(tester), isEmpty);
    expect(find.text('Confirm 0 fact(s)'), findsOneWidget);
  });

  testWidgets('a request switched to an appointment cannot be saved half-built', (tester) async {
    await pumpReview(tester, draft(facts: [requestFact]));

    await switchTypeTo(tester, 'Appointment');

    expect(find.text('Confirm 0 fact(s)'), findsOneWidget);
    expect(find.textContaining('No date and time'), findsOneWidget);
    expect(find.textContaining('null'), findsNothing,
        reason: 'the old code rendered "null · null" for the missing fields');
  });

  testWidgets('an appointment switched away and back is not silently re-armed', (tester) async {
    await pumpReview(tester, draft(facts: [appointmentFact]));

    await switchTypeTo(tester, 'Request');
    await switchTypeTo(tester, 'Appointment');

    expect(find.text('Confirm 0 fact(s)'), findsOneWidget,
        reason: 'the date and time were read from the text and cannot be re-invented');
    expect(find.textContaining('No date and time'), findsOneWidget);
  });

  testWidgets('typing an item name makes a switched fact saveable again', (tester) async {
    await pumpReview(tester, draft(facts: [appointmentFact]));
    await switchTypeTo(tester, 'Receipt');
    expect(find.text('Confirm 0 fact(s)'), findsOneWidget);

    await tester.enterText(field('Item'), 'Knee physio referral');
    await tester.pumpAndSettle();

    expect(find.text('Confirm 1 fact(s)'), findsOneWidget);
    expect(find.textContaining('Name this item'), findsNothing);
  });

  testWidgets('an item name survives a detour through another type', (tester) async {
    await pumpReview(tester, draft(facts: [requestFact]));
    await tester.enterText(field('Item'), 'Physio referral');
    await tester.pumpAndSettle();

    await switchTypeTo(tester, 'Note only');
    await switchTypeTo(tester, 'Request');

    expect(itemFieldText(tester), 'Physio referral',
        reason: 'parking the name is not the same as inheriting another label');
    expect(find.text('Confirm 1 fact(s)'), findsOneWidget);
  });

  testWidgets('an unchecked fact reports no blocker', (tester) async {
    await pumpReview(tester, draft(facts: [appointmentFact]));
    await switchTypeTo(tester, 'Receipt');
    expect(find.textContaining('Name this item'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    expect(find.textContaining('Name this item'), findsNothing);
    expect(find.text('Confirm 0 fact(s)'), findsOneWidget);
  });

  dateEditingTests();
}

// Dates and times are the reviewer's to correct. The extractor reads them out
// of free text and gets them wrong often enough that a read-only display was a
// dead end: the only options were accept a wrong date or discard the fact.
void dateEditingTests() {
  testWidgets('an appointment date, time and year can all be corrected',
      (tester) async {
    await pumpReview(tester, draft(facts: [appointmentFact]));

    await tester.enterText(field('Date'), '21 October');
    await tester.enterText(field('Time'), '11:30 AM');
    await tester.enterText(field('Year'), '2026');
    await tester.pumpAndSettle();

    expect(fieldText(tester, 'Date'), '21 October');
    expect(fieldText(tester, 'Time'), '11:30 AM');
    expect(fieldText(tester, 'Year'), '2026');
    expect(find.text('Confirm 1 fact(s)'), findsOneWidget);
  });

  testWidgets('a blank year is an explicit "unknown", not a gap', (tester) async {
    await pumpReview(tester, draft(facts: [appointmentFact]));

    expect(fieldText(tester, 'Year'), isEmpty);
    expect(find.textContaining('Year unknown'), findsOneWidget);
    // An appointment with no year is still saveable: the date and time are
    // what make it real.
    expect(find.text('Confirm 1 fact(s)'), findsOneWidget);
  });

  testWidgets('typing a year replaces the unknown note', (tester) async {
    await pumpReview(tester, draft(facts: [appointmentFact]));

    await tester.enterText(field('Year'), '2026');
    await tester.pumpAndSettle();

    expect(find.textContaining('Year unknown'), findsNothing);
    expect(find.textContaining('Year taken from the record'), findsOneWidget);
  });

  testWidgets('clearing the date blocks the appointment again', (tester) async {
    await pumpReview(tester, draft(facts: [appointmentFact]));

    await tester.enterText(field('Date'), '');
    await tester.pumpAndSettle();

    expect(find.text('Confirm 0 fact(s)'), findsOneWidget);
    expect(find.textContaining('No date and time'), findsOneWidget);
  });

  testWidgets('a receipt date can be corrected', (tester) async {
    await pumpReview(tester, draft(facts: [requestFact]));
    await switchTypeTo(tester, 'Receipt');

    expect(fieldText(tester, 'Receipt date'), '2026-10-12',
        reason: 'it starts from the record date');

    await tester.enterText(field('Receipt date'), '2026-10-15');
    await tester.pumpAndSettle();

    expect(fieldText(tester, 'Receipt date'), '2026-10-15');
    expect(find.text('Confirm 1 fact(s)'), findsOneWidget);
  });

  testWidgets('a date does not survive a switch to a type that has none',
      (tester) async {
    await pumpReview(tester, draft(facts: [appointmentFact]));
    await tester.enterText(field('Date'), '21 October');
    await tester.pumpAndSettle();

    await switchTypeTo(tester, 'Note only');
    await switchTypeTo(tester, 'Appointment');

    expect(fieldText(tester, 'Date'), isEmpty,
        reason: 'the date was read from the text and cannot be re-invented');
  });
}
