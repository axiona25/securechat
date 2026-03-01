import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/models/conversation_model.dart';
import '../../../core/l10n/app_localizations.dart';
import 'chat_list_item.dart';

class ChatListView extends StatelessWidget {
  final List<ConversationModel> conversations;
  final int? currentUserId;
  final bool isLoading;
  final VoidCallback? onRefresh;
  final ValueChanged<ConversationModel>? onConversationTap;
  final ValueChanged<ConversationModel>? onConversationDelete;
  final ValueChanged<ConversationModel>? onConversationMore;
  final Widget Function(ConversationModel)? previewBuilder;

  const ChatListView({
    super.key,
    required this.conversations,
    this.currentUserId,
    this.isLoading = false,
    this.onRefresh,
    this.onConversationTap,
    this.onConversationDelete,
    this.onConversationMore,
    this.previewBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const SliverFillRemaining(
        child: Center(
          child: CircularProgressIndicator(
            color: AppColors.primary,
            strokeWidth: 2.5,
          ),
        ),
      );
    }

    if (conversations.isEmpty) {
      return SliverFillRemaining(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 64,
                color: AppColors.textDisabled.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context)?.t('no_conversations') ?? 'No conversations yet',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                AppLocalizations.of(context)?.t('start_new_chat') ?? 'Start a new chat to begin messaging',
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textDisabled,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(left: 20, top: 8, bottom: 4),
              child: Text(
                AppLocalizations.of(context)?.t('chats') ?? 'Chat',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppColors.blue700,
                ),
              ),
            );
          }

          final convIndex = index - 1;
          if (convIndex >= conversations.length) return null;

          return ChatListItem(
            conversation: conversations[convIndex],
            currentUserId: currentUserId,
            onTap: () => onConversationTap?.call(conversations[convIndex]),
            onDelete: onConversationDelete != null ? () => onConversationDelete!(conversations[convIndex]) : null,
            onMore: onConversationMore != null ? () => onConversationMore!(conversations[convIndex]) : null,
            previewBuilder: previewBuilder,
          );
        },
        childCount: conversations.length + 1,
      ),
    );
  }
}
