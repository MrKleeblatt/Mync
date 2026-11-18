import 'dart:io';

import 'package:flutter/material.dart';

import '../library/track.dart';
import 'scope.dart';

/// Coverbild eines Titels (eingebettet oder aus dem Ordner), sonst ein Platzhalter.
class CoverArt extends StatefulWidget {
  const CoverArt({
    super.key,
    required this.track,
    this.size = 48,
    this.radius = 6,
  });

  final Track? track;
  final double size;
  final double radius;

  @override
  State<CoverArt> createState() => _CoverArtState();
}

class _CoverArtState extends State<CoverArt> {
  Future<String?>? _future;
  String? _forPath;

  void _resolve() {
    final t = widget.track;
    if (t?.path == _forPath && _future != null) return;
    _forPath = t?.path;
    _future = t == null ? Future.value(null) : context.library.coverFor(t);
  }

  @override
  Widget build(BuildContext context) {
    _resolve();
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      child: Icon(
        Icons.music_note,
        size: widget.size * 0.5,
        color: scheme.onSecondaryContainer,
      ),
    );
    return FutureBuilder<String?>(
      future: _future,
      builder: (context, snap) {
        final path = snap.data;
        if (path == null) return placeholder;
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: Image.file(
            File(path),
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
            cacheWidth: (widget.size * MediaQuery.devicePixelRatioOf(context))
                .round(),
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          ),
        );
      },
    );
  }
}
