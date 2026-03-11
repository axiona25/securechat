import 'package:flutter/material.dart';
import '../../core/l10n/app_localizations.dart';

/// Schermata dedicata al backup e recupero delle chiavi E2E.
/// Azioni: Attiva backup, Recupera chiavi, Cambia passphrase, Elimina backup.
class E2EBackupScreen extends StatelessWidget {
  const E2EBackupScreen({super.key});

  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _navy = Color(0xFF1A2B4A);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: _navy),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Backup chiavi sicure',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: _navy,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Proteggi i tuoi messaggi e recupera le chiavi in caso di reinstallazione o cambio dispositivo.',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[700],
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            _buildSection(
              context,
              [
                _buildActionTile(
                  context,
                  icon: Icons.backup_rounded,
                  title: 'Attiva backup',
                  subtitle: 'Salva una copia cifrata delle tue chiavi sul server',
                  onTap: () => _showComingSoon(context, 'Attiva backup'),
                ),
                const Divider(height: 1),
                _buildActionTile(
                  context,
                  icon: Icons.restore_rounded,
                  title: 'Recupera chiavi da backup',
                  subtitle: 'Ripristina le chiavi da un backup precedente',
                  onTap: () => _showComingSoon(context, 'Recupera chiavi'),
                ),
                const Divider(height: 1),
                _buildActionTile(
                  context,
                  icon: Icons.lock_reset_rounded,
                  title: 'Cambia passphrase',
                  subtitle: 'Modifica la passphrase usata per cifrare il backup',
                  onTap: () => _showComingSoon(context, 'Cambia passphrase'),
                ),
                const Divider(height: 1),
                _buildActionTile(
                  context,
                  icon: Icons.delete_outline_rounded,
                  title: 'Elimina backup',
                  subtitle: 'Rimuovi il backup dal server',
                  titleColor: const Color(0xFFE53935),
                  iconColor: const Color(0xFFE53935),
                  onTap: () => _showComingSoon(context, 'Elimina backup'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(BuildContext context, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _buildActionTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? titleColor,
    Color? iconColor,
  }) {
    final color = iconColor ?? _teal;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: titleColor ?? _navy,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[600],
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: Colors.grey[300], size: 22),
          ],
        ),
      ),
    );
  }

  void _showComingSoon(BuildContext context, String feature) {
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$feature — ${l10n.t('coming_soon')}'),
        backgroundColor: _teal,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
