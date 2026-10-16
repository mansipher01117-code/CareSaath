import 'package:flutter/material.dart';

import '../profiles.dart';
import '../theme.dart';

/// Create a family member. Name + relation are required; the caregiver is the
/// person who usually handles their appointments.
class CreateProfileScreen extends StatefulWidget {
  const CreateProfileScreen({super.key});
  @override
  State<CreateProfileScreen> createState() => _CreateProfileScreenState();
}

class _CreateProfileScreenState extends State<CreateProfileScreen> {
  final _name = TextEditingController();
  final _caregiver = TextEditingController();
  String _relation = 'Parent';
  bool _busy = false;
  String? _error;

  static const _relations = [
    'Parent', 'Mother', 'Father', 'Grandparent', 'Spouse', 'Child', 'Sibling', 'Myself', 'Other',
  ];

  @override
  void dispose() {
    _name.dispose();
    _caregiver.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await profiles.create(name, _relation, _caregiver.text.trim());
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New profile')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Add a family member', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              const Text(
                'Their records, follow-ups and graph are kept entirely separate from everyone else in the app.',
                style: TextStyle(color: C.muted, height: 1.5),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                onSubmitted: (_) => _save(),
                decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Asha'),
              ),
              const SizedBox(height: 14),
              InputDecorator(
                decoration: const InputDecoration(labelText: 'Relation'),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _relation,
                    isExpanded: true,
                    items: [for (final r in _relations) DropdownMenuItem(value: r, child: Text(r))],
                    onChanged: (v) => setState(() => _relation = v ?? _relation),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _caregiver,
                textCapitalization: TextCapitalization.words,
                onSubmitted: (_) => _save(),
                decoration: const InputDecoration(
                  labelText: 'Caregiver (optional)',
                  hintText: 'Who usually takes them to appointments?',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: C.rose, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 26),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: _busy
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.check_rounded),
                  label: Text(_busy ? 'Creating…' : 'Create profile'),
                ),
              ),
              const SizedBox(height: 14),
              const Row(children: [
                Icon(Icons.lock_outline_rounded, size: 16, color: C.muted),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'There is no sign-in. Everything stays in the FalkorDB instance this app talks to.',
                    style: TextStyle(color: C.muted, fontSize: 13),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}
