"""
Crea o aggiorna il superuser per l'admin panel (email fissa).

La password NON va mai nel codice: passala solo via ambiente al momento dell'esecuzione.

Esempio (server o locale):
  export AXPHONE_ADMIN_PASSWORD='la-tua-password-sicura'
  python manage.py ensure_axphone_admin

Opzionale:
  python manage.py ensure_axphone_admin --email altro@dominio.it
"""
import os

from django.core.management.base import BaseCommand, CommandError

from accounts.models import User

DEFAULT_EMAIL = 'admin@axphone.it'
ENV_PASSWORD = 'AXPHONE_ADMIN_PASSWORD'


class Command(BaseCommand):
    help = 'Crea/aggiorna superuser admin (default email admin@axphone.it); password da $AXPHONE_ADMIN_PASSWORD'

    def add_arguments(self, parser):
        parser.add_argument(
            '--email',
            default=DEFAULT_EMAIL,
            help=f'Email del superuser (default: {DEFAULT_EMAIL})',
        )

    def handle(self, *args, **options):
        email = (options['email'] or DEFAULT_EMAIL).strip().lower()
        password = os.environ.get(ENV_PASSWORD)
        if not password:
            raise CommandError(
                f'Imposta la variabile d\'ambiente {ENV_PASSWORD} con la password desiderata '
                f'(non committare mai la password nel repository).'
            )

        username = email.split('@')[0] or 'admin'
        user, created = User.objects.get_or_create(
            email=email,
            defaults={
                'username': username,
                'first_name': 'Admin',
                'last_name': 'AXPhone',
                'is_staff': True,
                'is_superuser': True,
                'is_verified': True,
                'approval_status': 'approved',
            },
        )
        if not created:
            user.username = username
            user.is_staff = True
            user.is_superuser = True
            user.is_verified = True
            user.approval_status = 'approved'

        user.set_password(password)
        user.save()

        action = 'Creato' if created else 'Aggiornato'
        self.stdout.write(self.style.SUCCESS(f'{action} superuser: {email} (staff + superuser + approved)'))
