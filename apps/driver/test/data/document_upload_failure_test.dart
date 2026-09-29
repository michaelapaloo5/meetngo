import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/data/supabase_driver_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// What a driver is told when a document upload fails.
///
/// Found on a device: the checklist said "check your connection and try again"
/// when the server had no `kyc-documents` bucket and the driver's signal was
/// fine. A message that sends somebody to check their Wi-Fi when the fault is
/// on the server is not a small thing -- it teaches a driver that the app is
/// unreliable, and there is nothing they can do to make it reliable.
void main() {
  group('a missing bucket is not the driver\'s fault', () {
    test('a 404 says the app cannot save photos, not that they should check their signal', () {
      final failure = documentUploadFailure(
        const StorageException('Object not found', statusCode: '404'),
      );

      expect(failure.message, isNot(contains('connection')));
      expect(failure.message, contains('nothing you need to fix'));
    });

    test('an error body naming the bucket counts even without a status code', () {
      // Not every failure carries a statusCode, and a "Bucket not found" body
      // is the same news as a 404 whether or not the code survived.
      final failure = documentUploadFailure(
        const StorageException('upload failed', error: 'Bucket not found'),
      );

      expect(failure.message, isNot(contains('connection')));
    });

    test('so does the same words in the message', () {
      final failure = documentUploadFailure(
        const StorageException('Bucket not found'),
      );

      expect(failure.message, isNot(contains('connection')));
    });
  });

  group('a transient failure still reads as transient', () {
    test('a 500 tells the driver to retry', () {
      final failure = documentUploadFailure(
        const StorageException('Internal error', statusCode: '500'),
      );

      expect(failure.message, contains('try again'));
    });

    test('an upload with no status code at all is a retry, not an accusation', () {
      // The default has to be the retry. Treating an unknown failure as a
      // server fault would be the reverse mistake: telling a driver it is not
      // their problem when it might be.
      final failure = documentUploadFailure(
        const StorageException('Something went wrong'),
      );

      expect(failure.message, contains('try again'));
    });

    test('a network failure is a retry', () {
      final failure = documentUploadFailure(
        const StorageException('Connection closed', statusCode: '0'),
      );

      expect(failure.message, contains('try again'));
    });
  });

  test('a too-large photo is a retry, and not blamed on the bucket', () {
    // The bucket has a 10MB cap and `CameraDocumentCapture` bounds the photo
    // well under it, so this is not reachable in the shipped app. It is here
    // because "Payload too large" contains neither the words that would make it
    // read as missing, and a test that did not cover it would leave the
    // classification resting on which words happen to be in the message.
    final failure = documentUploadFailure(
      const StorageException('Payload too large', statusCode: '413'),
    );

    expect(failure.message, contains('try again'));
    expect(failure.message, isNot(contains('nothing you need to fix')));
  });
}
