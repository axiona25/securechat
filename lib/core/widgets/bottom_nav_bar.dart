import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class BottomNavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int badgeCount;

  const BottomNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.badgeCount = 0,
  });
}

/// Colori footer: teal attivo, grigio inattivo.
const Color _navBarActive = Color(0xFF2ABFBF);
const Color _navBarGray = Color(0xFF9E9E9E);

class SecureChatBottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<BottomNavItem> items;

  const SecureChatBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.transparent,
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(items.length, (index) {
              final item = items[index];
              final isActive = index == currentIndex;

              return GestureDetector(
                onTap: () => onTap(index),
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 72,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Icon(
                            isActive ? item.activeIcon : item.icon,
                            color: isActive ? _navBarActive : _navBarGray,
                            size: 26,
                          ),
                          if (item.badgeCount > 0)
                            Positioned(
                              right: -8,
                              top: -4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.error,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                constraints: const BoxConstraints(
                                  minWidth: 18,
                                  minHeight: 16,
                                ),
                                child: Text(
                                  item.badgeCount > 99
                                      ? '99+'
                                      : item.badgeCount.toString(),
                                  style: const TextStyle(
                                    color: AppColors.textOnPrimary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                          color: isActive ? _navBarActive : _navBarGray,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
