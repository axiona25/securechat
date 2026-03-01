from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAdminUser
from rest_framework import status
from django.db.models import Count, Q
from django.contrib.auth.hashers import make_password
from django.utils.crypto import get_random_string
from django.core.mail import send_mail
from django.conf import settings
from accounts.models import User
from chat.models import Conversation, Message
from .models import AdminGroup, AdminGroupMembership
from .authentication import AdminJWTAuthentication
import logging

logger = logging.getLogger(__name__)

ADMIN_AUTH = [AdminJWTAuthentication]


def get_email_html(user_name, user_email, temp_password, is_new_user=True):
    """Genera template HTML professionale per email SecureChat."""
    title = "Benvenuto in SecureChat!" if is_new_user else "Password Aggiornata"
    subtitle = "Il tuo account è stato creato dall'amministratore." if is_new_user else "La tua password è stata aggiornata dall'amministratore."

    return f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{title}</title>
</head>
<body style="margin:0;padding:0;background-color:#F4F7FA;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background-color:#F4F7FA;padding:40px 20px;">
<tr><td align="center">
<table role="presentation" width="520" cellspacing="0" cellpadding="0" style="background-color:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 4px 24px rgba(0,0,0,0.06);">

  <!-- Header con logo -->
  <tr>
    <td style="background:linear-gradient(135deg,#2ABFBF 0%,#1FA3A3 50%,#178F8F 100%);padding:36px 40px;text-align:center;">
      <table role="presentation" cellspacing="0" cellpadding="0" style="margin:0 auto;">
        <tr>
          <td style="width:44px;height:44px;background:rgba(255,255,255,0.2);border-radius:12px;text-align:center;vertical-align:middle;">
            <span style="color:#ffffff;font-size:22px;font-weight:bold;">&#9878;</span>
          </td>
          <td style="padding-left:14px;">
            <span style="color:#ffffff;font-size:24px;font-weight:800;letter-spacing:-0.3px;">Secure</span><span style="color:rgba(255,255,255,0.85);font-size:24px;font-weight:800;">Chat</span>
          </td>
        </tr>
      </table>
      <div style="color:rgba(255,255,255,0.7);font-size:12px;letter-spacing:1.5px;text-transform:uppercase;margin-top:12px;">Messaggistica Sicura End-to-End</div>
    </td>
  </tr>

  <!-- Titolo -->
  <tr>
    <td style="padding:36px 40px 0;">
      <h1 style="margin:0;font-size:24px;font-weight:800;color:#1A2B3C;letter-spacing:-0.3px;">{title}</h1>
      <p style="margin:8px 0 0;font-size:15px;color:#7B8794;line-height:1.5;">{subtitle}</p>
    </td>
  </tr>

  <!-- Info utente -->
  <tr>
    <td style="padding:28px 40px 0;">
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#F8FAFB;border-radius:12px;border:1px solid #E8ECF0;">
        <tr>
          <td style="padding:20px 24px;">
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0">
              <tr>
                <td style="padding-bottom:14px;border-bottom:1px solid #E8ECF0;">
                  <div style="font-size:11px;text-transform:uppercase;letter-spacing:0.5px;color:#7B8794;font-weight:600;margin-bottom:4px;">Nome</div>
                  <div style="font-size:15px;font-weight:600;color:#1A2B3C;">{user_name}</div>
                </td>
              </tr>
              <tr>
                <td style="padding:14px 0;border-bottom:1px solid #E8ECF0;">
                  <div style="font-size:11px;text-transform:uppercase;letter-spacing:0.5px;color:#7B8794;font-weight:600;margin-bottom:4px;">Email</div>
                  <div style="font-size:15px;font-weight:600;color:#1A2B3C;">{user_email}</div>
                </td>
              </tr>
              <tr>
                <td style="padding-top:14px;">
                  <div style="font-size:11px;text-transform:uppercase;letter-spacing:0.5px;color:#7B8794;font-weight:600;margin-bottom:8px;">Password Temporanea</div>
                  <div style="background:linear-gradient(135deg,#2ABFBF 0%,#1FA3A3 100%);color:#ffffff;font-size:18px;font-weight:800;letter-spacing:2px;padding:14px 20px;border-radius:10px;text-align:center;font-family:'Courier New',monospace;">{temp_password}</div>
                </td>
              </tr>
            </table>
          </td>
        </tr>
      </table>
    </td>
  </tr>

  <!-- Avviso cambio password -->
  <tr>
    <td style="padding:20px 40px 0;">
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#FFF8E1;border-radius:10px;border:1px solid #FFE082;">
        <tr>
          <td style="padding:14px 18px;">
            <div style="font-size:13px;color:#F57F17;font-weight:600;">&#9888;&#65039; Al primo accesso ti verrà chiesto di cambiare la password.</div>
          </td>
        </tr>
      </table>
    </td>
  </tr>

  <!-- Download App Button -->
  <tr>
    <td style="padding:28px 40px 0;text-align:center;">
      <a href="https://securechat.app/download" style="display:inline-block;background:linear-gradient(135deg,#2ABFBF 0%,#1FA3A3 100%);color:#ffffff;text-decoration:none;font-size:16px;font-weight:700;padding:14px 40px;border-radius:12px;letter-spacing:0.3px;">Scarica SecureChat</a>
    </td>
  </tr>

  <!-- Store badges -->
  <tr>
    <td style="padding:16px 40px 0;text-align:center;">
      <table role="presentation" cellspacing="0" cellpadding="0" style="margin:0 auto;">
        <tr>
          <td style="padding:0 6px;">
            <a href="https://apps.apple.com/app/securechat" style="display:inline-block;background:#1A2B3C;color:#fff;text-decoration:none;font-size:12px;font-weight:600;padding:8px 16px;border-radius:8px;">
              &#63743; App Store
            </a>
          </td>
          <td style="padding:0 6px;">
            <a href="https://play.google.com/store/apps/details?id=com.securechat" style="display:inline-block;background:#1A2B3C;color:#fff;text-decoration:none;font-size:12px;font-weight:600;padding:8px 16px;border-radius:8px;">
              &#9654; Google Play
            </a>
          </td>
        </tr>
      </table>
    </td>
  </tr>

  <!-- Footer -->
  <tr>
    <td style="padding:32px 40px;text-align:center;">
      <div style="height:1px;background:#E8ECF0;margin-bottom:24px;"></div>
      <div style="font-size:12px;color:#7B8794;line-height:1.6;">
        Questa email è stata inviata automaticamente dal sistema SecureChat.<br>
        Se non hai richiesto questo account, ignora questa email.<br><br>
        <span style="color:#2ABFBF;font-weight:600;">SecureChat</span> — Comunicazione Sicura End-to-End<br>
        <span style="font-size:11px;color:#A0ADB8;">© 2026 SecureChat. Tutti i diritti riservati.</span>
      </div>
    </td>
  </tr>

</table>
</td></tr>
</table>
</body>
</html>"""


class AdminDashboardStatsView(APIView):
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def get(self, request):
        total_users = User.objects.filter(is_staff=False).count()
        total_groups = AdminGroup.objects.count()
        total_chats = Conversation.objects.count()
        total_messages = Message.objects.count()
        online_users = User.objects.filter(is_online=True, is_staff=False).count()
        pending_users = User.objects.filter(approval_status='pending', is_staff=False).count()

        return Response({
            'total_users': total_users,
            'total_groups': total_groups,
            'total_chats': total_chats,
            'total_messages': total_messages,
            'total_calls': 0,
            'online_users': online_users,
            'pending_users': pending_users,
        })


class AdminUsersListView(APIView):
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def get(self, request):
        users = User.objects.filter(is_staff=False).order_by('-date_joined')
        data = []
        for u in users:
            groups = AdminGroup.objects.filter(memberships__user=u, is_active=True)
            data.append({
                'id': u.id,
                'username': u.username,
                'first_name': u.first_name,
                'last_name': u.last_name,
                'email': u.email,
                'avatar': u.avatar.url if u.avatar else None,
                'is_active': u.is_active,
                'is_online': u.is_online,
                'is_verified': u.is_verified,
                'approval_status': getattr(u, 'approval_status', 'pending'),
                'must_change_password': getattr(u, 'must_change_password', False),
                'date_joined': u.date_joined.isoformat(),
                'last_seen': u.last_seen.isoformat() if u.last_seen else None,
                'groups': [{'id': g.id, 'name': g.name} for g in groups],
            })
        return Response(data)


class AdminCreateUserView(APIView):
    """Crea un nuovo utente e invia email con credenziali temporanee."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def post(self, request):
        email = request.data.get('email', '').lower().strip()
        first_name = request.data.get('first_name', '').strip()
        last_name = request.data.get('last_name', '').strip()

        if not email:
            return Response({'error': 'Email obbligatoria'}, status=status.HTTP_400_BAD_REQUEST)

        if User.objects.filter(email=email).exists():
            return Response({'error': 'Email già registrata'}, status=status.HTTP_400_BAD_REQUEST)

        # Genera password temporanea
        temp_password = get_random_string(10, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%')
        username = email.split('@')[0]
        # Assicura username univoco
        base_username = username
        counter = 1
        while User.objects.filter(username=username).exists():
            username = f"{base_username}{counter}"
            counter += 1

        approval = request.data.get('approval_status', 'approved')
        user = User.objects.create(
            username=username,
            email=email,
            first_name=first_name,
            last_name=last_name,
            password=make_password(temp_password),
            is_verified=True,
            is_active=approval != 'blocked',
            approval_status=approval,
            must_change_password=True,
        )

        # Invia email con credenziali
        try:
            from django.core.mail import EmailMultiAlternatives

            user_name = f"{first_name} {last_name}".strip() or username
            html_content = get_email_html(user_name, email, temp_password, is_new_user=True)

            msg = EmailMultiAlternatives(
                subject='SecureChat - Il tuo account è stato creato',
                body=f'Ciao {user_name}, il tuo account SecureChat è stato creato. Email: {email} - Password temporanea: {temp_password}',
                from_email=settings.DEFAULT_FROM_EMAIL,
                to=[email],
            )
            msg.attach_alternative(html_content, "text/html")
            result = msg.send(fail_silently=False)
            email_sent = result > 0
        except Exception as e:
            logger.error(f"Email send error: {e}")
            email_sent = False

        return Response({
            'id': user.id,
            'username': user.username,
            'email': user.email,
            'temp_password': temp_password,
            'email_sent': email_sent,
            'message': f'Utente creato. Password temporanea: {temp_password}',
        }, status=status.HTTP_201_CREATED)


class AdminUpdateUserView(APIView):
    """Aggiorna un utente esistente."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def patch(self, request, user_id):
        try:
            user = User.objects.get(id=user_id, is_staff=False)
        except User.DoesNotExist:
            return Response({'error': 'Utente non trovato'}, status=status.HTTP_404_NOT_FOUND)

        for field in ['first_name', 'last_name', 'email', 'approval_status']:
            if field in request.data:
                setattr(user, field, request.data[field])

        # Se bloccato, disattiva anche l'account e invalida le sessioni
        if request.data.get('approval_status') == 'blocked':
            user.is_active = False
            user.is_online = False
        elif request.data.get('approval_status') == 'approved':
            user.is_active = True

        user.save()

        # Se bloccato, invalida tutti i token JWT
        if request.data.get('approval_status') == 'blocked':
            try:
                from rest_framework_simplejwt.token_blacklist.models import OutstandingToken, BlacklistedToken
                tokens = OutstandingToken.objects.filter(user=user)
                for token in tokens:
                    BlacklistedToken.objects.get_or_create(token=token)
            except Exception:
                pass

        return Response({'message': 'Utente aggiornato'})

    def delete(self, request, user_id):
        try:
            user = User.objects.get(id=user_id, is_staff=False)
        except User.DoesNotExist:
            return Response({'error': 'Utente non trovato'}, status=status.HTTP_404_NOT_FOUND)

        user_email = user.email
        user_name = f"{user.first_name} {user.last_name}"

        # Invalida tutti i token JWT
        try:
            from rest_framework_simplejwt.token_blacklist.models import OutstandingToken, BlacklistedToken
            tokens = OutstandingToken.objects.filter(user=user)
            for token in tokens:
                BlacklistedToken.objects.get_or_create(token=token)
        except Exception:
            pass

        # Elimina tutti i messaggi dell'utente
        try:
            from chat.models import Message, ConversationParticipant
            Message.objects.filter(sender=user).delete()
            ConversationParticipant.objects.filter(user=user).delete()
        except Exception:
            pass

        # Rimuovi da tutti i gruppi admin
        try:
            from admin_api.models import AdminGroupMembership
            AdminGroupMembership.objects.filter(user=user).delete()
        except Exception:
            pass

        # Elimina chiavi di cifratura
        try:
            from encryption.models import UserKeyPair
            UserKeyPair.objects.filter(user=user).delete()
        except Exception:
            pass

        # Elimina l'utente definitivamente
        user.delete()

        return Response({
            'message': f'Utente {user_name} ({user_email}) eliminato definitivamente con tutti i dati associati.',
        })


class AdminResetPasswordView(APIView):
    """Reset password di un utente."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def post(self, request, user_id):
        try:
            user = User.objects.get(id=user_id, is_staff=False)
        except User.DoesNotExist:
            return Response({'error': 'Utente non trovato'}, status=status.HTTP_404_NOT_FOUND)

        temp_password = get_random_string(10, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%')
        user.password = make_password(temp_password)
        user.must_change_password = True
        user.save(update_fields=['password', 'must_change_password'])

        email_sent = False
        email_error = None
        try:
            from django.core.mail import EmailMultiAlternatives

            user_name = f"{user.first_name} {user.last_name}".strip() or user.username
            html_content = get_email_html(user_name, user.email, temp_password, is_new_user=False)

            msg = EmailMultiAlternatives(
                subject='SecureChat - La tua password è stata aggiornata',
                body=f'Ciao {user_name}, la tua password SecureChat è stata aggiornata. Email: {user.email} - Nuova password: {temp_password}',
                from_email=settings.DEFAULT_FROM_EMAIL,
                to=[user.email],
            )
            msg.attach_alternative(html_content, "text/html")
            result = msg.send(fail_silently=False)
            email_sent = result > 0
        except Exception as e:
            email_error = str(e)
            logger.error(f"Email send error for user {user.email}: {e}")

        return Response({
            'temp_password': temp_password,
            'message': f'Password resettata. Nuova password: {temp_password}',
        })


class AdminUserSyncGroupsView(APIView):
    """Sincronizza i gruppi di un utente: rimuove dai vecchi e aggiunge ai nuovi."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def post(self, request, user_id):
        try:
            user = User.objects.get(id=user_id, is_staff=False)
        except User.DoesNotExist:
            return Response({'error': 'Utente non trovato'}, status=status.HTTP_404_NOT_FOUND)

        group_ids = request.data.get('group_ids', [])

        # Rimuovi da tutti i gruppi attuali
        AdminGroupMembership.objects.filter(user=user).delete()

        # Aggiungi ai nuovi gruppi
        added = 0
        for gid in group_ids:
            try:
                group = AdminGroup.objects.get(id=gid)
                AdminGroupMembership.objects.create(user=user, group=group)
                added += 1
            except AdminGroup.DoesNotExist:
                continue
            except Exception:
                continue

        return Response({
            'message': f'Utente aggiornato: assegnato a {added} gruppi.',
            'groups': added,
        })


class AdminGroupsListView(APIView):
    """Lista e creazione gruppi organizzativi."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def get(self, request):
        groups = AdminGroup.objects.annotate(
            member_count=Count('memberships'),
        ).order_by('-created_at')

        data = []
        for g in groups:
            members = []
            for m in g.memberships.select_related('user').all():
                u = m.user
                members.append({
                    'id': u.id,
                    'first_name': u.first_name,
                    'last_name': u.last_name,
                    'email': u.email,
                    'avatar': u.avatar.url if u.avatar else None,
                    'is_online': u.is_online,
                })
            data.append({
                'id': g.id,
                'name': g.name,
                'description': g.description,
                'is_active': g.is_active,
                'member_count': g.member_count,
                'members': members,
                'created_at': g.created_at.isoformat(),
            })
        return Response(data)

    def post(self, request):
        name = request.data.get('name', '').strip()
        description = request.data.get('description', '').strip()

        if not name:
            return Response({'error': 'Nome gruppo obbligatorio'}, status=status.HTTP_400_BAD_REQUEST)

        if AdminGroup.objects.filter(name=name).exists():
            return Response({'error': 'Nome gruppo già esistente'}, status=status.HTTP_400_BAD_REQUEST)

        group = AdminGroup.objects.create(name=name, description=description)
        return Response({
            'id': group.id,
            'name': group.name,
            'description': group.description,
            'message': 'Gruppo creato',
        }, status=status.HTTP_201_CREATED)


class AdminGroupDetailView(APIView):
    """Aggiorna o elimina un gruppo."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def patch(self, request, group_id):
        try:
            group = AdminGroup.objects.get(id=group_id)
        except AdminGroup.DoesNotExist:
            return Response({'error': 'Gruppo non trovato'}, status=status.HTTP_404_NOT_FOUND)

        for field in ['name', 'description', 'is_active']:
            if field in request.data:
                setattr(group, field, request.data[field])
        group.save()
        return Response({'message': 'Gruppo aggiornato'})

    def delete(self, request, group_id):
        try:
            group = AdminGroup.objects.get(id=group_id)
        except AdminGroup.DoesNotExist:
            return Response({'error': 'Gruppo non trovato'}, status=status.HTTP_404_NOT_FOUND)

        group_name = group.name
        member_count = group.memberships.count()

        # Elimina tutte le membership
        group.memberships.all().delete()
        # Elimina il gruppo
        group.delete()

        return Response({
            'message': f'Gruppo "{group_name}" eliminato definitivamente con {member_count} membership associate.',
        })


class AdminGroupAssignUsersView(APIView):
    """Assegna utenti a un gruppo."""
    authentication_classes = ADMIN_AUTH
    permission_classes = [IsAdminUser]

    def post(self, request, group_id):
        try:
            group = AdminGroup.objects.get(id=group_id)
        except AdminGroup.DoesNotExist:
            return Response({'error': 'Gruppo non trovato'}, status=status.HTTP_404_NOT_FOUND)

        user_ids = request.data.get('user_ids', [])
        if not user_ids:
            return Response({'error': 'Nessun utente selezionato'}, status=status.HTTP_400_BAD_REQUEST)

        added = 0
        for uid in user_ids:
            try:
                user = User.objects.get(id=uid, is_staff=False)
                _, created = AdminGroupMembership.objects.get_or_create(user=user, group=group)
                if created:
                    added += 1
                    # Se l'utente era pending, approvalo
                    if getattr(user, 'approval_status', None) == 'pending':
                        user.approval_status = 'approved'
                        user.save(update_fields=['approval_status'])
            except User.DoesNotExist:
                continue

        return Response({
            'message': f'{added} utenti assegnati al gruppo {group.name}',
            'added': added,
        })

    def delete(self, request, group_id):
        """Rimuovi un utente dal gruppo."""
        try:
            group = AdminGroup.objects.get(id=group_id)
        except AdminGroup.DoesNotExist:
            return Response({'error': 'Gruppo non trovato'}, status=status.HTTP_404_NOT_FOUND)

        user_id = request.data.get('user_id')
        if not user_id:
            return Response({'error': 'user_id obbligatorio'}, status=status.HTTP_400_BAD_REQUEST)

        AdminGroupMembership.objects.filter(user_id=user_id, group=group).delete()
        return Response({'message': 'Utente rimosso dal gruppo'})
