import 'package:flutter/material.dart';

/// SecureChat Design System — Color Palette
/// Estratta dai file originali Logo_Securechat.png e Sfondo.png
class AppColors {
  AppColors._();

  // ══════════════════════════════════════════════
  // BRAND PRIMARY — Navy (testo "Secure", scudo top)
  // ══════════════════════════════════════════════
  static const Color navy900 = Color(0xFF1E2040);
  static const Color navy800 = Color(0xFF253050);
  static const Color navy700 = Color(0xFF2D3A5C);
  static const Color navy600 = Color(0xFF354468);
  static const Color navy100 = Color(0xFFE8EBF0);

  // ══════════════════════════════════════════════
  // BRAND TEAL — Verde Acqua (testo "Chat", scudo bottom)
  // ══════════════════════════════════════════════
  static const Color teal700 = Color(0xFF2A8C84);
  static const Color teal600 = Color(0xFF3BA89E);
  static const Color teal500 = Color(0xFF5CBDB0); // ★ PRIMARY
  static const Color teal400 = Color(0xFF6EC8B8);
  static const Color teal300 = Color(0xFF8DD4C6);
  static const Color teal200 = Color(0xFFB0E0D4);
  static const Color teal100 = Color(0xFFD5F0EA);
  static const Color teal50 = Color(0xFFECF8F5);

  // ══════════════════════════════════════════════
  // BRAND BLUE — Azzurro (scudo centro, sfondo onde)
  // ══════════════════════════════════════════════
  static const Color blue700 = Color(0xFF3580C8);
  static const Color blue600 = Color(0xFF4A9CD8);
  static const Color blue500 = Color(0xFF5AAEE0); // ★ SECONDARY
  static const Color blue400 = Color(0xFF80C0EC);
  static const Color blue300 = Color(0xFFA8D4F2);
  static const Color blue200 = Color(0xFFC4E2F6);
  static const Color blue100 = Color(0xFFE0F0FA);
  static const Color blue50 = Color(0xFFF0F6FC);

  // ══════════════════════════════════════════════
  // BRAND GREEN — Verde Lime (frecce lucchetto)
  // ══════════════════════════════════════════════
  static const Color green600 = Color(0xFF7AB850);
  static const Color green500 = Color(0xFF92D080);
  static const Color green400 = Color(0xFFA8D890);
  static const Color green300 = Color(0xFFC0E4AC);
  static const Color green100 = Color(0xFFE8F5E0);

  // ══════════════════════════════════════════════
  // BACKGROUND (dallo Sfondo.png)
  // ══════════════════════════════════════════════
  static const Color bgWhite = Color(0xFFF5F5F5);
  static const Color bgIce = Color(0xFFEDF4F4);
  static const Color bgWaveLight = Color(0xFFDBE8F2);
  static const Color bgWaveTeal = Color(0xFFC2E0D8);
  static const Color bgWaveBlue = Color(0xFFB0D0EC);

  // ══════════════════════════════════════════════
  // SEMANTIC — Ruoli funzionali
  // ══════════════════════════════════════════════
  static const Color primary = teal500;
  static const Color primaryDark = teal700;
  static const Color primaryLight = teal200;
  static const Color secondary = blue500;
  static const Color accent = green600;

  // Text
  static const Color textPrimary = navy900;
  static const Color textSecondary = navy700;
  static const Color textTertiary = navy600;
  static const Color textDisabled = Color(0xFF9EAAB4);
  static const Color textOnPrimary = Color(0xFFFFFFFF);

  // Surfaces
  static const Color surface = Color(0xFFFFFFFF);
  static const Color scaffold = bgWhite;
  static const Color card = Color(0xFFFFFFFF);
  static const Color divider = Color(0xFFE4E8EC);

  // Status
  static const Color error = Color(0xFFE5453A);
  static const Color warning = Color(0xFFF5A623);
  static const Color success = green600;
  static const Color info = blue500;

  // Chat specific
  static const Color online = green600;
  static const Color offline = Color(0xFFB0B8C0);
  static const Color chatBubbleMine = teal50;
  static const Color chatBubbleOther = Color(0xFFFFFFFF);
  static const Color chatInputBg = Color(0xFFF0F2F5);

  // Shimmer
  static const Color shimmerBase = Color(0x22FFFFFF);
  static const Color shimmerHighlight = Color(0x66FFFFFF);

  // Alias per compatibilità (codice legacy)
  static const Color white = surface;
  static const Color lightTeal = teal300;
  static const Color primaryTeal = primary;

  // ══════════════════════════════════════════════
  // GRADIENTI
  // ══════════════════════════════════════════════
  static const LinearGradient shieldGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF2A3555), Color(0xFF3A7090), Color(0xFF5CBDB0), Color(0xFF92D080)],
  );

  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF0F4FA), Color(0xFFDBE8F2), Color(0xFFC2E0D8)],
  );

  static const LinearGradient buttonGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF3BA89E), Color(0xFF5CBDB0)],
  );

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF5AAEE0), Color(0xFF5CBDB0)],
  );

  // ══════════════════════════════════════════════
  // DARK MODE
  // ══════════════════════════════════════════════
  static const Color darkBg = Color(0xFF121620);
  static const Color darkSurface = Color(0xFF1A2030);
  static const Color darkCard = Color(0xFF222838);
  static const Color darkPrimary = Color(0xFF6EC8B8);
  static const Color darkText = Color(0xFFE8ECF0);
  static const Color darkTextSec = Color(0xFFA0A8B8);
  static const Color darkDivider = Color(0xFF2A3040);
  static const Color darkNavBar = Color(0xFF161C28);
}
