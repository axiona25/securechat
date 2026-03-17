# Deploy Admin Panel — SecureChat
## Guida completa alla pubblicazione dell'Admin Panel React su server

---

## Prerequisiti

- Node.js installato in locale
- Accesso SSH al server: `ssh -i ~/.ssh/axphone_key root@206.189.59.87`
- Trovarsi nella directory del progetto: `/Users/r.amoroso/Documents/Cursor/SecureChat`

---

## Step 1 — Build del frontend React in locale

```bash
cd /Users/r.amoroso/Documents/Cursor/SecureChat/admin-panel
npm install
npm run build
```

> La build viene creata in `admin-panel/build/`  
> Ignorare i warning ESLint — non bloccano il deploy.

---

## Step 2 — Pubblica sul server via rsync

```bash
rsync -avz --delete \
  /Users/r.amoroso/Documents/Cursor/SecureChat/admin-panel/build/ \
  -e "ssh -i ~/.ssh/axphone_key" \
  root@206.189.59.87:/opt/axphone/admin-panel/build/
```

> `--delete` rimuove i file vecchi non più presenti nella nuova build.

---

## Step 3 — Verifica sul browser

Apri: **https://axphone.it/admin-panel/**

---

## Note importanti

### Path Nginx
Il file di configurazione Nginx è:
```
/opt/axphone/nginx/conf.d/default.conf
```
L'admin panel è servito da:
```nginx
location /admin-panel/ {
    alias /opt/axphone/admin-panel/build/;
    try_files $uri $uri/ /admin-panel/index.html;
}
```

### Se mancano dipendenze npm
```bash
cd /Users/r.amoroso/Documents/Cursor/SecureChat/admin-panel
npm install leaflet react-leaflet
npm run build
```

### Se Nginx non aggiorna (cache)
```bash
ssh -i ~/.ssh/axphone_key root@206.189.59.87 \
  "nginx -s reload"
```

---

## Troubleshooting

### Build fallisce per modulo mancante
```bash
cd /Users/r.amoroso/Documents/Cursor/SecureChat/admin-panel
npm install
npm run build
```

### Pagina non aggiornata dopo il deploy
Svuota la cache del browser (Cmd+Shift+R su Mac) oppure:
```bash
ssh -i ~/.ssh/axphone_key root@206.189.59.87 "nginx -s reload"
```

### Verifica che i file siano arrivati sul server
```bash
ssh -i ~/.ssh/axphone_key root@206.189.59.87 \
  "ls -la /opt/axphone/admin-panel/build/"
```

### Verifica configurazione Nginx
```bash
ssh -i ~/.ssh/axphone_key root@206.189.59.87 \
  "nginx -t && echo 'Config OK'"
```

---

## Riepilogo comandi rapidi (copia-incolla)

```bash
# 1. Build
cd /Users/r.amoroso/Documents/Cursor/SecureChat/admin-panel && npm run build

# 2. Deploy
rsync -avz --delete \
  /Users/r.amoroso/Documents/Cursor/SecureChat/admin-panel/build/ \
  -e "ssh -i ~/.ssh/axphone_key" \
  root@206.189.59.87:/opt/axphone/admin-panel/build/

# 3. Reload Nginx (se necessario)
ssh -i ~/.ssh/axphone_key root@206.189.59.87 "nginx -s reload"
```

---

*Ultima modifica: Marzo 2026*
