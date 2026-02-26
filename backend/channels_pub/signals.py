from django.db.models.signals import post_delete
from django.dispatch import receiver
from django.db.models import F
from .models import PostComment, ChannelPost


@receiver(post_delete, sender=PostComment)
def decrement_comment_count_on_cascade_delete(sender, instance, **kwargs):
    """
    If a comment is deleted via cascade (e.g. post deletion), this ensures
    consistency. For manual deletes, the view already handles the count.
    """
    try:
        ChannelPost.objects.filter(
            id=instance.post_id, comment_count__gt=0
        ).update(comment_count=F('comment_count') - 1)
    except Exception:
        pass
