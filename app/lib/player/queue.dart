import 'dart:math';

enum QueueRepeat { off, all, one }

/// Eine Warteschlange: Titel (relative Pfade), aktueller Index und die
/// Position im aktuellen Titel. Jede Warteschlange merkt sich ihren Stand,
/// sodass man zwischen ihnen wechseln kann, ohne etwas zu verlieren.
class PlayQueue {
  PlayQueue({
    required this.id,
    required this.name,
    List<String>? items,
    this.index = 0,
    this.positionMs = 0,
    this.repeat = QueueRepeat.all,
  }) : items = items ?? [];

  final String id;
  String name;
  final List<String> items;
  int index;
  int positionMs;
  QueueRepeat repeat;

  bool get isEmpty => items.isEmpty;
  String? get current =>
      (index >= 0 && index < items.length) ? items[index] : null;

  /// Ersetzt den Inhalt und startet bei [start].
  void replace(List<String> paths, {int start = 0}) {
    items
      ..clear()
      ..addAll(paths);
    index = paths.isEmpty ? 0 : start.clamp(0, paths.length - 1);
    positionMs = 0;
  }

  /// Fügt Titel direkt nach dem aktuellen ein.
  void playNext(List<String> paths) {
    if (items.isEmpty) {
      replace(paths);
      return;
    }
    items.insertAll(index + 1, paths);
  }

  void append(List<String> paths) {
    final wasEmpty = items.isEmpty;
    items.addAll(paths);
    if (wasEmpty) index = 0;
  }

  void removeAt(int i) {
    if (i < 0 || i >= items.length) return;
    items.removeAt(i);
    if (i < index) {
      index--;
    } else if (i == index) {
      positionMs = 0;
      if (index >= items.length) index = max(0, items.length - 1);
    }
  }

  void move(int from, int to) {
    if (from == to || from < 0 || from >= items.length) return;
    final item = items.removeAt(from);
    final target = to.clamp(0, items.length);
    items.insert(target, item);
    if (index == from) {
      index = target;
    } else if (from < index && target >= index) {
      index--;
    } else if (from > index && target <= index) {
      index++;
    }
  }

  /// Mischt alle Titel; der aktuelle Titel kommt an den Anfang.
  void shuffle([Random? rnd]) {
    if (items.length < 2) return;
    final cur = current;
    final rest = [...items];
    if (cur != null) rest.removeAt(index);
    rest.shuffle(rnd);
    items
      ..clear()
      ..addAll([?cur, ...rest]);
    index = 0;
  }

  /// Ersetzt einen umbenannten Pfad (nach Sync oder Scan).
  bool renamePath(String from, String to) {
    var changed = false;
    for (var i = 0; i < items.length; i++) {
      if (items[i] == from) {
        items[i] = to;
        changed = true;
      }
    }
    return changed;
  }

  /// Nächster Index nach dem Ende des aktuellen Titels (null = Ende).
  int? nextIndex({bool manual = false}) {
    if (items.isEmpty) return null;
    if (repeat == QueueRepeat.one && !manual) return index;
    if (index + 1 < items.length) return index + 1;
    return repeat == QueueRepeat.off && !manual ? null : 0;
  }

  int previousIndex() {
    if (items.isEmpty) return 0;
    if (index > 0) return index - 1;
    return repeat == QueueRepeat.off ? 0 : items.length - 1;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'items': items,
    'index': index,
    'position_ms': positionMs,
    'repeat': repeat.name,
  };

  factory PlayQueue.fromJson(Map<String, dynamic> j) => PlayQueue(
    id: j['id'] as String,
    name: j['name'] as String,
    items: (j['items'] as List).cast<String>(),
    index: j['index'] as int? ?? 0,
    positionMs: j['position_ms'] as int? ?? 0,
    repeat: QueueRepeat.values.asNameMap()[j['repeat']] ?? QueueRepeat.all,
  );
}
