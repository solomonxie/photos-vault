import 'on_device_vision.dart';
import 'person.dart' show FaceRect;

/// One face the user has already put a name to — a photo, the box, and what
/// it looks like as a vector.
class ConfirmedFace {
  const ConfirmedFace({
    required this.personId,
    required this.localId,
    required this.descriptor,
  });

  final String personId;
  final String localId;
  final FaceDescriptor descriptor;
}

/// A face the app has a description of. [personId] null means nobody has
/// said whose it is — most of them, and exactly what grouping searches.
class DescribedFace {
  const DescribedFace({
    required this.localId,
    required this.face,
    required this.descriptor,
    this.personId,
  });

  final String localId;
  final FaceRect face;
  final FaceDescriptor descriptor;
  final String? personId;
}

/// Who a face might be. Never who it *is* — see `FaceMatcher`.
class FaceMatch {
  const FaceMatch({required this.personId, required this.distance});

  final String personId;
  final double distance;
}

/// Guesses which named person a face belongs to, by finding the nearest
/// already-confirmed face.
///
/// Two gates, and a guess has to pass both:
///
/// - **[ceiling]** — how alike is alike enough. Without it the nearest
///   person is still returned when the nearest person is nobody, so every
///   stranger gets named after whoever is least unlike them.
/// - **[margin]** — how much closer the winner has to be than the runner-up
///   from a *different* person. Two siblings sit at nearly the same
///   distance, and picking one of them is a coin flip presented as an
///   answer. Silence is the better output.
///
/// Both numbers are provisional: they were not measured before shipping,
/// because measuring needs labelled faces and the labels are what the user
/// makes by naming people. See `docs/design/face-recognition/DESIGN.md`.
class FaceMatcher {
  const FaceMatcher({this.ceiling = 0.30, this.margin = 0.06});

  /// The largest cosine distance still worth offering a name for — 0 is
  /// the same direction, ~1 unrelated.
  ///
  /// Deliberately tight, and tight enough to suit the *image print* as
  /// well as the model: a suggestion puts a name on screen nobody asked
  /// for, where a wrong face in a group is one tap in a list you were
  /// already checking. Silence costs nothing here.
  final double ceiling;

  /// How far ahead of the next person the winner must be.
  final double margin;

  /// The best guess for [candidate], or `null` for no opinion — which is
  /// what the app did before this existed and a perfectly good answer.
  FaceMatch? match(FaceDescriptor candidate, List<ConfirmedFace> confirmed) {
    if (candidate.isEmpty) return null;
    final best = <String, double>{};
    for (final face in confirmed) {
      final distance = candidate.distanceTo(face.descriptor);
      if (distance == null) continue;
      final current = best[face.personId];
      if (current == null || distance < current) {
        best[face.personId] = distance;
      }
    }
    if (best.isEmpty) return null;

    String? winner;
    var winning = double.infinity;
    var runnerUp = double.infinity;
    best.forEach((personId, distance) {
      if (distance < winning) {
        runnerUp = winning;
        winning = distance;
        winner = personId;
      } else if (distance < runnerUp) {
        runnerUp = distance;
      }
    });
    if (winner == null || winning > ceiling) return null;
    if (runnerUp - winning < margin) return null;
    return FaceMatch(personId: winner!, distance: winning);
  }
}
