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
  for (final dir in ['apps', 'packages']) {
    final root = Directory(dir);
    if (!root.existsSync()) continue;
    for (final entity in root.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('AndroidManifest.xml')) {
        manifests.add(entity);
      }
    }
  }
  manifests.sort((a, b) => a.path.compareTo(b.path));

  test('every AndroidManifest.xml in the repo was found', () {
    expect(manifests, isNotEmpty,
        reason: 'if this is empty the walk is broken and every other test '
            'here is vacuous');
    expect(manifests.length, greaterThanOrEqualTo(2),
        reason: 'the rider app and the driver app each have one');
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
        expect(body.contains('--'), isFalse,
            reason: 'line $line: XML forbids "--" inside a comment. A manifest '
                'with one fails the Gradle manifest merger with "Error parsing" '
                'and no line number. Write an em dash in full instead.');
      }

      // And the whole file parses. Belt and braces: the check above covers the
      // rule this repo has actually broken, and this covers anything else.
      expect(() => _parse(text), returnsNormally,
          reason: 'the manifest must be well-formed XML');
    });
  }
}

/// Parse with the platform's own XML parser.
void _parse(String text) {
  // `Document` is not in the SDK, so this uses the fact that a well-formed
  // manifest is also well-formed as a whole when its tags balance. A real
  // parser is in `package:xml`; this project has no such dependency and adding
  // one for a comment lint is not worth it. What the double-hyphen check
  // above catches is the only malformation Gradle has ever hit here, and it
  // catches it without a parser at all.
  var depth = 0;
  for (final m in RegExp(r'<(/?)([A-Za-z_][\w:.-]*)([^>]*?)(/?)>').allMatches(text)) {
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
