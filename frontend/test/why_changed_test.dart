// "What changed" says an item moved; it never showed what moved it. The Why?
// sheet puts both ends of the change side by side — the record that asked for
// the item and the record whose receipt settled it — out of the span ids the
// change record already carries. An item nothing touched says exactly that.
import 'package:caresaath/api.dart';
import 'package:caresaath/screens/today_screen.dart';
import 'package:caresaath/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Json request() => {
      'span_id': 'D01-P1',
      'doc_id': 'D01',
      'doc_title': 'Physio referral note',
      'date': '2026-10-12',
      'text': 'Please bring the knee physio referral to the next appointment.',
    };

Json receipt() => {
      'span_id': 'D02-P1',
      'doc_id': 'D02',
      'doc_title': 'Front desk slip',
      'date': '2026-10-15',
      'text': 'The knee physio referral was received at the front desk.',
    };

Json change({bool withSides = true, bool withReceipt = true}) => {
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
          if (withSides) 'requested_by': request(),
          if (withSides && withReceipt) 'receipt': receipt(),
          if (withSides && !withReceipt) 'receipt': null,
          if (withSides)
            'path': [
              'Person:Nilofer',
              'Document:D01',
              'Span:D01-P1',
              'FollowUp:Knee physio referral',
              'Receipt:2026-10-15',
              'Span:D02-P1',
              'Document:D02',
            ],
        }
      ],
      'added': const <Json>[],
      'unchanged': [
        {
          'id': 'fu:old_xray',
          'label': 'Old X-ray film',
          'status': 'receipt_not_documented',
          if (withSides) 'requested_by': request(),
        }
      ],
    };

Future<void> pump(WidgetTester tester, Json c) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ChangeCard(change: c)))));
  await tester.pumpAndSettle();
}

Future<void> openWhy(WidgetTester tester) async {
  await tester.tap(find.text('Why?'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('only the item that moved offers Why?', (tester) async {
    await pump(tester, change());

    // One changed item, one unchanged item, one button.
    expect(find.text('Why?'), findsOneWidget);
  });

  testWidgets('the sheet puts the request and the receipt side by side', (tester) async {
    await pump(tester, change());
    await openWhy(tester);

    expect(find.text('WHY THIS CHANGED'), findsOneWidget);
    expect(find.text('Knee physio referral'), findsWidgets);
    expect(find.text('Receipt not documented → Receipt documented'), findsOneWidget);

    // Left: the record that asked for it, with its own paragraph.
    expect(find.text('ASKED FOR IN'), findsOneWidget);
    expect(find.text('D01 · Physio referral note'), findsOneWidget);
    expect(find.text('2026-10-12'), findsOneWidget);
    expect(find.textContaining('Please bring the knee physio referral'), findsOneWidget);

    // Right: the record whose receipt settled it.
    expect(find.text('RECEIPT DOCUMENTED IN'), findsOneWidget);
    expect(find.text('D02 · Front desk slip'), findsOneWidget);
    expect(find.textContaining('was received at the front desk'), findsOneWidget);
  });

  testWidgets('both sides link back to the original span', (tester) async {
    await pump(tester, change());
    await openWhy(tester);

    final chips = tester.widgetList<SourceChip>(find.byType(SourceChip));
    expect(chips.map((c) => c.spanId), containsAll(<String>['D01-P1', 'D02-P1']));
  });

  testWidgets('the sheet shows the graph path between the two records', (tester) async {
    await pump(tester, change());
    await openWhy(tester);

    expect(find.text('THE PATH BETWEEN THEM'), findsOneWidget);
    expect(find.text('FollowUp:Knee physio referral'), findsOneWidget);
    expect(find.text('Span:D02-P1'), findsOneWidget);
  });

  testWidgets('an item with no receipt yet says so instead of showing a blank card',
      (tester) async {
    await pump(tester, change(withReceipt: false));
    await openWhy(tester);

    expect(find.text('No confirmed record documents a receipt yet.'), findsOneWidget);
    expect(find.text('D01 · Physio referral note'), findsOneWidget);
  });

  testWidgets('an untouched item says no new evidence touched it, with its source',
      (tester) async {
    await pump(tester, change());

    expect(find.text('No new evidence touched this item'), findsOneWidget);
    // Its own source, from the record that first asked for it.
    final chips = tester.widgetList<SourceChip>(find.byType(SourceChip));
    expect(chips.map((c) => c.spanId), contains('D01-P1'));
  });

  testWidgets('a backend that sends no sides still renders the card', (tester) async {
    await pump(tester, change(withSides: false));

    expect(find.text('Knee physio referral'), findsOneWidget);
    expect(find.text('No new evidence touched this item'), findsOneWidget);

    await openWhy(tester);
    // Nothing to show on either side, and it says so twice rather than lying.
    expect(find.text('No confirmed record asks for this item.'), findsOneWidget);
    expect(find.text('No confirmed record documents a receipt yet.'), findsOneWidget);
    expect(find.text('THE PATH BETWEEN THEM'), findsNothing);
  });
}
