import 'package:flutter/material.dart';

import 'profiles.dart';
import 'screens/profiles_screen.dart';
import 'screens/shell.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  profiles.load();
  runApp(const CareSaathApp());
}

class CareSaathApp extends StatelessWidget {
  const CareSaathApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'CareSaath',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const _Root(),
      );
}

/// The app opens on the remembered profile, or on the picker when there is
/// none to open.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: profiles,
        builder: (context, _) {
          if (profiles.loading) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          if (profiles.selectedId == null) return const ProfilesScreen();
          return Shell(key: ValueKey(profiles.selectedId));
        },
      );
}
