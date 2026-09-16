import 'package:http/http.dart' as http;

enum S3RegionDetectionOutcome { ok, notFound, networkError }

class S3RegionDetectionResult {
  const S3RegionDetectionResult(this.outcome, {this.region});

  final S3RegionDetectionOutcome outcome;
  final String? region;

  bool get isOk => outcome == S3RegionDetectionOutcome.ok;
}

/// Detects which AWS region [bucket] lives in from its name alone — no
/// credentials or manual region entry needed. S3's global endpoint returns
/// the `x-amz-bucket-region` header even on an unauthorized response, so a
/// plain unsigned request is enough.
Future<S3RegionDetectionResult> detectBucketRegion(String bucket) async {
  try {
    final response = await http.head(
      Uri.https('$bucket.s3.amazonaws.com', '/'),
    );
    final region = response.headers['x-amz-bucket-region'];
    if (region != null && region.isNotEmpty) {
      return S3RegionDetectionResult(
        S3RegionDetectionOutcome.ok,
        region: region,
      );
    }
    if (response.statusCode == 404) {
      return const S3RegionDetectionResult(S3RegionDetectionOutcome.notFound);
    }
    return const S3RegionDetectionResult(S3RegionDetectionOutcome.networkError);
  } catch (_) {
    return const S3RegionDetectionResult(S3RegionDetectionOutcome.networkError);
  }
}
