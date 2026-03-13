from celery import shared_task
import logging
logger = logging.getLogger(__name__)

@shared_task(name='chat.send_push_async', bind=True, max_retries=2, default_retry_delay=5)
def send_push_async(self, conversation_id, sender_user_id, push_title, push_body, push_data):
    try:
        from chat.models import Conversation
        from django.contrib.auth import get_user_model
        from chat.push_notifications import send_push_to_conversation_participants
        User = get_user_model()
        conversation = Conversation.objects.get(id=conversation_id)
        sender = User.objects.get(id=sender_user_id)
        send_push_to_conversation_participants(conversation, sender, push_title, push_body, push_data)
    except Exception as e:
        logger.error('[PushAsync] error: %s', e)
        raise self.retry(exc=e)
