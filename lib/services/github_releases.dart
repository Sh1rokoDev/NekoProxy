const githubReleaseAssetHosts = {
  'github.com',
  'release-assets.githubusercontent.com',
  'objects.githubusercontent.com',
};
const githubRedirectCodes = {301, 302, 303, 307, 308};
const maxGitHubReleaseMetadataSize = 1024 * 1024;

typedef GitHubReleaseAsset = ({String name, String? sha256});

final _tagPattern = RegExp(r'^[A-Za-z0-9._-]+$');
final _assetRow = RegExp(r'<li\b[^>]*>[\s\S]*?</li>');
final _assetLink = RegExp(r'<a\b[^>]*\shref="([^"]+)"');
final _assetDigest = RegExp(
  r'<clipboard-copy\b[^>]*\svalue="sha256:([a-f0-9]{64})"',
);

class GitHubReleases {
  const GitHubReleases(this.repository);

  final String repository;
  String get _path => '/$repository/releases';
  Uri get latest => Uri.https('github.com', '$_path/latest');
  Uri get index => Uri.https('github.com', _path);
  Uri assetsPage(String tag) =>
      Uri.https('github.com', '$_path/expanded_assets/$tag');
  Uri download(String tag, String name) =>
      Uri.https('github.com', '$_path/download/$tag/$name');

  String? tagAt(Uri? location) {
    final tag = location?.pathSegments.lastOrNull;
    if (tag == null ||
        !_tagPattern.hasMatch(tag) ||
        tag == '.' ||
        tag == '..' ||
        location?.path != '$_path/tag/$tag') {
      return null;
    }
    return tag;
  }

  List<GitHubReleaseAsset> assets(String tag, String html) {
    final assets = <GitHubReleaseAsset>[];
    for (final match in _assetRow.allMatches(html)) {
      final row = html.substring(match.start, match.end);
      for (final link in _assetLink.allMatches(row)) {
        final target = githubReleaseRedirect(index, link.group(1), const {
          'github.com',
        });
        final name = target?.pathSegments.lastOrNull;
        if (name == null ||
            name.isEmpty ||
            name.contains('/') ||
            name.contains('\\') ||
            target?.pathSegments.join('/') !=
                '$repository/releases/download/$tag/$name') {
          continue;
        }
        final digest = _assetDigest.allMatches(row).toList();
        assets.add((
          name: name,
          sha256: digest.length == 1 ? digest.single.group(1) : null,
        ));
      }
    }
    return assets;
  }
}

Uri? githubReleaseRedirect(Uri uri, String? location, Set<String> hosts) {
  final reference = location == null ? null : Uri.tryParse(location);
  if (reference == null) return null;
  final next = uri.resolveUri(reference);
  return next.scheme == 'https' &&
          next.port == 443 &&
          next.userInfo.isEmpty &&
          hosts.contains(next.host)
      ? next
      : null;
}
