import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  test('primary colour is the video-matched amber', () {
    expect(MngColors.primary, const Color(0xFFF5B301));
    expect(MngColors.onPrimary, const Color(0xFF1A1A1A));
  });

  test('radius tokens are 16 small and 20 large', () {
    expect(MngRadius.small, 16.0);
    expect(MngRadius.large, 20.0);
  });

  test('theme uses the amber primary and light surfaces', () {
    final theme = MngTheme.light;
    expect(theme.colorScheme.primary, MngColors.primary);
    expect(theme.scaffoldBackgroundColor, MngColors.page);
    expect(theme.useMaterial3, isTrue);
  });

  test('filled button uses amber with dark label', () {
    final style = MngTheme.light.filledButtonTheme.style;
    expect(style?.backgroundColor?.resolve({}), MngColors.primary);
    expect(style?.foregroundColor?.resolve({}), MngColors.onPrimary);
  });

  test('theme has no dark variant yet', () {
    expect(MngTheme.dark, isNull);
  });
}
