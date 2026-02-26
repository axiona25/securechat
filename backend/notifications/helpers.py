"""
Helper functions for sending notifications from other apps.
Import these in chat, calls, channels_pub to trigger notifications easily.

Usage:
    from notifications.helpers import notify_new_message
    notify_new_message(sender_user, conversation, message)
"""
import logging
from .models import NotificationType
from .services import NotificationService

logger = logging.getLogger(__name__)


def _truncate(text, max_length):
    """Truncate text to max_length with ellipsis."""
    if not text:
        return ''
    if len(text) <= max_length:
        return text
    return text[:max_length - 1] + '…'


def notify_new_message(sender, conversation, message):
    """
    Notify all participants of a new message in a conversation.
    Called from chat app when a new message is created.
    For participants with chat locked (is_locked), use generic title/body.
    """
    from chat.models import ConversationParticipant

    participants = ConversationParticipant.objects.filter(
        conversation=conversation,
    ).exclude(
        user=sender,
    ).select_related('user')

    if not participants.exists():
        return

    is_group = conversation.conv_type == 'group'
    group_name = None
    if is_group:
        group_name = getattr(getattr(conversation, 'group_info', None), 'name', None)

    content = (getattr(message, 'content_for_translation', None) or '').strip()
    normal_body = _truncate(content, 100) if content else 'New message'
    target_type = 'group' if is_group else 'conversation'

    for participant in participants:
        # Chat con lucchetto: title e body generici
        if participant.is_locked:
            title = '🔒 SecureChat'
            body = 'You have a new locked message'
        else:
            title = group_name or sender.username
            body = normal_body

        NotificationService.send(
            recipient_id=participant.user_id,
            notification_type=NotificationType.NEW_MESSAGE,
            title=title,
            body=body,
            data={
                'conversation_id': str(conversation.id),
                'message_id': str(message.id),
                'sender_username': sender.username if not participant.is_locked else '',
                'is_group': str(is_group),
                'is_locked': str(participant.is_locked),
            },
            sender_id=sender.id,
            source_type='message',
            source_id=str(message.id),
            target_type=target_type,
            target_id=str(conversation.id),
        )


def notify_message_reaction(reactor, message, emoji):
    """Notify message author of a reaction."""
    if reactor.id == message.sender_id:
        return

    NotificationService.send(
        recipient_id=message.sender_id,
        notification_type=NotificationType.MESSAGE_REACTION,
        title='New Reaction',
        body=f'{reactor.username} reacted {emoji} to your message',
        data={
            'conversation_id': str(message.conversation_id),
            'message_id': str(message.id),
            'emoji': emoji,
        },
        sender_id=reactor.id,
        source_type='message',
        source_id=str(message.id),
    )


def notify_mention(mentioner, conversation, message, mentioned_user_ids):
    """Notify mentioned users in a group message."""
    if not mentioned_user_ids:
        return

    content = (getattr(message, 'content_for_translation', None) or '').strip()
    body_preview = _truncate(content, 80) if content else 'New message'
    group_name = getattr(
        getattr(conversation, 'group_info', None),
        'name',
        None
    )
    title = group_name or 'Group'

    NotificationService.send_to_multiple(
        recipient_ids=mentioned_user_ids,
        notification_type=NotificationType.MENTION,
        title=title,
        body=f'{mentioner.username} mentioned you: {body_preview}',
        data={
            'conversation_id': str(conversation.id),
            'message_id': str(message.id),
        },
        sender_id=mentioner.id,
        source_type='message',
        source_id=str(message.id),
        target_type='group',
        target_id=str(conversation.id),
    )


def notify_incoming_call(caller, call, recipient_ids):
    """
    Notify recipients of an incoming call.
    High priority + data-only (client handles VoIP UI).
    """
    is_video = getattr(call, 'call_type', 'audio') == 'video'
    call_type = 'Video' if is_video else 'Voice'

    NotificationService.send_to_multiple(
        recipient_ids=recipient_ids,
        notification_type=NotificationType.INCOMING_CALL,
        title=f'Incoming {call_type} Call',
        body=f'{caller.username} is calling you',
        data={
            'call_id': str(call.id),
            'caller_id': str(caller.id),
            'caller_username': caller.username,
            'call_type': 'video' if is_video else 'voice',
        },
        sender_id=caller.id,
        source_type='call',
        source_id=str(call.id),
        high_priority=True,
    )


def notify_missed_call(caller, call, recipient_id):
    """Notify a user of a missed call."""
    is_video = getattr(call, 'call_type', 'audio') == 'video'
    call_type = 'video' if is_video else 'voice'

    NotificationService.send(
        recipient_id=recipient_id,
        notification_type=NotificationType.MISSED_CALL,
        title='Missed Call',
        body=f'Missed {call_type} call from {caller.username}',
        data={
            'call_id': str(call.id),
            'caller_id': str(caller.id),
            'caller_username': caller.username,
        },
        sender_id=caller.id,
        source_type='call',
        source_id=str(call.id),
    )


def notify_channel_post(channel, post):
    """
    Notify all non-muted subscribers of a new channel post.
    Called from channels_pub when a post is published.
    """
    from channels_pub.models import ChannelMember

    subscriber_ids = list(
        ChannelMember.objects.filter(
            channel=channel,
            is_banned=False,
            is_muted=False,
        ).exclude(
            role=ChannelMember.Role.OWNER,
        ).exclude(
            user_id=post.author_id,
        ).values_list('user_id', flat=True)
    )

    if not subscriber_ids:
        return

    body = _truncate(post.text, 100) if post.text else f'New {post.post_type} post'

    NotificationService.send_to_multiple(
        recipient_ids=subscriber_ids,
        notification_type=NotificationType.CHANNEL_POST,
        title=f'📢 {channel.name}',
        body=body,
        data={
            'channel_id': str(channel.id),
            'channel_username': channel.username,
            'post_id': str(post.id),
            'post_type': post.post_type,
        },
        sender_id=post.author_id,
        source_type='channel_post',
        source_id=str(post.id),
        target_type='channel',
        target_id=str(channel.id),
    )


def notify_group_invite(inviter, group, invited_user_id):
    """Notify a user they've been invited to a group."""
    NotificationService.send(
        recipient_id=invited_user_id,
        notification_type=NotificationType.GROUP_INVITE,
        title='Group Invitation',
        body=f'{inviter.username} invited you to "{group.name}"',
        data={
            'group_id': str(group.id),
            'group_name': group.name,
            'inviter_username': inviter.username,
        },
        sender_id=inviter.id,
        source_type='group',
        source_id=str(group.id),
    )


def notify_channel_invite(inviter, channel, invited_user_id):
    """Notify a user they've been invited to a channel."""
    NotificationService.send(
        recipient_id=invited_user_id,
        notification_type=NotificationType.CHANNEL_INVITE,
        title='Channel Invitation',
        body=f'{inviter.username} invited you to @{channel.username}',
        data={
            'channel_id': str(channel.id),
            'channel_username': channel.username,
            'inviter_username': inviter.username,
        },
        sender_id=inviter.id,
        source_type='channel',
        source_id=str(channel.id),
    )


def notify_security_alert(user_id, alert_title, alert_body, threat_detection_id=None):
    """
    Notify a user of a security alert from Shield.
    High priority — bypasses DND.
    """
    NotificationService.send(
        recipient_id=user_id,
        notification_type=NotificationType.SECURITY_ALERT,
        title=f'🛡️ {alert_title}',
        body=alert_body,
        data={
            'threat_detection_id': str(threat_detection_id) if threat_detection_id else '',
        },
        source_type='security',
        source_id=str(threat_detection_id) if threat_detection_id else '',
        high_priority=True,
    )
