import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api.dart';
import '../profiles.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'create_profile_screen.dart';

/// First screen when no profile is selected: pick a family member, or add the
/// first one.
class ProfilesScreen extends StatelessWidget {
  /// When shown from inside the app (switcher), a profile can be tapped to
  /// switch to it and pop back.
  final bool popOnSelect;
  const ProfilesScreen({super.key, this.popOnSelect = false});

  Future<void> _add(BuildContext context) async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateProfileScreen()),
    );
    if (created == true && popOnSelect && context.mounted) Navigator.of(context).pop();
  }

  Future<void> _delete(BuildContext context, Json p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.paper,
        title: Text('Remove ${p['name']}?'),
        content: Text(
          'This deletes ${p['name']}’s profile and all ${p['records']} confirmed records. '
          'It cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.rose),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await profiles.remove(p['id'] as String);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const _Brand(),
        automaticallyImplyLeading: popOnSelect,
        actions: const [_HealthDot(), SizedBox(width: 16)],
      ),
      body: AnimatedBuilder(
        animation: profiles,
        builder: (context, _) {
          if (profiles.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (profiles.error != null) {
            return ListView(padding: const EdgeInsets.all(24), children: [
              ErrorState(message: profiles.error!),
              const SizedBox(height: 12),
              Center(
                child: OutlinedButton.icon(
                  onPressed: profiles.load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
              ),
            ]);
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 32, 20, 40),
                children: [
                  Text(
                    profiles.people.isEmpty ? 'Who are you caring for?' : 'Family',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    profiles.people.isEmpty
                        ? 'Each family member gets their own records, follow-ups and graph. Nothing is shared between them.'
                        : 'Pick whose records to open. Each profile is kept separate.',
                    style: const TextStyle(color: C.muted, height: 1.5),
                  ),
                  const SizedBox(height: 26),
                  if (profiles.people.isEmpty)
                    const EmptyState(
                      icon: Icons.group_add_outlined,
                      title: 'Add the first family member',
                      body: 'No profiles yet. Create one to start keeping their health records together.',
                    )
                  else
                    for (final p in profiles.people) ...[
                      _ProfileTile(
                        person: p,
                        selected: p['id'] == profiles.selectedId,
                        onTap: () async {
                          await profiles.select(p['id'] as String);
                          if (popOnSelect && context.mounted) Navigator.of(context).pop();
                        },
                        onDelete: () => _delete(context, p),
                      ),
                      const SizedBox(height: 12),
                    ],
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _add(context),
                      icon: const Icon(Icons.person_add_alt_rounded),
                      label: Text(profiles.people.isEmpty
                          ? 'Add the first family member'
                          : 'Add a family member'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final Json person;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _ProfileTile({
    required this.person,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final name = (person['name'] ?? '?').toString();
    final caregiver = (person['caregiver'] ?? '').toString();
    final records = person['records'] ?? 0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Panel(
          border: selected ? C.teal : C.line,
          child: Row(children: [
            Avatar(name: name, selected: selected),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                Text(
                  [
                    person['relation'] ?? '',
                    if (caregiver.isNotEmpty) 'caregiver $caregiver',
                    '$records ${records == 1 ? 'record' : 'records'}',
                  ].join(' · '),
                  style: const TextStyle(color: C.muted, fontSize: 13),
                ),
              ]),
            ),
            if (selected)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.check_circle_rounded, color: C.teal, size: 20),
              ),
            IconButton(
              tooltip: 'Remove profile',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline_rounded, color: C.muted, size: 20),
            ),
          ]),
        ),
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  final String name;
  final bool selected;
  final double radius;
  const Avatar({super.key, required this.name, this.selected = false, this.radius = 24});

  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: radius,
        backgroundColor: selected ? C.tealSoft : C.marigoldSoft,
        child: Text(
          name.trim().isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase(),
          style: TextStyle(
            fontSize: radius * 0.85,
            fontWeight: FontWeight.w800,
            color: selected ? C.teal : C.marigold,
          ),
        ),
      );
}

class _Brand extends StatelessWidget {
  const _Brand();
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: C.teal, borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.favorite_rounded, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Text('CareSaath',
            style: GoogleFonts.fraunces(fontSize: 22, fontWeight: FontWeight.w700, color: C.ink)),
      ]);
}

/// Shows whether the API and FalkorDB are reachable.
class _HealthDot extends StatelessWidget {
  const _HealthDot();
  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
        future: Api.health(),
        builder: (context, snap) {
          final ok = snap.hasData && snap.data!['graph'] == 'ok';
          final label = snap.hasError
              ? 'API offline'
              : (ok ? 'FalkorDB connected' : (snap.hasData ? 'Graph unavailable' : 'Checking…'));
          final color = ok ? C.teal : (snap.hasData || snap.hasError ? C.rose : C.muted);
          return Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
          ]);
        },
      );
}
