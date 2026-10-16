import 'package:flutter/material.dart';

import '../api.dart';
import '../profiles.dart';
import '../theme.dart';
import 'review_screen.dart';

class AddRecordScreen extends StatefulWidget {
  const AddRecordScreen({super.key});
  @override
  State<AddRecordScreen> createState() => _AddRecordScreenState();
}

class _AddRecordScreenState extends State<AddRecordScreen> {
  final _title = TextEditingController();
  final _text = TextEditingController();
  DateTime _date = DateTime.now();
  bool _busy = false;
  String? _error;

  String get _iso =>
      '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty || _text.text.trim().length < 3) {
      setState(() => _error = 'Add a title and the record text.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final draft = await Api.preview(
          profiles.selectedId!, _title.text.trim(), _iso, _text.text.trim());
      if (!mounted) return;
      if (draft['duplicate_of'] != null) {
        setState(() => _error = 'This record is already confirmed as ${draft['duplicate_of']}. No duplicate facts were created.');
        return;
      }
      final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ReviewScreen(draft: draft)));
      if (done == true && mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add record')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('New record for ${profiles.selectedName}',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              const Text('Nothing is used in answers until you review and confirm it.',
                  style: TextStyle(color: C.muted)),
              const SizedBox(height: 20),
              TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title', hintText: 'e.g. Clinic visit note')),
              const SizedBox(height: 14),
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () async {
                  final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: DateTime(2100));
                  if (d != null) setState(() => _date = d);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Record date', suffixIcon: Icon(Icons.calendar_today_outlined)),
                  child: Text(_iso),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _text,
                minLines: 6,
                maxLines: 14,
                decoration: const InputDecoration(
                  labelText: 'Record text',
                  alignLabelWithHint: true,
                  hintText: 'Paste the note. Leave a blank line between paragraphs — each paragraph becomes a citable source.',
                ),
              ),
              const SizedBox(height: 10),
              const Row(children: [
                Icon(Icons.upload_file_outlined, size: 16, color: C.muted),
                SizedBox(width: 6),
                Text('PDF / photo upload with OCR — coming next', style: TextStyle(color: C.muted, fontSize: 13)),
              ]),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: C.rose, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _submit,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.fact_check_outlined),
                  label: Text(_busy ? 'Extracting…' : 'Extract & review'),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
