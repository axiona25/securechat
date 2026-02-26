"""
Crea gli utenti di test per sviluppo: testuser1, testuser2, testuser3.
Stessa mail @securechat.test e password simili (TestPass123!, TestPass456!, TestPass789!).

Uso: python manage.py create_test_users
"""
from django.core.management.base import BaseCommand
from accounts.models import User


TEST_USERS = [
    {
        'username': 'testuser1',
        'email': 'testuser1@securechat.test',
        'password': 'TestPass123!',
        'first_name': 'Alice',
        'last_name': 'Test',
    },
    {
        'username': 'testuser2',
        'email': 'testuser2@securechat.test',
        'password': 'TestPass456!',
        'first_name': 'Bob',
        'last_name': 'Test',
    },
    {
        'username': 'testuser3',
        'email': 'testuser3@securechat.test',
        'password': 'TestPass789!',
        'first_name': 'Charlie',
        'last_name': 'Test',
    },
]


class Command(BaseCommand):
    help = 'Crea utenti di test (testuser1, testuser2, testuser3) con email @securechat.test'

    def handle(self, *args, **options):
        for data in TEST_USERS:
            email = data['email']
            user, created = User.objects.get_or_create(
                email=email,
                defaults={
                    'username': data['username'],
                    'first_name': data['first_name'],
                    'last_name': data['last_name'],
                    'is_verified': True,
                },
            )
            user.set_password(data['password'])
            user.save(update_fields=['password'])
            if created:
                self.stdout.write(self.style.SUCCESS(f'Creato: {email}'))
            else:
                self.stdout.write(f'Aggiornato: {email} (password reimpostata)')
        self.stdout.write(self.style.SUCCESS('Utenti di test pronti.'))
