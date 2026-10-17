import 'dart:js_interop';

@JS('window.print')
external void _windowPrint();

/// On the web the browser dialog is always there, and its "Save as PDF"
/// destination is what turns the visit sheet into a file.
bool get canPrint => true;

void printPage() => _windowPrint();
