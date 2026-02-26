import logging
from celery import shared_task
from django.utils import timezone
from django.db.models import Q
from channels.layers import get_channel_layer
from asgiref.sync import async_to_sync

logger = logging.getLogger(__name__)


@shared_task(name='channels_pub.broadcast_new_post')
def broadcast_new_post(post_id):
    """Send a new post to all WebSocket subscribers of the channel."""
    from .models import ChannelPost
    from .serializers import ChannelPostListSerializer

    try:
        post = ChannelPost.objects.select_related('author', 'channel').prefetch_related('poll__options').get(id=post_id)
    except ChannelPost.DoesNotExist:
        logger.warning(f'broadcast_new_post: post {post_id} not found')
        return

    serializer = ChannelPostListSerializer(post)
    channel_layer = get_channel_layer()
    group_name = f'channel_{post.channel_id}'

    async_to_sync(channel_layer.group_send)(
        group_name,
        {
            'type': 'channel_new_post',
            'post': serializer.data,
        }
    )
    logger.info(f'Broadcast post {post_id} to group {group_name}')


@shared_task(name='channels_pub.publish_scheduled_posts')
def publish_scheduled_posts():
    """
    Celery beat task: publishes all scheduled posts whose scheduled_at has passed.
    Should run every minute via Celery Beat.
    """
    from .models import ChannelPost

    now = timezone.now()
    posts = ChannelPost.objects.filter(
        is_scheduled=True,
        is_published=False,
        scheduled_at__lte=now,
    )
    count = 0
    for post in posts:
        post.is_published = True
        post.is_scheduled = False
        post.save(update_fields=['is_published', 'is_scheduled'])
        broadcast_new_post.delay(str(post.id))
        count += 1

    if count > 0:
        logger.info(f'Published {count} scheduled posts')


@shared_task(name='channels_pub.update_subscriber_counts')
def update_subscriber_counts():
    """
    Periodic task to recalculate and sync subscriber_count for all channels.
    Run daily or hourly via Celery Beat.
    """
    from .models import Channel, ChannelMember
    from django.db.models import Count

    channels = Channel.objects.filter(is_active=True).annotate(
        real_count=Count('members', filter=Q(members__is_banned=False))
    )
    updated = 0
    for ch in channels:
        if ch.subscriber_count != ch.real_count:
            Channel.objects.filter(id=ch.id).update(subscriber_count=ch.real_count)
            updated += 1

    if updated > 0:
        logger.info(f'Updated subscriber_count for {updated} channels')
