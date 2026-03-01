# Codice rilevante: flusso must_change_password / cambio password forzato al primo accesso

Solo il codice legato al controllo del flag, alla modale di cambio password, alla chiamata API e all’endpoint backend. Niente UI puro (layout, colori, padding).

---

## 1. Punto nel login flow dove si controlla must_change_password

**File:** `lib/features/home/home_screen.dart`

Il controllo non avviene nella schermata di login ma **dopo** che l’utente è già loggato e arriva alla Home. In `_loadData()` (chiamata da `initState`), dopo aver caricato conversazioni e utente corrente, si fa una GET al profilo e, se `must_change_password == true`, si mostra la modale non dismissibile.

### Lettura del flag e decisione di mostrare la modale

```dart
Future<void> _loadData() async {
  // ... load conversations, current user, notification count ...
  // setState con _currentUser, _conversations, ecc.

  // Check se deve cambiare password
  if (_currentUser != null) {
    try {
      final token = ApiService().accessToken;
      final response = await http.get(
        Uri.parse('${AppConstants.baseUrl}/auth/profile/'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final profileData = jsonDecode(response.body) as Map<String, dynamic>;
        if (profileData['must_change_password'] == true && mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => ChangePasswordModal(
              onPasswordChanged: () {
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Password aggiornata con successo!'),
                    backgroundColor: Color(0xFF2ABFBF),
                  ),
                );
              },
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error checking must_change_password: $e');
    }
  }
}
```

- **Dove viene letto il flag:** risposta di `GET ${baseUrl}/auth/profile/` → `profileData['must_change_password']`.
- **Dove si decide di mostrare la modale:** se `profileData['must_change_password'] == true && mounted` → `showDialog(..., ChangePasswordModal(onPasswordChanged: ...))`.
- **Callback `onPasswordChanged`:** chiude la modale (`Navigator.of(ctx).pop()`) e mostra uno SnackBar di successo. Non fa nuovo login e non chiama `initializeKeys()`: l’utente è già autenticato; dopo il cambio password il backend risponde con nuovi token e la modale li salva (vedi sotto).

---

## 2. Modale / schermata di cambio password — widget e logica di submit

**File:** `lib/features/auth/widgets/change_password_modal.dart`

### Widget e stato (senza dettagli di layout/colori)

```dart
class ChangePasswordModal extends StatefulWidget {
  final VoidCallback onPasswordChanged;

  const ChangePasswordModal({Key? key, required this.onPasswordChanged}) : super(key: key);

  @override
  State<ChangePasswordModal> createState() => _ChangePasswordModalState();
}

class _ChangePasswordModalState extends State<ChangePasswordModal> {
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _loading = false;
  String? _error;
  // ...
}
```

### Logica di submit (`_changePassword`)

```dart
Future<void> _changePassword() async {
  final newPassword = _newPasswordController.text.trim();
  final confirmPassword = _confirmPasswordController.text.trim();

  if (newPassword.isEmpty || confirmPassword.isEmpty) {
    setState(() => _error = l10n.t('fill_both_fields'));
    return;
  }
  if (newPassword.length < 8) {
    setState(() => _error = l10n.t('password_min_8'));
    return;
  }
  if (newPassword != confirmPassword) {
    setState(() => _error = l10n.t('passwords_dont_match'));
    return;
  }

  setState(() { _loading = true; _error = null; });

  try {
    final api = ApiService();
    final token = api.accessToken;

    final response = await http.post(
      Uri.parse('${AppConstants.baseUrl}/auth/change-password/'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'new_password': newPassword,
        'confirm_password': confirmPassword,
      }),
    );

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode == 200) {
      if (data['access'] != null && data['refresh'] != null) {
        api.setTokens(access: data['access'] as String, refresh: data['refresh'] as String);
      }
      final prefs = await SharedPreferences.getInstance();
      if (data['access'] != null) prefs.setString('access_token', data['access'] as String);
      if (data['refresh'] != null) prefs.setString('refresh_token', data['refresh'] as String);
      if (mounted) widget.onPasswordChanged();
    } else {
      setState(() => _error = data['error']?.toString() ?? l10n.t('error_change_password'));
    }
  } catch (e) {
    setState(() => _error = l10n.t('error_connection'));
  }

  if (mounted) setState(() => _loading = false);
}
```

- Il dialog è `PopScope(canPop: false)` + `Dialog`, quindi non si chiude con back.
- Il pulsante di submit chiama `_changePassword` (disabilitato quando `_loading`).

---

## 3. Cosa succede dopo il submit (API call e flusso client)

**Stesso file:** `lib/features/auth/widgets/change_password_modal.dart` (blocco sopra).

- **API call:** `POST ${baseUrl}/auth/change-password/` con body `{ new_password, confirm_password }` e header `Authorization: Bearer <access_token>`.
- **Se 200:**  
  - Il backend restituisce `access` e `refresh` (nuovi JWT).  
  - Il client aggiorna i token in `ApiService` (`api.setTokens(...)`) e in `SharedPreferences` (`access_token`, `refresh_token`).  
  - Viene chiamato `widget.onPasswordChanged()`: la Home chiude la modale e mostra lo SnackBar “Password aggiornata con successo!”.
- **Non** si fa un nuovo login (form email/password): l’utente resta sulla Home con la stessa sessione, ma con i nuovi token.
- **Non** si chiama esplicitamente `initializeKeys()` dopo il cambio password: le chiavi sono già state inizializzate al login in `AuthService.login()`; il cambio password non tocca quel flusso.

---

## 4. Backend — endpoint di cambio password

**File:** `backend/accounts/views.py`

### View che gestisce il cambio password

```python
class ChangePasswordView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        new_password = request.data.get('new_password', '')
        confirm_password = request.data.get('confirm_password', '')

        if not new_password or len(new_password) < 8:
            return Response({'error': 'La password deve essere di almeno 8 caratteri.'}, status=status.HTTP_400_BAD_REQUEST)

        if new_password != confirm_password:
            return Response({'error': 'Le password non coincidono.'}, status=status.HTTP_400_BAD_REQUEST)

        user = request.user
        user.set_password(new_password)
        user.must_change_password = False
        user.save(update_fields=['password', 'must_change_password'])

        # Genera nuovi token
        from rest_framework_simplejwt.tokens import RefreshToken
        refresh = RefreshToken.for_user(user)

        return Response({
            'message': 'Password aggiornata con successo.',
            'access': str(refresh.access_token),
            'refresh': str(refresh),
        })
```

**File:** `backend/accounts/urls.py`

```python
urlpatterns = [
    # ...
    path('change-password/', views.ChangePasswordView.as_view(), name='change-password'),
]
```

Con il prefisso `api/auth/` (da `backend/config/urls.py`: `path('api/auth/', include('accounts.urls'))`), l’endpoint completo è **`POST /api/auth/change-password/`**.

---

## 5. Dove viene esposto il flag must_change_password (backend)

- **Modello:** `backend/accounts/models.py`  
  `must_change_password = models.BooleanField(default=False)`

- **Profilo (usato dalla Home per il check):** `GET /api/auth/profile/` → `ProfileView` in `backend/accounts/views.py` restituisce `UserProfileSerializer(request.user).data`, che include il campo `must_change_password` (presente in `UserProfileSerializer.Meta.fields` in `backend/accounts/serializers.py`).

---

## Flusso sintetico

1. Utente fa login → arriva alla Home → `_loadData()` viene eseguito.
2. `_loadData()` fa `GET /auth/profile/` e legge `profileData['must_change_password']`.
3. Se `true`, mostra `ChangePasswordModal` con `barrierDismissible: false`.
4. Utente inserisce nuova password e conferma → submit chiama `POST /auth/change-password/` con `new_password` e `confirm_password`.
5. Backend: valida, imposta nuova password, mette `user.must_change_password = False`, salva, genera nuovi JWT e risponde con `access` e `refresh`.
6. Client: salva i nuovi token in ApiService e SharedPreferences, chiama `onPasswordChanged()` → modale si chiude, SnackBar di successo. Nessun nuovo login e nessuna chiamata esplicita a `initializeKeys()`.
