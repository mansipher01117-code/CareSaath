/// The browser's print dialog, which is also how a page is saved as a PDF.
///
/// Resolved at compile time: the web build gets the real `window.print()`, and
/// any other target gets a stub that reports it cannot print. Nothing else in
/// the app imports `dart:js_interop`, so nothing else stops compiling off the
/// web.
library;

export 'printing_stub.dart' if (dart.library.js_interop) 'printing_web.dart';
