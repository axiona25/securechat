/// Forma canonica per [callId] in tutta l'app (dedup, bridge, WS, CallKit).
/// UUID sono case-insensitive; uniformare evita mismatch tra push nativo, WS e plugin.
String normalizeCallId(String? value) {
  if (value == null) return '';
  return value.trim().toLowerCase();
}
