import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

const _selectedKey = 'caresaath.selected_person_id';

/// The family members this device knows about, and which one the app is
/// currently showing. The selection is remembered in browser/device storage
/// so the app reopens on the same person.
class ProfileStore extends ChangeNotifier {
  List<Json> people = const [];
  String? selectedId;
  bool loading = true;
  String? error;

  Json? get selected {
    for (final p in people) {
      if (p['id'] == selectedId) return p;
    }
    return null;
  }

  String get selectedName => (selected?['name'] ?? '') as String;

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      people = (await Api.people()).cast<Json>();
      final prefs = await SharedPreferences.getInstance();
      final remembered = prefs.getString(_selectedKey);
      final known = people.any((p) => p['id'] == remembered);
      selectedId = known ? remembered : (people.isEmpty ? null : people.first['id'] as String);
      if (!known && selectedId != null) await _remember(selectedId!);
    } catch (e) {
      error = '$e';
      people = const [];
      selectedId = null;
    }
    loading = false;
    notifyListeners();
  }

  Future<void> select(String id) async {
    if (id == selectedId) return;
    selectedId = id;
    await _remember(id);
    notifyListeners();
    refreshAll();
  }

  Future<Json> create(String name, String relation, String? caregiver) async {
    final created = await Api.createPerson(name, relation, caregiver);
    people = [...people, created];
    await select(created['id'] as String);
    notifyListeners();
    return created;
  }

  Future<void> remove(String id) async {
    await Api.deletePerson(id);
    people = [for (final p in people) if (p['id'] != id) p];
    if (selectedId == id) {
      selectedId = people.isEmpty ? null : people.first['id'] as String;
      final prefs = await SharedPreferences.getInstance();
      if (selectedId == null) {
        await prefs.remove(_selectedKey);
      } else {
        await prefs.setString(_selectedKey, selectedId!);
      }
    }
    notifyListeners();
    refreshAll();
  }

  /// Refresh the cached record counts shown next to each name.
  Future<void> refreshCounts() async {
    try {
      people = (await Api.people()).cast<Json>();
      notifyListeners();
    } catch (_) {
      // the screens surface their own errors
    }
  }

  Future<void> _remember(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedKey, id);
  }
}

/// Single app-wide instance, read by every screen.
final profiles = ProfileStore();
