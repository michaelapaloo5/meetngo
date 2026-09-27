import 'package:flutter/material.dart';
import 'tokens.dart';

abstract final class MngTheme {
  /// Light theme only at launch, per spec section 6.
  static ThemeData? get dark => null;

  static TextStyle get _labelLarge => const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: MngColors.onPrimary,
      );

  static final ThemeData _light = _buildLight();

  /// Built once and cached, so reading it inside build() does not reallocate.
  static ThemeData get light => _light;

  static ThemeData _buildLight() {
    final scheme = ColorScheme.fromSeed(
      seedColor: MngColors.primary,
      surface: MngColors.page,
    ).copyWith(
      primary: MngColors.primary,
      onPrimary: MngColors.onPrimary,
      error: MngColors.error,
      surface: MngColors.page,
      outline: MngColors.divider,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: MngColors.page,
      dividerColor: MngColors.divider,
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
            fontSize: 28, fontWeight: FontWeight.w700, color: MngColors.textPrimary),
        titleLarge: TextStyle(
            fontSize: 20, fontWeight: FontWeight.w600, color: MngColors.textPrimary),
        titleMedium: TextStyle(
            fontSize: 16, fontWeight: FontWeight.w600, color: MngColors.textPrimary),
        bodyMedium: TextStyle(fontSize: 14, color: MngColors.textPrimary),
        bodySmall: TextStyle(fontSize: 12, color: MngColors.textSub),
      ),
      cardTheme: CardThemeData(
        color: MngColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MngRadius.large),
          side: const BorderSide(color: MngColors.divider),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: MngColors.primary,
          foregroundColor: MngColors.onPrimary,
          minimumSize: const Size.fromHeight(52),
          textStyle: _labelLarge,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(MngRadius.small)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: MngColors.muted,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: MngSpacing.md, vertical: 14),
        border: _inputBorder(BorderSide.none),
        enabledBorder: _inputBorder(BorderSide.none),
        focusedBorder:
            _inputBorder(const BorderSide(color: MngColors.primary, width: 1.5)),
        errorBorder:
            _inputBorder(const BorderSide(color: MngColors.error, width: 1.5)),
        focusedErrorBorder:
            _inputBorder(const BorderSide(color: MngColors.error, width: 1.5)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: MngColors.surface,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(BorderSide side) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(MngRadius.small),
        borderSide: side,
      );
}
