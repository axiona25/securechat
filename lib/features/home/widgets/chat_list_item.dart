import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/models/conversation_model.dart';
import '../../../core/widgets/user_avatar_widget.dart';

class ChatListItem extends StatelessWidget {
  final ConversationModel conversation;
  final int? currentUserId;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDelete;
  final VoidCallback? onMore;
  final Widget Function(ConversationModel)? previewBuilder;

  const ChatListItem({
    super.key,
    required this.conversation,
    this.currentUserId,
    this.onTap,
    this.onLongPress,
    this.onDelete,
    this.onMore,
    this.previewBuilder,
  });

  static const Color _navy = Color(0xFF1A2B4A);
  static const Color _gray = Color(0xFF9E9E9E);
  static const Color _teal = Color(0xFF2ABFBF);
  static const Color _teal800 = Color(0xFF157070); // Teal 800 per timestamp non letti

  bool get _isLastMessageFromMe {
    final lm = conversation.lastMessage;
    return lm != null &&
        currentUserId != null &&
        lm.senderId == currentUserId;
  }

  /// Backend: statuses[].user è un intero (user ID), non un oggetto {id: ...}.
  Widget _buildHomeMessageStatus() {
    final lm = conversation.lastMessage;
    if (lm == null || currentUserId == null) return const SizedBox.shrink();
    final statuses = lm.statuses ?? [];
    final otherStatuses = statuses.where((s) {
      if (s is! Map) return false;
      final userId = (s as Map)['user'];
      final id = userId is int ? userId : int.tryParse(userId?.toString() ?? '');
      return id != null && id != currentUserId;
    }).toList();
    final isRead = otherStatuses.any((s) => (s as Map)['status'] == 'read');
    final isDelivered = otherStatuses.any((s) => (s as Map)['status'] == 'delivered');
    // Spunte teal700
    if (isRead) return Icon(Icons.done_all, size: 14, color: AppColors.teal700);
    if (isDelivered) return Icon(Icons.done_all, size: 14, color: AppColors.teal700);
    return Icon(Icons.done, size: 14, color: AppColors.teal700);
  }

  @override
  Widget build(BuildContext context) {
    final unreadCount = conversation.unreadCount;
    final hasUnread = unreadCount > 0;
    final timeStr = conversation.formattedTime;

    final content = InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildAvatar(),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            conversation.displayNameFor(currentUserId),
                            style: TextStyle(
                              color: _navy,
                              fontSize: 16,
                              fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w500,
                              height: 1.35,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (conversation.isFavorite) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.favorite, size: 14, color: Color(0xFFE91E63)),
                        ],
                        if (conversation.isMuted) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.notifications_off_outlined, size: 14, color: AppColors.blue700),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (_isLastMessageFromMe) _buildHomeMessageStatus(),
                        if (_isLastMessageFromMe) const SizedBox(width: 3),
                        Expanded(
                          child: previewBuilder != null
                              ? previewBuilder!(conversation)
                              : Text(
                                  (conversation.previewTextFor(currentUserId)).trim(),
                                  style: TextStyle(
                                    color: hasUnread ? _navy : _gray,
                                    fontSize: 14,
                                    fontWeight: hasUnread ? FontWeight.w500 : FontWeight.w400,
                                    height: 1.35,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  timeStr,
                  style: TextStyle(
                    color: hasUnread ? _teal800 : _gray,
                    fontSize: 12,
                  ),
                ),
                if (hasUnread) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                    decoration: const BoxDecoration(
                      color: _teal,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        unreadCount > 99 ? '99+' : unreadCount.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );

    return Slidable(
      key: ValueKey(conversation.id),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.45,
        children: [
          CustomSlidableAction(
            onPressed: (_) => onMore?.call(),
            backgroundColor: AppColors.blue700,
            foregroundColor: Colors.white,
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.more_vert, size: 22),
                SizedBox(height: 4),
                Text('Altro', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          CustomSlidableAction(
            onPressed: (_) => onDelete?.call(),
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.delete_outline, size: 22),
                SizedBox(height: 4),
                Text('Elimina', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          Divider(
            height: 1,
            thickness: 0.8,
            color: Colors.grey.shade200,
            indent: 80,
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    if (conversation.isGroup) {
      return _buildGroupAvatar();
    }
    return _buildSingleAvatar();
  }

  static Color _getStatusColor(bool isOnline) {
    if (isOnline) return const Color(0xFF4CAF50); // Online - verde
    return const Color(0xFF9E9E9E); // Assente - grigio
  }

  Widget _buildSingleAvatar() {
    final avatarUrl = conversation.avatarUrlFor(currentUserId) ?? conversation.avatarUrl;
    final conversationName = conversation.displayNameFor(currentUserId);
    final isOnline = conversation.isOtherOnlineFor(currentUserId);
    final statusColor = _getStatusColor(isOnline);

    return SizedBox(
      width: 54,
      height: 54,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          UserAvatarWidget(
            avatarUrl: avatarUrl,
            displayName: conversationName,
            size: 52,
            borderWidth: isOnline ? 2.0 : 1.5,
            borderColor: isOnline ? AppColors.primary : AppColors.divider,
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupAvatar() {
    final avatars = conversation.groupAvatars;
    return SizedBox(
      width: 54,
      height: 54,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: _buildMiniAvatar(
              avatars.length > 1 ? avatars[1] : null,
              size: 36,
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.surface,
                  width: 2,
                ),
              ),
              child: _buildMiniAvatar(
                avatars.isNotEmpty ? avatars[0] : null,
                size: 36,
              ),
            ),
          ),
          if (conversation.participants.length > 2)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: AppColors.teal100,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.surface,
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Text(
                    '+${conversation.participants.length - 2}',
                    style: const TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMiniAvatar(String? avatarUrl, {double size = 36}) {
    return ClipOval(
      child: Container(
        width: size,
        height: size,
        color: AppColors.teal50,
        child: avatarUrl != null
            ? Image.network(
                avatarUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                  Icons.person,
                  color: AppColors.primary,
                  size: size * 0.5,
                ),
              )
            : Icon(
                Icons.person,
                color: AppColors.primary,
                size: size * 0.5,
              ),
      ),
    );
  }

  Widget _buildInitialsAvatar() {
    final displayName = conversation.displayNameFor(currentUserId);
    String initials = '';
    final parts = displayName.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      initials = '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    } else if (parts.isNotEmpty && parts[0].isNotEmpty) {
      initials = parts[0][0].toUpperCase();
    } else {
      initials = '?';
    }
    return Container(
      color: AppColors.teal50,
      child: Center(
        child: Text(
          initials,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.primary,
          ),
        ),
      ),
    );
  }
}
