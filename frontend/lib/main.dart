import 'package:flutter/material.dart';

import 'screens/shell.dart';
import 'theme.dart';

void main() => runApp(const CareSaathApp());

class CareSaathApp extends StatelessWidget {
  const CareSaathApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'CareSaath',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const Shell(),
      );
}
