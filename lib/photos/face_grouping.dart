import 'dart:isolate';

import 'ai_analysis_store.dart';
import 'face_matcher.dart';
import 'on_device_vision.dart' show FaceDescriptor;
import 'person.dart';

/// Everyone in the library who looks like one particular face.
///
/// Computed fresh on demand and never written down. A stored cluster is
/// stored wrongness: it goes stale the moment a better photo is described,
/// and a pile the app got wrong is worse than no pile at all. This is the
/// answer to a question the user asked by pointing at a face, and it lives
/// exactly as long as the screen showing it.
class FaceGrouping {
  const FaceGrouping({required this.analysisStore, this.ceiling});

  /// How alike counts as alike, *per space*. A threshold belongs to the
  /// thing that produced the numbers: SFace's embeddings and Vision's
  /// image prints do not put "the same person" at the same distance, and
  /// one number across both is wrong for at least one of them.
  ///
  /// 0.637 is the only figure here nobody invented: it is the cosine
  /// distance matching the 0.363 similarity SFace's authors publish as
  /// the same-person line. 0.30 for the image print is measured only
  /// against "this grouped acceptably", which is why the model exists.
  static const ceilingFor = {
    2: 0.30, // unaligned image print — no eyes found
    3: 0.30, // aligned image print — superseded by the model
    4: 0.637, // SFace
  };

  static double ceilingForPipeline(int pipeline) =>
      ceilingFor[pipeline] ?? 0.30;

  /// Stricter, for folding the People list into one circle per person.
  ///
  /// Two reasons it can't be [ceilingFor]. The published 0.637 is a
  /// *verification* line — "are these two the same person?", asked once,
  /// answered by someone who can see both. Folding asks it forty times
  /// and shows only the answer: a face wrongly pulled in doesn't appear
  /// as a mistake, it disappears behind somebody else's circle, and there
  /// is nothing to untick because there is nothing to see.
  ///
  /// And a wrong fold is self-concealing in a way a wrong group is not:
  /// the list is ordered by pile size, so the circles that swallowed the
  /// most strangers are the ones shown first.
  ///
  /// Splitting one person into two circles is the failure this prefers.
  /// That costs a second naming; the other costs a person you can't find.
  static const foldingCeilingFor = {2: 0.22, 3: 0.22, 4: 0.45};

  static double foldingCeilingForPipeline(int pipeline) =>
      foldingCeilingFor[pipeline] ?? 0.22;

  final AiAnalysisStore analysisStore;

  /// Overrides the per-space default. Tests set it; the app doesn't.
  final double? ceiling;

  /// How alike counts as alike. Deliberately looser than
  /// [FaceMatcher.ceiling], because the two mistakes cost different
  /// amounts: a wrong *suggestion* puts a name on screen that nobody
  /// asked for, while a wrong face in a group is one tap to untick. Under
  /// a gathering the user is going to check anyway, letting too much in
  /// beats leaving the right photo out — a face that isn't offered can't
  /// be corrected.
  ///

  /// Unnamed faces that look like *any* of [references], nearest first.
  ///
  /// The compounding one. Searching from a single face searches from a
  /// single angle in a single light; searching from every photo you have
  /// confirmed of somebody searches from all of them, and a new photo
  /// only has to land near one. This is what makes tagging pay off
  /// instead of plateau — each confirmation is another way to be found.
  ///
  /// A face nearer to one of [others] (everyone else's references) than to
  /// any of [references] is somebody else's, and left out. [among] limits
  /// candidates and references to those photos — the visible ones.
  Future<List<UnnamedFace>> likeAnyOf(
    List<ConfirmedFace> references, {
    List<ConfirmedFace> others = const [],
    Set<String>? among,
    int limit = 500,
  }) async {
    final mine = [
      for (final r in references)
        if (among == null || among.contains(r.localId)) r.descriptor,
    ];
    if (mine.isEmpty) return const [];
    final theirs = [
      for (final r in others)
        if (among == null || among.contains(r.localId)) r.descriptor,
    ];
    final List<DescribedFace> described;
    try {
      described = await analysisStore.allDescribedFaces();
    } catch (_) {
      return const [];
    }
    return _ranked(
      _candidates(described, among),
      mine,
      theirs,
      ceiling,
      limit,
      folding: true,
    );
  }

  /// Faces that look like [seed], nearest first, [seed] itself included.
  ///
  /// Faces already belonging to a named person are left out: they have an
  /// answer, and offering them again invites a second name on the same
  /// face. Empty when the seed has no description yet — which means the
  /// analyze pass hasn't reached it. [among] limits candidates to those
  /// photos.
  /// [limit] is a last guard against a threshold gone wrong, not a page
  /// size — it sits far above any real group, because a circle promising
  /// two hundred photos that opens on thirty-seven is a lie told by the
  /// cap. Nearest first, so a bad threshold reads as "the first few are
  /// right and then it drifts" rather than as a wall.
  Future<List<UnnamedFace>> like(
    UnnamedFace seed, {
    Set<String>? among,
    int limit = 500,
  }) async {
    final List<DescribedFace> described;
    final seedDescriptor = await analysisStore.descriptorFor(
      seed.localId,
      seed.face,
    );
    if (seedDescriptor == null || seedDescriptor.isEmpty) return const [];
    // The *folding* threshold, the one the circle was gathered with. The
    // looser [ceilingFor] would show photos the count never counted, and
    // a number you can't reconcile with what it opens is worse than a
    // number that is slightly too cautious.
    final limitDistance =
        ceiling ?? foldingCeilingForPipeline(seedDescriptor.pipeline);
    try {
      described = await analysisStore.allDescribedFaces();
    } catch (_) {
      return const [];
    }
    return _ranked(
      _candidates(described, among),
      [seedDescriptor],
      const [],
      limitDistance,
      limit,
      folding: false,
    );
  }

  static List<DescribedFace> _candidates(
    List<DescribedFace> described,
    Set<String>? among,
  ) => [
    for (final f in described)
      if (f.personId == null && (among == null || among.contains(f.localId))) f,
  ];

  /// Off the UI isolate once the comparisons add up (CLAUDE.md). Static, so
  /// the closure carries only its arguments.
  static Future<List<UnnamedFace>> _ranked(
    List<DescribedFace> candidates,
    List<FaceDescriptor> mine,
    List<FaceDescriptor> theirs,
    double? ceiling,
    int limit, {
    required bool folding,
  }) async {
    final work = candidates.length * (mine.length + theirs.length);
    if (work < _isolateWork) {
      return _rank(candidates, mine, theirs, ceiling, limit, folding);
    }
    return Isolate.run(
      () => _rank(candidates, mine, theirs, ceiling, limit, folding),
    );
  }

  static const _isolateWork = 20000;

  static List<UnnamedFace> _rank(
    List<DescribedFace> candidates,
    List<FaceDescriptor> mine,
    List<FaceDescriptor> theirs,
    double? ceiling,
    int limit,
    bool folding,
  ) {
    double nearest(List<FaceDescriptor> from, FaceDescriptor to) {
      var best = double.infinity;
      for (final d in from) {
        final distance = d.distanceTo(to);
        if (distance != null && distance < best) best = distance;
      }
      return best;
    }

    final ranked = <(double, DescribedFace)>[];
    for (final candidate in candidates) {
      final best = nearest(mine, candidate.descriptor);
      // Measured against the space the *candidate* is in, since that is
      // the one being judged.
      final ceilingHere =
          ceiling ??
          (folding
              ? foldingCeilingForPipeline(candidate.descriptor.pipeline)
              : double.infinity);
      if (best > ceilingHere) continue;
      if (theirs.isNotEmpty && nearest(theirs, candidate.descriptor) < best) {
        continue;
      }
      ranked.add((best, candidate));
    }
    ranked.sort((a, b) => a.$1.compareTo(b.$1));
    return [
      for (final (_, candidate) in ranked.take(limit))
        UnnamedFace(localId: candidate.localId, face: candidate.face),
    ];
  }
}
