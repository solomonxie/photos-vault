import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../storage/note.dart';
import 'link_text.dart';

/// An album's notes: a list under a heading, tap one to edit or delete it,
/// + to add. The same for a hidden album (sealed [NoteBook]) and an
/// ordinary one. Links in a note open in the system browser.
class AlbumNotes extends StatefulWidget {
  const AlbumNotes({super.key, required this.book});

  final NoteBook book;

  @override
  State<AlbumNotes> createState() => _AlbumNotesState();
}

class _AlbumNotesState extends State<AlbumNotes> {
  List<Note> _notes = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final notes = await widget.book.list();
    if (mounted) setState(() => _notes = notes);
  }

  /// Add with no [note]; edit or delete with one.
  Future<void> _edit([Note? note]) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: note?.text ?? '');
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1C1C1E),
            borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: Text(l10n.actionCancel),
                      ),
                      Expanded(
                        child: Text(
                          note == null
                              ? l10n.hiddenNotesAdd
                              : l10n.hiddenNotesEdit,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: CupertinoColors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(sheetContext).pop('save'),
                        child: Text(l10n.settingsSaveButton),
                      ),
                    ],
                  ),
                  CupertinoTextField(
                    key: const ValueKey('hiddenNoteField'),
                    controller: controller,
                    autofocus: true,
                    minLines: 4,
                    maxLines: 10,
                    placeholder: l10n.hiddenNotesPlaceholder,
                  ),
                  if (note != null)
                    CupertinoButton(
                      onPressed: () => Navigator.of(sheetContext).pop('delete'),
                      child: Text(
                        l10n.actionDelete,
                        style: const TextStyle(
                          color: CupertinoColors.systemRed,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (action == 'save' && text.isNotEmpty) {
      await widget.book.save(text, existing: note);
    } else if (action == 'delete' && note != null) {
      await widget.book.delete(note.id);
    } else {
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    const grey = TextStyle(fontSize: 12, color: CupertinoColors.systemGrey);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.hiddenNotesTitle.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 13,
                    letterSpacing: 0.4,
                    color: CupertinoColors.systemGrey,
                  ),
                ),
              ),
              CupertinoButton(
                key: const ValueKey('hiddenNoteAdd'),
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                onPressed: _edit,
                child: const Icon(CupertinoIcons.add_circled, size: 22),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_notes.isEmpty)
            Text(l10n.hiddenNotesEmpty, style: grey)
          else
            for (final note in _notes)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _edit(note),
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinkText(
                        note.text,
                        maxLines: 6,
                        style: const TextStyle(
                          fontSize: 15,
                          color: CupertinoColors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        DateFormat.yMMMd().add_jm().format(note.updatedAt),
                        style: grey,
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
