from django.utils import timezone


class LastSeenMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)
        if hasattr(request, 'user') and request.user.is_authenticated:
            # Update every 5 minutes to avoid excessive DB writes
            now = timezone.now()
            if not request.user.last_seen or (now - request.user.last_seen).seconds > 300:
                request.user.last_seen = now
                request.user.save(update_fields=['last_seen'])
        return response
