// The sheet somebody actually carries into the clinic. It may only ever say
// what the confirmed records say: every line carries the span it came from and
// the words that say it, an item with no receipt is listed as still open
// rather than quietly dropped, and the footer never goes missing.
import 'package:caresaath/api.dart';
import 'package:caresaath/screens/visit_prep_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json person({List<Json>? appointments}) => {
      'id': 'nilofer',
      'name': 'Nilofer',
      'relation': 'Mother',
      'caregiver': 'Zoya',
      'records': 2,
      'appointments': appointments ??
          [
            {
              'date': '20 October',
              'time': '10:00 AM',
              'year': '2026',
              'on': '2026-10-20',
              'upcoming': true,
              'sources': [
                {
                  'span_id': 'D01-P2',
                  'doc_id': 'D01',
                  'text': 'Appointment confirmed for 20 October at 10:00 AM.',
                }
              ],
            }
          ],
    };

Json pendingItem() => {
      'id': 'fu:old_xray',
      'item': 'old_xray_film',
      'label': 'Old X-ray film',
      'status': 'receipt_not_documented',
      'requested_by': [
        {
          'span_id': 'D01-P3',
          'doc_id': 'D01',
          'doc_title': 'Physio referral note',
          'date': '2026-10-12',
          'text': 'Please also bring the old X-ray film so the surgeon can compare.',
        }
      ],
      'receipts': const <Json>[],
      'path': const <String>[],
    };

Json documentedItem() => {
      'id': 'fu:knee_physio_referral',
      'item': 'knee_physio_referral',
      'label': 'Knee physio referral',
      'status': 'receipt_documented',
      'requested_by': [
        {
          'span_id': 'D01-P1',
          'doc_id': 'D01',
          'doc_title': 'Physio referral note',
          'date': '2026-10-12',
          'text': 'Please bring the knee physio referral to the next appointment.',
        }
      ],
      'receipts': [
        {
          'span_id': 'D02-P1',
          'doc_id': 'D02',
          'doc_title': 'Front desk slip',
          'date': '2026-10-15',
          'text': 'The knee physio referral was received at the front desk.',
        }
      ],
      'path': const <String>[],
    };

Future<void> pump(WidgetTester tester, {Json? p, List<Json> items = const []}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: VisitPrepSheet(person: p ?? person(), items: items),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the sheet names the person and the next appointment', (tester) async {
    await pump(tester, items: [pendingItem(), documentedItem()]);

    expect(find.text('Nilofer'), findsOneWidget);
    expect(find.text('Mother · caregiver Zoya'), findsOneWidget);
    expect(find.text('20 October 2026 · 10:00 AM'), findsOneWidget);
    expect(find.textContaining('D01-P2'), findsOneWidget);
  });

  testWidgets('what is still open and what is documented are kept apart',
      (tester) async {
    await pump(tester, items: [pendingItem(), documentedItem()]);

    expect(find.text('STILL TO CLARIFY'), findsOneWidget);
    expect(find.text('ALREADY DOCUMENTED'), findsOneWidget);
    expect(find.text('Old X-ray film'), findsOneWidget);
    expect(find.text('Knee physio referral'), findsOneWidget);
    expect(find.text('No receipt in the confirmed records yet'), findsOneWidget);
  });

  testWidgets('a documented item carries the date its receipt was recorded',
      (tester) async {
    await pump(tester, items: [documentedItem()]);

    expect(find.text('Receipt recorded 2026-10-15'), findsOneWidget);
  });

  testWidgets('every line carries its span id and a quote from that span',
      (tester) async {
    await pump(tester, items: [pendingItem(), documentedItem()]);

    // The open item quotes the request; the documented one quotes the receipt.
    expect(
        find.textContaining('D01-P3 · Physio referral note · 2026-10-12'), findsOneWidget);
    expect(find.textContaining('bring the old X-ray film'), findsOneWidget);
    expect(find.textContaining('D02-P1 · Front desk slip · 2026-10-15'), findsOneWidget);
    expect(find.textContaining('received at the front desk'), findsOneWidget);
  });

  testWidgets('the footer is always on the sheet', (tester) async {
    await pump(tester);
    expect(find.text(VisitPrepSheet.footer), findsOneWidget);
    expect(VisitPrepSheet.footer,
        'Generated from confirmed records only. Not medical advice.');
  });

  testWidgets('an empty profile says what is missing rather than printing blanks',
      (tester) async {
    await pump(tester, p: person(appointments: const []));

    expect(find.text('No confirmed record names an appointment.'), findsOneWidget);
    expect(find.text('Nothing is waiting on a receipt.'), findsOneWidget);
    expect(find.text('No receipt is documented yet.'), findsOneWidget);
    expect(find.text(VisitPrepSheet.footer), findsOneWidget);
  });

  testWidgets('an appointment with no year says so instead of inventing one',
      (tester) async {
    await pump(tester, p: person(appointments: [
      {
        'date': '20 October',
        'time': '10:00 AM',
        'year': '',
        'on': '',
        'upcoming': false,
        'sources': const <Json>[],
      }
    ]));

    expect(find.text('20 October · 10:00 AM'), findsOneWidget);
    expect(find.text('Year not stated in the record'), findsOneWidget);
  });

  testWidgets('a long paragraph is quoted short, not in full', (tester) async {
    final long = 'x' * 400;
    final item = pendingItem();
    (item['requested_by'] as List)[0]['text'] = long;
    await pump(tester, items: [item]);

    expect(find.textContaining(long), findsNothing);
    expect(find.textContaining('…'), findsOneWidget);
  });
}
