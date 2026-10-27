import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../photos/place_search.dart';

/// Moves a [NativeMap]'s camera from outside it.
class NativeMapController {
  MethodChannel? _channel;

  Future<void> fitAll({bool animated = true}) async =>
      _call('fitAll', animated);

  /// [span] in degrees: 0.05 is a neighbourhood, 1 a region.
  Future<void> focus(double lat, double lng, {double span = 0.05}) =>
      _call('focus', {'lat': lat, 'lng': lng, 'span': span});

  Future<void> _call(String method, Object? args) async {
    try {
      await _channel?.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No map on this platform.
    }
  }
}

/// MapKit's map (`ios/Runner/MapChannel.swift`) with [pins] and a [line].
/// Pins and line go to native in one message when they change, never per
/// frame. Where there's no MapKit (widget tests, other platforms) it is a
/// plain placeholder of the same size.
class NativeMap extends StatefulWidget {
  const NativeMap({
    super.key,
    this.pins = const [],
    this.line,
    this.interactive = true,
    this.fitOnChange = true,
    this.controller,
    this.onPinTap,
    this.onLongPress,
  });

  final List<MapPinData> pins;
  final MapLineData? line;

  /// False: a still map that a scroll view can scroll past.
  final bool interactive;

  /// Zoom to show every pin whenever they change.
  final bool fitOnChange;
  final NativeMapController? controller;
  final ValueChanged<String>? onPinTap;
  final void Function(double lat, double lng)? onLongPress;

  /// Whether MapKit is there to draw it. Overridable for tests.
  @visibleForTesting
  static bool? available;

  static bool get _available =>
      available ??
      (!kIsWeb &&
          Platform.isIOS &&
          !Platform.environment.containsKey('FLUTTER_TEST'));

  @override
  State<NativeMap> createState() => _NativeMapState();
}

class _NativeMapState extends State<NativeMap> {
  MethodChannel? _channel;

  @override
  void didUpdateWidget(NativeMap old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._channel = null;
      widget.controller?._channel = _channel;
    }
    final pinsChanged = !listEquals(old.pins, widget.pins);
    final lineChanged = old.line != widget.line;
    if (pinsChanged || lineChanged) _push(fit: widget.fitOnChange);
  }

  @override
  void dispose() {
    widget.controller?._channel = null;
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _created(int id) {
    final channel = MethodChannel('byo.photos/map/$id');
    _channel = channel;
    widget.controller?._channel = channel;
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'pinTapped':
          if (call.arguments is String) widget.onPinTap?.call(call.arguments);
        case 'longPress':
          final args = call.arguments;
          if (args is Map && args['lat'] is num && args['lng'] is num) {
            widget.onLongPress?.call(
              (args['lat'] as num).toDouble(),
              (args['lng'] as num).toDouble(),
            );
          }
      }
      return null;
    });
    _push(fit: true, animated: false);
  }

  Future<void> _push({required bool fit, bool animated = true}) async {
    final channel = _channel;
    if (channel == null) return;
    try {
      await channel.invokeMethod<void>('setPins', [
        for (final p in widget.pins) p.toMap(),
      ]);
      await channel.invokeMethod<void>('setPolyline', widget.line?.toMap());
      if (fit) await channel.invokeMethod<void>('fitAll', animated);
    } on MissingPluginException {
      // Torn down while sending.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!NativeMap._available) {
      return const ColoredBox(
        key: ValueKey('nativeMapPlaceholder'),
        color: Color(0xFF1C1C1E),
        child: Center(
          child: Icon(CupertinoIcons.map, color: CupertinoColors.systemGrey),
        ),
      );
    }
    return UiKitView(
      viewType: 'byo.photos/map_view',
      creationParams: {'interactive': widget.interactive},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _created,
      gestureRecognizers: widget.interactive
          ? {Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new)}
          : const {},
    );
  }
}
