import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';

enum ChatFilter { all, group, favorites }

class ChatTabBar extends StatelessWidget {
  final ChatFilter selectedFilter;
  final ValueChanged<ChatFilter> onFilterChanged;
  final int allCount;
  final int groupCount;
  final int favoritesCount;

  const ChatTabBar({
    super.key,
    required this.selectedFilter,
    required this.onFilterChanged,
    required this.allCount,
    required this.groupCount,
    required this.favoritesCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _buildTab(
            label: 'Chats',
            count: allCount,
            filter: ChatFilter.all,
          ),
          const SizedBox(width: 24),
          _buildTab(
            label: 'Group',
            count: groupCount > 0 ? groupCount : null,
            filter: ChatFilter.group,
          ),
          const SizedBox(width: 24),
          _buildTab(
            label: 'Favourite',
            count: favoritesCount > 0 ? favoritesCount : null,
            filter: ChatFilter.favorites,
          ),
        ],
      ),
    );
  }

  Widget _buildTab({
    required String label,
    int? count,
    required ChatFilter filter,
  }) {
    final isSelected = selectedFilter == filter;
    final displayText = (count != null && count > 0) ? '$label ($count)' : label;

    return GestureDetector(
      onTap: () => onFilterChanged(filter),
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              displayText,
              style: TextStyle(
                fontSize: 15,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? AppColors.primary : AppColors.textDisabled,
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 2.5,
            width: isSelected ? displayText.length * 7.0 + 10 : 0,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}
