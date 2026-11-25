// Logbuch ansehen (wie bei Kassenbon): neueste Einträge oben, nach Art
// filtern, kopieren, leeren. Lange Einträge (Stacktraces) zum Aufklappen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../log.dart';

enum _Filter { all, info, network, problems }

void openLogPage(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => LogPage()));

class LogPage extends StatefulWidget {
  LogPage({super.key, AppLog? log}) : log = log ?? appLog;
  final AppLog log;

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  var _filter = _Filter.all;
  String? _copied;

  bool _shown(LogEntry e) => switch (_filter) {
    _Filter.all => true,
    _Filter.info => e.level == LogLevel.info,
    _Filter.network => e.level == LogLevel.network,
    _Filter.problems =>
      e.level == LogLevel.warning || e.level == LogLevel.error,
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.log,
    builder: (context, _) {
      final all = widget.log.entries;
      final shown = all.where(_shown).toList().reversed.toList();
      final t = Theme.of(context).textTheme;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Logbuch'),
          actions: [
            IconButton(
              tooltip: 'Kopieren',
              icon: const Icon(Icons.copy_all_outlined),
              onPressed: all.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(
                        ClipboardData(text: widget.log.text),
                      );
                      setState(() => _copied = '${all.length} kopiert');
                    },
            ),
            IconButton(
              tooltip: 'Leeren',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: all.isEmpty ? null : widget.log.clear,
            ),
          ],
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<_Filter>(
                        segments: [
                          const ButtonSegment(
                            value: _Filter.all,
                            label: Text('Alle'),
                            icon: Icon(Icons.list),
                          ),
                          const ButtonSegment(
                            value: _Filter.info,
                            label: Text('Info'),
                            icon: Icon(Icons.info_outline),
                          ),
                          const ButtonSegment(
                            value: _Filter.network,
                            label: Text('Netz'),
                            icon: Icon(Icons.swap_vert),
                          ),
                          ButtonSegment(
                            value: _Filter.problems,
                            label: Text('${widget.log.problems}'),
                            icon: const Icon(Icons.warning_amber_outlined),
                          ),
                        ],
                        selected: {_filter},
                        showSelectedIcon: false,
                        onSelectionChanged: (s) =>
                            setState(() => _filter = s.first),
                      ),
                      if (_copied != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(_copied!, style: t.bodySmall),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: shown.isEmpty
                      ? Center(
                          child: Text('Keine Einträge', style: t.bodyMedium),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: shown.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, indent: 16),
                          itemBuilder: (context, i) => _EntryTile(shown[i]),
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Ein Eintrag: Uhrzeit und Art farbig, lange Meldungen zum Aufklappen.
class _EntryTile extends StatefulWidget {
  const _EntryTile(this.entry);
  final LogEntry entry;

  @override
  State<_EntryTile> createState() => _EntryTileState();
}

class _EntryTileState extends State<_EntryTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final c = Theme.of(context).colorScheme;
    final (icon, color) = switch (e.level) {
      LogLevel.info => (Icons.info_outline, c.onSurfaceVariant),
      LogLevel.network => (Icons.swap_vert, c.primary),
      LogLevel.warning => (Icons.warning_amber_outlined, c.tertiary),
      LogLevel.error => (Icons.error_outline, c.error),
    };
    final long = e.message.contains('\n') || e.message.length > 160;
    String two(int n) => n.toString().padLeft(2, '0');
    final time =
        '${two(e.time.hour)}:${two(e.time.minute)}:${two(e.time.second)}';
    return InkWell(
      onTap: long ? () => setState(() => _open = !_open) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Text(
              time,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: c.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                e.message,
                minLines: 1,
                maxLines: _open ? null : 3,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            if (long)
              Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18),
          ],
        ),
      ),
    );
  }
}
