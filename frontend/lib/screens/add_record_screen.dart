import 'package:file_picker/file_picker.dart';
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

  /// The file being read, while it is being read. A scan goes to Gemini to be
  /// transcribed, so this is the one wait in the app worth narrating.
  String? _reading;

  /// What can be read: a text PDF directly, anything else off the picture.
  static const _extensions = ['pdf', 'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'];

  String get _iso =>
      '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty || _text.text.trim().length < 3) {
      setState(() => _error = 'Add a title and the record text.');
      return;
    }
    await _draft(() => Api.preview(
        profiles.selectedId!, _title.text.trim(), _iso, _text.text.trim()));
  }

  /// Pick a PDF or a photo and let the backend read the text off it. The
  /// result is the same draft a paste produces, so it goes to the same place.
  Future<void> _upload() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Choose a record to read',
      type: FileType.custom,
      allowedExtensions: _extensions,
    );
    if (file == null) return;  // the picker was cancelled
    // file_picker 13 reads bytes on demand instead of up front, which is also
    // the only way to get them on the web.
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      setState(() => _error = '${file.name} came back empty. Try picking it again.');
      return;
    }
    // A record needs a title and the file already has a name, so an untitled
    // upload is titled after the file rather than refused for it.
    final title = _title.text.trim().isEmpty
        ? file.name.replaceAll(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '')
        : _title.text.trim();
    setState(() => _reading = file.name);
    await _draft(() =>
        Api.uploadRecord(profiles.selectedId!, title, _iso, file.name, bytes));
    if (mounted) setState(() => _reading = null);
  }

  /// One way to the Review screen, whether the text was pasted or read off a
  /// file: the same duplicate check, the same errors, the same next screen.
  Future<void> _draft(Future<Json> Function() make) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final draft = await make();
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
              const SizedBox(height: 14),
              Row(children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _upload,
                  icon: const Icon(Icons.upload_file_outlined, size: 18),
                  label: const Text('Upload PDF / photo'),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('A PDF with a text layer is read directly; a photo or a scan '
                      'is transcribed, and you check it on the next screen.',
                      style: TextStyle(color: C.muted, fontSize: 12.5, height: 1.4)),
                ),
              ]),
              if (_reading != null) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(color: C.teal),
                const SizedBox(height: 6),
                Text('Reading $_reading…',
                    style: const TextStyle(color: C.muted, fontSize: 13)),
              ],
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
