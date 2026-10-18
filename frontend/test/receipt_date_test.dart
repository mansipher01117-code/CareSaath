// The receipt line on Today used to print whatever the Receipt node carried,
// which was the document's date: "The vitamin D report was received at the
// clinic on 20 November 2026" read back as a receipt on 17 October 2026, the
// day the note was typed up. The date is now the event's, and the line says
// when it is only the document's standing in.
import 'package:caresaath/screens/today_screen.dart';
import 'package:caresaath/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('prettyDate', () {
    test('an ISO date reads as a date a person would say', () {
      expect(prettyDate('2026-11-20'), '20 Nov 2026');
      expect(prettyDate('2026-01-03'), '3 Jan 2026');
    });

    test('anything that is not an ISO date is left exactly as it is', () {
      expect(prettyDate(''), '');
      expect(prettyDate(null), '');
      expect(prettyDate('last Tuesday'), 'last Tuesday');
      expect(prettyDate('2026-13-20'), '2026-13-20');
    });
  });

  group('receiptLine', () {
    test('shows the event date the sentence gave', () {
      expect(
        receiptLine({
          'date': '2026-11-20',
          'date_source': 'sentence',
          'doc_title': 'Clinic front-desk note',
        }),
        'Receipt recorded 20 Nov 2026 · Clinic front-desk note',
      );
    });

    test('says so when the date is only the document date', () {
      expect(
        receiptLine({
          'date': '2026-10-17',
          'date_source': 'document',
          'doc_title': 'Clinic front-desk note',
        }),
        'Receipt recorded 17 Oct 2026 (document date) · Clinic front-desk note',
      );
    });

    test('a date the reviewer typed is not called the document date', () {
      expect(receiptLine({'date': '2026-11-20', 'date_source': 'edited'}),
          'Receipt recorded 20 Nov 2026');
    });

    test('claims no date when the receipt has none', () {
      expect(receiptLine({'date': '', 'doc_title': 'Clinic front-desk note'}),
          'Receipt recorded · Clinic front-desk note');
    });
  });
}
