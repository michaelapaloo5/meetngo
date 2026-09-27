import 'package:flutter/material.dart';

/// Palette locked to the reference UI. See spec section 6.
abstract final class MngColors {
  static const primary = Color(0xFFF5B301);
  static const onPrimary = Color(0xFF1A1A1A);

  static const page = Color(0xFFFFFFFF);
  static const surface = Color(0xFFFFFFFF);
  static const muted = Color(0xFFF5F5F7);
  static const divider = Color(0xFFEDEDF0);

  static const textPrimary = Color(0xFF1A1A1A);
  static const textSub = Color(0xFF8A8A8E);

  static const standard = Color(0xFFF5B301);
  static const premium = Color(0xFF1A1A1A);
  static const van = Color(0xFF1DB954);

  static const success = Color(0xFF1DB954);
  static const error = Color(0xFFE5484D);
  static const info = Color(0xFF2F6FED);
}

abstract final class MngSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

abstract final class MngRadius {
  static const small = 16.0;
  static const large = 20.0;
}
