import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'player_controller.dart';
import 'queue.dart';
import '../core/music_fs.dart';

/// MPRIS2-Schnittstelle (D-Bus): Medientasten, Mediensteuerung von
/// GNOME/KDE, `playerctl`, KDE Connect usw.
class Mpris {
  Mpris(this.controller);

  final PlayerController controller;
  DBusClient? _client;
  _MprisObject? _object;

  Future<void> start() async {
    if (!Platform.isLinux) return;
    try {
      final client = DBusClient.session();
      final reply = await client.requestName(
        'org.mpris.MediaPlayer2.mync',
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      if (reply != DBusRequestNameReply.primaryOwner &&
          reply != DBusRequestNameReply.alreadyOwner) {
        await client.close();
        return;
      }
      final obj = _MprisObject(controller);
      await client.registerObject(obj);
      _client = client;
      _object = obj;
      controller.addListener(obj.onChange);
    } catch (_) {
      // Keine Session-D-Bus (z. B. in Containern): ohne MPRIS weiter
    }
  }

  Future<void> stop() async {
    final o = _object;
    if (o != null) controller.removeListener(o.onChange);
    await _client?.close();
  }
}

const _root = 'org.mpris.MediaPlayer2';
const _playerIf = 'org.mpris.MediaPlayer2.Player';

class _MprisObject extends DBusObject {
  _MprisObject(this.c) : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  final PlayerController c;
  Map<String, DBusValue> _last = {};
  int _lastPosSec = 0;

  String get _status =>
      c.playing ? 'Playing' : (c.currentTrack == null ? 'Stopped' : 'Paused');
  String get _loop => switch (c.queue.repeat) {
    QueueRepeat.off => 'None',
    QueueRepeat.all => 'Playlist',
    QueueRepeat.one => 'Track',
  };

  DBusValue _metadata() {
    final t = c.currentTrack;
    final m = <String, DBusValue>{
      'mpris:trackid': DBusObjectPath(
        t == null
            ? '/org/mpris/MediaPlayer2/TrackList/NoTrack'
            : '/org/mync/track/${t.fileId.replaceAll('-', '_')}',
      ),
    };
    if (t != null) {
      m['xesam:title'] = DBusString(t.title);
      m['xesam:artist'] = DBusArray.string(
        t.artists.isEmpty ? [t.artist] : t.artists,
      );
      if (t.album != null) m['xesam:album'] = DBusString(t.album!);
      m['xesam:albumArtist'] = DBusArray.string([t.albumArtist]);
      if (t.trackNo != null) m['xesam:trackNumber'] = DBusInt32(t.trackNo!);
      m['xesam:url'] = DBusString(MusicFs.mediaUri(c.library.abs(t.path)));
      final len = c.duration > Duration.zero ? c.duration : t.duration;
      m['mpris:length'] = DBusInt64(len.inMicroseconds);
    }
    return DBusDict.stringVariant(m);
  }

  Map<String, DBusValue> _playerProps() => {
    'PlaybackStatus': DBusString(_status),
    'LoopStatus': DBusString(_loop),
    'Rate': DBusDouble(c.speed),
    'Shuffle': const DBusBoolean(false),
    'Metadata': _metadata(),
    'Volume': DBusDouble(c.volume / 100),
    'Position': DBusInt64(c.position.inMicroseconds),
    'MinimumRate': const DBusDouble(0.25),
    'MaximumRate': const DBusDouble(4),
    'CanGoNext': const DBusBoolean(true),
    'CanGoPrevious': const DBusBoolean(true),
    'CanPlay': DBusBoolean(!c.queue.isEmpty),
    'CanPause': const DBusBoolean(true),
    'CanSeek': const DBusBoolean(true),
    'CanControl': const DBusBoolean(true),
  };

  Map<String, DBusValue> _rootProps() => {
    'CanQuit': const DBusBoolean(false),
    'CanRaise': const DBusBoolean(false),
    'HasTrackList': const DBusBoolean(false),
    'Identity': const DBusString('mync'),
    'DesktopEntry': const DBusString('mync'),
    'SupportedUriSchemes': DBusArray.string(['file']),
    'SupportedMimeTypes': DBusArray.string([
      'audio/mpeg',
      'audio/flac',
      'audio/ogg',
      'audio/opus',
      'audio/mp4',
      'audio/x-wav',
    ]),
  };

  /// Meldet geänderte Eigenschaften (ohne Position, die fragen Clients ab).
  void onChange() {
    final now = _playerProps()..remove('Position');
    final changed = <String, DBusValue>{};
    for (final e in now.entries) {
      if (_last[e.key] != e.value) changed[e.key] = e.value;
    }
    _last = now;
    if (changed.isNotEmpty) {
      unawaited(emitPropertiesChanged(_playerIf, changedProperties: changed));
    }
    // Sprünge in der Position (Seek) melden
    final sec = c.position.inSeconds;
    if ((sec - _lastPosSec).abs() > 2) {
      unawaited(
        emitSignal(_playerIf, 'Seeked', [DBusInt64(c.position.inMicroseconds)]),
      );
    }
    _lastPosSec = sec;
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface == _root) {
      return DBusMethodSuccessResponse(); // Raise, Quit: nicht unterstützt
    }
    if (call.interface != _playerIf) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (call.name) {
      case 'Play':
        if (!c.playing) await c.playPause();
      case 'Pause':
        if (c.playing) await c.playPause();
      case 'PlayPause':
        await c.playPause();
      case 'Stop':
        if (c.playing) await c.playPause();
        await c.seek(Duration.zero);
      case 'Next':
        await c.next();
      case 'Previous':
        await c.previous();
      case 'Seek':
        await c.seekRelative(Duration(microseconds: call.values[0].asInt64()));
      case 'SetPosition':
        await c.seek(Duration(microseconds: call.values[1].asInt64()));
      case 'OpenUri':
        break;
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
    return DBusMethodSuccessResponse();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final props = interface == _root
        ? _rootProps()
        : (interface == _playerIf ? _playerProps() : null);
    final v = props?[name];
    if (v == null) return DBusMethodErrorResponse.unknownProperty();
    return DBusGetPropertyResponse(v);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface == _root) return DBusGetAllPropertiesResponse(_rootProps());
    if (interface == _playerIf) {
      return DBusGetAllPropertiesResponse(_playerProps());
    }
    return DBusGetAllPropertiesResponse({});
  }

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    if (interface != _playerIf) {
      return DBusMethodErrorResponse.unknownProperty();
    }
    switch (name) {
      case 'Volume':
        await c.setVolume((value.asDouble() * 100).clamp(0, 100));
      case 'Rate':
        await c.setSpeed(value.asDouble().clamp(0.25, 4));
      case 'LoopStatus':
        await c.setRepeat(switch (value.asString()) {
          'Track' => QueueRepeat.one,
          'Playlist' => QueueRepeat.all,
          _ => QueueRepeat.off,
        });
      case 'Shuffle':
        if (value.asBoolean()) await c.shuffleQueue();
      default:
        return DBusMethodErrorResponse.propertyReadOnly();
    }
    return DBusMethodSuccessResponse();
  }

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      _root,
      methods: [DBusIntrospectMethod('Raise'), DBusIntrospectMethod('Quit')],
      properties: [
        for (final k in _rootProps().keys)
          DBusIntrospectProperty(
            k,
            _rootProps()[k]!.signature,
            access: DBusPropertyAccess.read,
          ),
      ],
    ),
    DBusIntrospectInterface(
      _playerIf,
      methods: [
        for (final m in [
          'Next',
          'Previous',
          'Pause',
          'PlayPause',
          'Stop',
          'Play',
        ])
          DBusIntrospectMethod(m),
        DBusIntrospectMethod(
          'Seek',
          args: [
            DBusIntrospectArgument(
              DBusSignature('x'),
              DBusArgumentDirection.in_,
              name: 'Offset',
            ),
          ],
        ),
        DBusIntrospectMethod(
          'SetPosition',
          args: [
            DBusIntrospectArgument(
              DBusSignature('o'),
              DBusArgumentDirection.in_,
              name: 'TrackId',
            ),
            DBusIntrospectArgument(
              DBusSignature('x'),
              DBusArgumentDirection.in_,
              name: 'Position',
            ),
          ],
        ),
        DBusIntrospectMethod(
          'OpenUri',
          args: [
            DBusIntrospectArgument(
              DBusSignature('s'),
              DBusArgumentDirection.in_,
              name: 'Uri',
            ),
          ],
        ),
      ],
      signals: [
        DBusIntrospectSignal(
          'Seeked',
          args: [
            DBusIntrospectArgument(
              DBusSignature('x'),
              DBusArgumentDirection.out,
              name: 'Position',
            ),
          ],
        ),
      ],
      properties: [
        for (final k in _playerProps().keys)
          DBusIntrospectProperty(
            k,
            _playerProps()[k]!.signature,
            access:
                const {'Volume', 'Rate', 'LoopStatus', 'Shuffle'}.contains(k)
                ? DBusPropertyAccess.readwrite
                : DBusPropertyAccess.read,
          ),
      ],
    ),
  ];
}
