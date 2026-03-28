"""
Per un utente con un solo telefono reale: tiene il dispositivo con last_seen più recente
e rimuove le altre righe UserDevice (stesso account, ID “IMEI” cambiati nel tempo).
"""
from django.core.management.base import BaseCommand

from accounts.models import User, UserDevice


class Command(BaseCommand):
    help = 'Elimina righe UserDevice duplicate per un utente, mantenendo solo il record più recente.'

    def add_arguments(self, parser):
        parser.add_argument('--email', type=str, required=True, help='Email utente')
        parser.add_argument('--dry-run', action='store_true', help='Solo elenco, nessuna cancellazione')

    def handle(self, *args, **options):
        email = options['email'].strip().lower()
        dry = options['dry_run']
        user = User.objects.filter(email__iexact=email).first()
        if not user:
            self.stderr.write(self.style.ERROR(f'Utente non trovato: {email}'))
            return

        devices = list(UserDevice.objects.filter(user=user).order_by('-last_seen', '-id'))
        if len(devices) <= 1:
            self.stdout.write(self.style.SUCCESS('Nessun duplicato da rimuovere.'))
            return

        keep = devices[0]
        remove = devices[1:]
        self.stdout.write(
            f'Utente {user.email} (id={user.id}): {len(devices)} dispositivi — '
            f'mantengo id={keep.id} imei={keep.imei[:48]}… last_seen={keep.last_seen}'
        )
        for d in remove:
            self.stdout.write(f'  {"[dry] " if dry else ""}rimuovo id={d.id} imei={d.imei[:40]}…')
            if not dry:
                d.delete()

        if dry:
            self.stdout.write(self.style.WARNING('Dry-run: nessuna modifica.'))
        else:
            self.stdout.write(self.style.SUCCESS(f'Rimosse {len(remove)} righe.'))
