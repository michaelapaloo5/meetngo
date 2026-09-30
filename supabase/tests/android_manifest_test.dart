import 'package:test/test.dart';

import 'dart:io';

/// Parses every AndroidManifest.xml in the repository and fails on anything
/// that is not well-formed.
///
/// This exists because of a real, expensive failure: a double hyphen inside an
/// XML comment is illegal, and an `AndroidManifest.xml` containing one does not
/// produce a useful error. Gradle's manifest merger reports
///
///     com.android.manifmerger.ManifestMerger2$MergeFailureException:
///     Error parsing ...\AndroidManifest.xml
///
/// with no line number, no offending character, and nothing to grep for. The
/// build fails about a file nobody was editing, and the test suite is green
/// because Flutter's analyzer does not read manifests. The failure costs a full
/// release build cycle -- several minutes across two apps -- to find something
/// a well-formedness check catches in milliseconds.
///
/// The rule is in the XML spec, section 2.5, and it is not something anybody
/// thinks about while writing a comment. A comment explaining the camera
/// permission is exactly where a `--` gets typed as a dash.
void main() {
  final manifests = <File>[];
  // Where the two app trees live. Resolved by walking up from the CWD until both
  // are found, rather than assumed to be relative to it: `dart test` runs from
  // this directory (it is now its own package, so `package:test` resolves) but a
  // developer or a CI job may run it from the repository root, and a walk that
  // silently found nothing there would make every test below vacuous rather than
  // failing. The first test exists precisely to catch that, but only if the walk
  // is not itself the thing that quietly found nothing.
  final repoRoot = _findRepoRoot();
  for (final dir in ['apps', 'packages']) {
    final root = Directory('${repoRoot.path}${Platform.pathSeparator}$dir');
    if (!root.existsSync()) continue;
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('AndroidManifest.xml')) continue;
      // Only manifests anyone actually writes. A recursive walk that does not
      // skip the build directories finds every plugin's *merged* manifest under
      // `build/**/intermediates/`, which made this 103 tests instead of 3 and
      // would have failed on a file no human can edit, since those come from
      // pub cache and Gradle, not from this repository.
      if (_isGeneratedPath(entity.path)) continue;
      manifests.add(entity);
    }
  }
  manifests.sort((a, b) => a.path.compareTo(b.path));

  test('every AndroidManifest.xml in the repo was found', () {
    expect(
      manifests,
      isNotEmpty,
      reason: 'if this is empty the walk is broken and every other test '
          'here is vacuous',
    );
    expect(
      manifests.length,
      greaterThanOrEqualTo(2),
      reason: 'the rider app and the driver app each have one',
    );
  });

  for (final manifest in manifests) {
    test('${manifest.path} is well-formed XML', () {
      final text = manifest.readAsStringSync();

      // The specific cause, reported as its own test so the failure names the
      // problem rather than a generic parse error. A regex rather than a
      // parser because a parser that rejects the file cannot then tell you
      // *why* in a sentence.
      final comments = RegExp(r'<!--([\s\S]*?)-->').allMatches(text);
      for (final comment in comments) {
        final body = comment.group(1)!;
        final offset = text.indexOf(body) + body.indexOf('--');
        final line = '\n'.allMatches(text.substring(0, offset)).length + 1;
        // The double hyphen of the opening and closing delimiters is outside
        // the captured body, so anything found here is genuinely illegal.
        expect(
          body.contains('--'),
          isFalse,
          reason: 'line $line: XML forbids "--" inside a comment. A manifest '
              'with one fails the Gradle manifest merger with "Error parsing" '
              'and no line number. Write an em dash in full instead.',
        );
      }

      // And the whole file parses. Belt and braces: the check above covers the
      // rule this repo has actually broken, and this covers anything else.
      expect(
        () => _parse(text),
        returnsNormally,
        reason: 'the manifest must be well-formed XML',
      );
    });
  }
}

/// True for a path under a directory whose contents are generated rather than
/// written: Gradle's `build/`, Dart's `.dart_tool/`, and the platform
/// `ephemeral/` that Flutter's own iOS tooling creates.
bool _isGeneratedPath(String path) {
  final normalised = path.replaceAll('/', '\\');
  for (final segment in ['\\build\\', '\\.dart_tool\\', '\\ephemeral\\']) {
    if (normalised.contains(segment)) return true;
  }
  return false;
}

/// The directory holding both `apps` and `packages`, found by walking up from the
/// current directory.
///
/// Falls back to the CWD itself if no ancestor has both, so the walk runs and the
/// "every AndroidManifest.xml in the repo was found" test fails loudly with zero
/// manifests -- which is the outcome that says "you ran this from the wrong
/// place", rather than a silent pass.
Directory _findRepoRoot() {
  var dir = Directory.current;
  for (var depth = 0; depth < 8; depth++) {
    final hasApps =
        Directory('${dir.path}${Platform.pathSeparator}apps').existsSync();
    final hasPackages = Directory(
      '${dir.path}${Platform.pathSeparator}packages',
    ).existsSync();
    if (hasApps && hasPackages) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}

/// Parse with the platform's own XML parser.
void _parse(String text) {
  // manifest is also well-formed as a whole when its tags balance. A real
  // parser is in `package:xml`; this project has no such dependency and adding
  // one for a comment lint is not worth it. What the double-hyphen check
  // above catches is the only malformation Gradle has ever hit here, and it
  // catches it without a parser at all.
  var depth = 0;
  for (final m in RegExp(
    r'<(/?)([A-Za-z_][\w:.-]*)([^>]*?)(/?)>',
  ).allMatches(text)) {
    final closing = m.group(1) == '/';
    final selfClosing = m.group(4) == '/';
    if (selfClosing) continue;
    if (closing) {
      depth--;
    } else {
      depth++;
    }
  }
  expect(depth, 0, reason: 'unbalanced tags in the manifest');
}
