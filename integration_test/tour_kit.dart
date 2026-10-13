// Shared by the simulator tours: fakes for the native sheets a test can't
// tap, an error recorder, and a crawler that taps everything it can see.

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/upload/signing.dart';

const prefix = 'photos-vault/';

Uint8List jpeg(int w, int h, int r, int g, int b) => img.encodeJpg(
  img.Image(width: w, height: h)..clear(img.ColorRgb8(r, g, b)),
);

Future<void> waitForPhotos() async {
  var state = PermissionState.notDetermined;
  for (var i = 0; i < 120 && !state.isAuth; i++) {
    state = await PhotoManager.getPermissionState(
      requestOption: const PermissionRequestOption(),
    );
    if (!state.isAuth) await Future<void>.delayed(const Duration(seconds: 1));
  }
  expect(state.isAuth, isTrue, reason: 'grant Photos to the app first');
}

Future<void> put(S3BackupTarget target, String key, List<int> bytes) async {
  final r = await http.put(
    await presignPutUrl(target: target, key: key),
    body: bytes,
  );
  expect(r.statusCode, 200, reason: 'PUT $key');
}

/// A bucket of its own, configured as the app's only target.
Future<S3BackupTarget> freshTarget(String name) async {
  await const FlutterSecureStorage().deleteAll();
  final bucket = '$name-${DateTime.now().millisecondsSinceEpoch}';
  expect(
    (await http.put(Uri.https('localhost:9443', '/$bucket'))).statusCode,
    200,
  );
  return BackupTargetsStore().add(
    accessKeyId: 'sim',
    secretAccessKey: 'sim',
    region: 'us-east-1',
    bucket: bucket,
    prefix: prefix,
  );
}

/// Utilities' Hidden row through to the album behind [code]: past the
/// few-decoys warning and the first-time passphrase, then the keypad.
Future<bool> openHidden(Crawler nav, String code) async {
  final t = nav.t;
  if (!await nav.tapWhenFound(find.text('Hidden'))) return false;
  for (var i = 0; i < 4; i++) {
    if (find.text('Private photos').evaluate().isNotEmpty) {
      await t.enterText(
        find.byType(CupertinoTextField).first,
        'correct horse battery',
      );
      await t.pump();
      await t.tap(find.text('Continue').last);
      await nav.settle(10);
      continue;
    }
    if (find.text('Continue').hitTestable().evaluate().isNotEmpty) {
      await t.tap(find.text('Continue').hitTestable().first);
      await nav.settle();
      continue;
    }
    break;
  }
  for (final digit in code.split('')) {
    final key = find.text(digit).hitTestable();
    if (key.evaluate().isEmpty) {
      say('no keypad for $code');
      return false;
    }
    await t.tap(key.last);
    await t.pump(const Duration(milliseconds: 120));
  }
  await nav.settle(10);
  nav.problems.check();
  return true;
}

void say(String line) => debugPrint('TOUR| $line');

/// Answers the channels behind system UI nothing here can tap (the Photos
/// delete prompt, file picker, share sheet, Safari) and passes the rest on.
class NativeFakes {
  NativeFakes(this.tester);

  final WidgetTester tester;

  /// What the Photos delete prompt answers.
  var acceptDelete = true;
  final deletePrompts = <List<String>>[];
  final calls = _Log();

  static const _methods = StandardMethodCodec();

  TestDefaultBinaryMessenger get _messenger =>
      tester.binding.defaultBinaryMessenger;

  void install() {
    _messenger.allMessagesHandler = (channel, mock, message) {
      if (channel == 'com.fluttercandies/photo_manager' && message != null) {
        final call = _methods.decodeMethodCall(message);
        switch (call.method) {
          case 'deleteWithIds':
            final ids = ((call.arguments as Map)['ids'] as List).cast<String>();
            deletePrompts.add(ids);
            calls.add('photos.delete ${ids.length}');
            return Future.value(
              _methods.encodeSuccessEnvelope(acceptDelete ? ids : <String>[]),
            );
          case 'presentLimited':
            calls.add('photos.presentLimited');
            return Future.value(_methods.encodeSuccessEnvelope(null));
        }
      }
      if (channel.contains('filepicker')) {
        calls.add('picker ${_name(message)}');
        return Future.value(_methods.encodeSuccessEnvelope(null));
      }
      if (channel == 'dev.fluttercommunity.plus/share') {
        calls.add('share ${_name(message)}');
        return Future.value(
          _methods.encodeSuccessEnvelope(
            'dev.fluttercommunity.plus/share/unavailable',
          ),
        );
      }
      if (channel.startsWith('dev.flutter.pigeon.url_launcher_ios')) {
        calls.add('url ${channel.split('.').last}');
        // [LaunchResult.success] in pigeon's codec.
        return Future.value(
          ByteData.sublistView(Uint8List.fromList([12, 1, 129, 3, 0, 0, 0, 0])),
        );
      }
      return _messenger.delegate.send(channel, message);
    };
  }

  String _name(ByteData? message) {
    if (message == null) return '';
    try {
      return _methods.decodeMethodCall(message).method;
    } catch (_) {
      return '?';
    }
  }

  void uninstall() => _messenger.allMessagesHandler = null;
}

/// Every FlutterError (overflows included) while installed, plus whatever
/// the binding caught.
class _Log {
  final lines = <String>[];
  void add(String line) {
    say('native $line');
    lines.add(line);
  }
}

class Problems {
  Problems(this.tester);

  final WidgetTester tester;
  final list = <String>[];
  void Function(FlutterErrorDetails)? _previous;
  String where = 'start';

  void install() {
    _previous = FlutterError.onError;
    FlutterError.onError = (details) {
      // The whole report once, for errors whose own text says little.
      debugPrint(
        'TOUR| DETAIL ${details.toString().split('\n').take(40).join('\nTOUR| DETAIL ')}',
      );
      final text = details.exceptionAsString().split('\n').take(6).join(' | ');
      final source = RegExp(r'(package:photos_vault|/lib/)[^ )]+');
      final stack = [
        ...source
            .allMatches(details.toString())
            .map((m) => m.group(0)!)
            .take(2),
        ...?details.stack
            ?.toString()
            .split('\n')
            .where((l) => l.contains('package:photos_vault'))
            .take(4),
      ].join(' <- ');
      _add('$text @ $stack');
    };
  }

  void uninstall() => FlutterError.onError = _previous;

  void check() {
    final e = tester.takeException();
    if (e != null) _add('uncaught: $e');
  }

  void _add(String message) {
    final line = '[$where] $message';
    say('PROBLEM $line');
    list.add(line);
  }
}

class _Candidate {
  _Candidate(this.sig, this.center, {this.longPress = false});
  final String sig;
  final Offset center;
  final bool longPress;
}

/// Taps every control on every screen it can reach, pops back after each,
/// and reopens a screen that closed itself to carry on.
class Crawler {
  Crawler(this.t, this.problems, {this.deny = const [], this.maxDepth = 6});

  final WidgetTester t;
  final Problems problems;

  /// Labels never tapped: actions that would leave nothing to crawl.
  final List<Pattern> deny;
  final int maxDepth;
  final visited = <String>{};
  final everVisited = <String>{};
  final spinners = <String>{};

  /// Lets screens already crawled be crawled again from a new place.
  void newPhase() {
    everVisited.addAll(visited);
    visited.clear();
  }

  final skipped = <String>{};
  var taps = 0;
  var shots = 0;

  NavigatorState get _nav =>
      t.state<NavigatorState>(find.byType(Navigator).first);

  Route<dynamic> top() {
    late Route<dynamic> route;
    _nav.popUntil((r) {
      route = r;
      return true;
    });
    return route;
  }

  Future<void> settle([int frames = 6]) async {
    for (var i = 0; i < frames; i++) {
      await t.pump(Duration(milliseconds: i < 3 ? 50 : 200));
    }
  }

  /// Pages are one screen whatever they show; popups are told apart by
  /// their first line.
  static String _kindKey(String name) =>
      name.startsWith('page:') ? name.split(' ').first : name;

  /// The screen widget a route shows, for naming it.
  String describe(Route<dynamic> route) {
    final context = route is ModalRoute ? route.subtreeContext : null;
    if (context == null) return route.runtimeType.toString();
    String? screen;
    final texts = <String>[];
    void visit(Element e) {
      final name = e.widget.runtimeType.toString();
      if (screen == null &&
          (name.endsWith('Screen') ||
              name.endsWith('Sheet') ||
              name.endsWith('Picker') ||
              name.endsWith('Dialog'))) {
        screen = name;
      }
      if (texts.length < 2 && e.widget is Text) {
        final s = (e.widget as Text).data ?? '';
        if (s.trim().isNotEmpty) texts.add(s.trim());
      }
      e.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    final kind = route is PopupRoute ? 'popup' : 'page';
    final name = screen ?? route.runtimeType.toString().split('<').first;
    return '$kind:$name${texts.isEmpty ? '' : ' "${_shape(_clip(texts.first))}"'}';
  }

  static final _numbers = RegExp(r'[0-9]+([.,:][0-9]+)*');
  static final _calendar = RegExp(
    r'\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\b',
  );

  /// Rows that differ only by a date or a count are the same control.
  static String _shape(String label) => RegExp(r'^\d$').hasMatch(label)
      ? label
      : label
            .replaceAll(RegExp(r'[A-Za-z0-9_-]{12,}'), 'X')
            .replaceAll(_calendar, 'D')
            .replaceAll(_numbers, '#');

  static String _clip(String s) {
    final one = s.replaceAll('\n', ' ');
    return one.length > 40 ? '${one.substring(0, 40)}…' : one;
  }

  String _label(Element e) {
    final texts = <String>[];
    final icons = <String>[];
    var depth = 0;
    void visit(Element c) {
      final w = c.widget;
      if (w is Text && (w.data ?? w.textSpan?.toPlainText() ?? '').isNotEmpty) {
        texts.add(w.data ?? w.textSpan!.toPlainText());
      } else if (w is Icon && w.icon != null) {
        icons.add('icon:${w.icon!.codePoint.toRadixString(16)}');
      } else if (w is CupertinoSwitch) {
        icons.add('switch');
      }
      if (texts.length > 2 || depth > 40) return;
      depth++;
      c.visitChildren(visit);
      depth--;
    }

    visit(e);
    if (texts.isNotEmpty) return _shape(_clip(texts.take(2).join(' / ')));
    if (icons.isNotEmpty) return icons.take(2).join(' ');
    final key = e.widget.key;
    if (key is ValueKey<String>) {
      final v = key.value;
      // Photo tiles are keyed by record id: one is as good as the next.
      if (v.contains(':')) return 'tile';
      return 'key:$v';
    }
    return 'unlabeled ${e.widget.runtimeType}';
  }

  bool _hits(RenderBox box, Offset at) {
    final result = HitTestResult();
    t.binding.hitTestInView(result, at, t.view.viewId);
    return result.path.any((entry) => entry.target == box);
  }

  List<_Candidate> _candidates(Route<dynamic> route, String screen) {
    final context = route is ModalRoute ? route.subtreeContext : null;
    if (context == null) return const [];
    final out = <_Candidate>[];
    final size = t.view.physicalSize / t.view.devicePixelRatio;
    void add(Element e, {bool tap = true, bool longPress = false}) {
      final box = e.renderObject;
      if (box is! RenderBox || !box.hasSize || !box.attached) return;
      final center = box.localToGlobal(box.size.center(Offset.zero));
      if (center.dx < 0 ||
          center.dy < 0 ||
          center.dx > size.width ||
          center.dy > size.height) {
        return;
      }
      if (!_hits(box, center)) return;
      final label = _label(e);
      if (tap) out.add(_Candidate('$screen|$label', center));
      if (longPress) {
        out.add(_Candidate('$screen|long $label', center, longPress: true));
      }
    }

    void visit(Element e) {
      final w = e.widget;
      if (w is CupertinoButton && w.onPressed != null) {
        add(e, longPress: w.onLongPress != null);
      } else if (w is GestureDetector &&
          (w.onTap != null || w.onLongPress != null)) {
        add(e, tap: w.onTap != null, longPress: w.onLongPress != null);
      } else if (w is CupertinoListTile && w.onTap != null) {
        add(e);
      } else if (w is CupertinoSwitch && w.onChanged != null) {
        add(e);
      } else if (w is CupertinoActionSheetAction ||
          w is CupertinoDialogAction ||
          w is CupertinoContextMenuAction) {
        add(e);
      } else if (w is CupertinoSlidingSegmentedControl ||
          w is CupertinoSegmentedControl) {
        void segments(Element c) {
          if (c.widget is Text) add(c);
          c.visitChildren(segments);
        }

        e.visitChildren(segments);
        return;
      } else if (w is CupertinoContextMenu) {
        add(e, tap: false, longPress: true);
      } else if (w is CupertinoTextField) {
        add(e);
      }
      e.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return out;
  }

  ScrollableState? _mainScrollable(Route<dynamic> route) {
    final context = route is ModalRoute ? route.subtreeContext : null;
    if (context == null) return null;
    ScrollableState? best;
    var bestArea = 0.0;
    void visit(Element e) {
      if (e is StatefulElement && e.state is ScrollableState) {
        final s = e.state as ScrollableState;
        final box = e.renderObject;
        if (s.position.axis == Axis.vertical &&
            s.position is! FixedExtentMetrics &&
            s.position.hasContentDimensions &&
            s.position.minScrollExtent.isFinite &&
            s.position.maxScrollExtent.isFinite &&
            box is RenderBox &&
            box.hasSize &&
            s.position.hasContentDimensions &&
            s.position.maxScrollExtent > s.position.minScrollExtent) {
          final area = box.size.width * box.size.height;
          if (area > bestArea) {
            best = s;
            bestArea = area;
          }
        }
      }
      e.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return best;
  }

  bool _denied(String sig) {
    final label = sig.substring(sig.lastIndexOf('|') + 1);
    return deny.any((p) => label.contains(p));
  }

  /// The next control on [route] not yet tried, scrolling down for it.
  Future<_Candidate?> _next(
    Route<dynamic> route,
    String screen,
    Set<String> done,
  ) async {
    _Candidate? pick() {
      for (final c in _candidates(route, screen)) {
        if (done.contains(c.sig)) continue;
        if (_denied(c.sig)) {
          if (skipped.add(c.sig)) say('skip ${c.sig}');
          done.add(c.sig);
          continue;
        }
        return c;
      }
      return null;
    }

    var here = pick();
    if (here != null) return here;
    // A page still sliding back into place hit-tests as nothing.
    await settle(4);
    here = pick();
    if (here != null) return here;
    final scrollable = _mainScrollable(route);
    if (scrollable == null) return _sideways(route, pick);
    final position = scrollable.position;
    final step = position.viewportDimension * 0.85;
    final start = position.pixels;
    if (step < 50 || !position.maxScrollExtent.isFinite) return null;
    final offsets = <double>[
      start,
      for (var o = start + step; o < position.maxScrollExtent + step; o += step)
        o,
      for (var o = position.minScrollExtent; o < start; o += step) o,
    ];
    for (final offset in offsets) {
      if (!route.isActive || top() != route || !scrollable.mounted) {
        return null;
      }
      position.jumpTo(
        offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      await t.pump(const Duration(milliseconds: 60));
      await t.pump(const Duration(milliseconds: 60));
      final c = pick() ?? await _sideways(route, pick);
      if (c != null) return c;
    }
    return null;
  }

  /// Rows that scroll sideways (album cards, chips), each run end to end.
  Future<_Candidate?> _sideways(
    Route<dynamic> route,
    _Candidate? Function() pick,
  ) async {
    final context = route is ModalRoute ? route.subtreeContext : null;
    if (context == null) return null;
    final rows = <ScrollableState>[];
    final size = t.view.physicalSize / t.view.devicePixelRatio;
    void visit(Element e) {
      if (e is StatefulElement && e.state is ScrollableState) {
        final s = e.state as ScrollableState;
        final box = e.renderObject;
        // Not a pager: paging a photo viewer changes which photo it is.
        if (s.position.axis == Axis.horizontal &&
            s.position is! PageMetrics &&
            s.position.hasContentDimensions &&
            s.position.minScrollExtent.isFinite &&
            s.position.maxScrollExtent.isFinite &&
            box is RenderBox &&
            box.hasSize &&
            s.position.hasContentDimensions &&
            s.position.maxScrollExtent > s.position.minScrollExtent) {
          final y = box.localToGlobal(box.size.center(Offset.zero)).dy;
          if (y > 0 && y < size.height) rows.add(s);
        }
      }
      e.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    for (final row in rows) {
      final position = row.position;
      final step = position.viewportDimension * 0.85;
      if (step < 50) continue;
      for (
        var o = position.minScrollExtent + step;
        o < position.maxScrollExtent + step;
        o += step
      ) {
        if (!row.mounted) return null;
        position.jumpTo(
          o.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
        await t.pump(const Duration(milliseconds: 60));
        final c = pick();
        if (c != null) return c;
      }
      if (!row.mounted) return null;
      position.jumpTo(position.minScrollExtent);
      await t.pump(const Duration(milliseconds: 60));
    }
    return null;
  }

  Future<void> _act(_Candidate c, int depth) async {
    taps++;
    say('${'  ' * depth}${c.longPress ? 'hold' : 'tap'} ${c.sig}');
    problems.where = c.sig;
    if (c.longPress) {
      await holdAt(c.center);
    } else {
      await t.tapAt(c.center);
    }
    final before = problems.list.length;
    await settle();
    FocusManager.instance.primaryFocus?.unfocus();
    problems.check();
    if (problems.list.length > before) await shot('problem');
  }

  /// Asks the host (`shotter.sh`) for a simulator screenshot.
  Future<void> shot(String name) async {
    say('SHOT ${(shots++).toString().padLeft(3, '0')}_$name');
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }
  }

  /// Crawls the route on top now. [reopen] brings it back if one of its own
  /// controls closes it.
  Future<void> crawl({
    int depth = 0,
    Route<dynamic>? parent,
    Future<bool> Function()? reopen,
    int maxTaps = 60,
  }) async {
    var origin = top();
    final screen = describe(origin);
    say('${'  ' * depth}enter $screen');
    await shot(screen);
    if (find
        .byType(CupertinoActivityIndicator)
        .hitTestable()
        .evaluate()
        .isNotEmpty) {
      await settle(15);
      if (find
          .byType(CupertinoActivityIndicator)
          .hitTestable()
          .evaluate()
          .isNotEmpty) {
        say('SPINNER still on $screen after 3s');
        spinners.add(screen);
      }
    }
    say(
      '${'  ' * depth}  sees ${_candidates(origin, screen).map((c) => c.sig.split('|').last).toSet().join(' ; ')}',
    );
    final done = <String>{};
    for (var i = 0; i < maxTaps; i++) {
      final c = await _next(origin, screen, done);
      if (c == null) break;
      done.add(c.sig);
      await _act(c, depth);
      if (origin.isActive && top() != origin) {
        final opened = top();
        final name = describe(opened);
        final from = origin;
        if (depth < maxDepth && visited.add(_kindKey(name))) {
          await crawl(
            depth: depth + 1,
            parent: from,
            reopen: () async {
              if (!from.isActive) return false;
              if (top() != from) _nav.popUntil((r) => r == from);
              await settle(3);
              if (c.longPress) {
                await holdAt(c.center);
              } else {
                await t.tapAt(c.center);
              }
              await settle();
              return top() != from;
            },
          );
        } else {
          say('${'  ' * depth}  (seen $name)');
        }
        if (origin.isActive && top() != origin) {
          _nav.popUntil((r) => r == origin);
          await settle(8);
          problems.check();
        }
      }
      if (!origin.isActive) {
        say('${'  ' * depth}closed $screen');
        // Closed onto a next step (a dialog leading to a sheet): that too.
        final now = top();
        if (parent != null && parent.isActive && now != parent) {
          final name = describe(now);
          if (depth < maxDepth && visited.add(_kindKey(name))) {
            await crawl(depth: depth, parent: parent);
          }
          if (parent.isActive && top() != parent) {
            _nav.popUntil((r) => r == parent);
            await settle(8);
            problems.check();
          }
        }
        if (reopen == null || !await reopen()) return;
        origin = top();
      }
    }
    say('${'  ' * depth}leave $screen');
  }

  /// Scrolls the page on top until [finder] can be tapped, then taps it.
  Future<bool> tapWhenFound(Finder finder) async {
    bool found() => finder.hitTestable().evaluate().isNotEmpty;
    if (!found()) {
      final s = _mainScrollable(top());
      if (s != null) {
        final p = s.position;
        final step = p.viewportDimension * 0.6;
        for (
          var o = p.minScrollExtent;
          o <= p.maxScrollExtent + step;
          o += step
        ) {
          if (!s.mounted) break;
          p.jumpTo(o.clamp(p.minScrollExtent, p.maxScrollExtent));
          await t.pump(const Duration(milliseconds: 80));
          if (found()) break;
          await _sideways(
            top(),
            () => found() ? _Candidate('', Offset.zero) : null,
          );
          if (found()) break;
        }
      } else {
        await _sideways(
          top(),
          () => found() ? _Candidate('', Offset.zero) : null,
        );
      }
    }
    if (!found()) {
      say('not found: $finder');
      return false;
    }
    problems.where = 'tapWhenFound $finder';
    await t.tap(finder.hitTestable().first);
    await settle();
    problems.check();
    return true;
  }

  /// A press held through a context menu's lift, not just past the
  /// long-press threshold: let go early and the menu reads it as a tap.
  Future<void> holdAt(Offset at) async {
    final gesture = await t.startGesture(at);
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }
    await gesture.up();
  }

  /// Back to the first page, whatever is open.
  Future<void> home() async {
    _nav.popUntil((r) => r.isFirst);
    await settle();
    problems.check();
  }
}
