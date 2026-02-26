from django.core.management.base import BaseCommand
from accounts.models import User


class Command(BaseCommand):
    help = 'Reset all users to offline (e.g. on server boot)'

    def handle(self, *args, **options):
        updated = User.objects.filter(is_online=True).update(is_online=False)
        self.stdout.write(self.style.SUCCESS(f'All users set to offline (updated {updated} rows)'))
