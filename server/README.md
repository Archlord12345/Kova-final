# KOVA Backend

Backend Express pour le relais parent ↔ enfant KOVA. Il peut tourner en mode :

- **relay-only** : pairing, alertes, historique, ACKs et profil enfant sans PostgreSQL.
- **full** : mêmes endpoints + API PostgreSQL si `DATABASE_URL` est configuré.

## Variables utiles

| Variable | Défaut | Description |
| --- | --- | --- |
| `PORT` | `3000` | Port HTTP utilisé par Render/Railway/local. |
| `NODE_ENV` | - | Mettre `production` sur hébergement. |
| `DATABASE_URL` | - | PostgreSQL optionnel pour les routes DB. |
| `JWT_SECRET` | - | Requis pour les routes auth en mode DB. |
| `CORS_ORIGINS` | `*` | Origines autorisées séparées par virgule. Exemple: `https://app.example.com,capacitor://localhost`. |
| `JSON_BODY_LIMIT` | `256kb` | Limite payload Express. |
| `PAIRING_CODE_TTL_MS` | `900000` | Durée de validité des codes de pairing relay. |
| `MAX_PAIRING_CODES` | `10000` | Limite mémoire des codes relay. |
| `MAX_STORED_ALERTS` | `100` | Alertes en attente par pair token. |
| `MAX_STORED_HISTORY` | `500` | Historiques en attente par pair token. |
| `RELAY_TOKEN_TTL_MS` | `604800000` | TTL des stores relay par pair token. |

## Local

```bash
npm ci --prefix server
npm start --prefix server
curl http://127.0.0.1:3000/api/health
```

## Railway

Le repo contient `railway.toml`, `railway.json` et `nixpacks.toml` configurés pour installer et démarrer uniquement `server` :

- Install: `npm ci --omit=dev --prefix server` (Nixpacks includes `server/package.json` and `server/package-lock.json` before the install layer)
- Build: no-op (`echo 'No build step required for Express backend'`)
- Start: `npm start --prefix server`
- Healthcheck: `/api/health`

## Render

Le fichier `render.yaml` déclare un service web Node avec :

- `rootDir: server`
- Build: `npm ci --omit=dev`
- Start: `npm start`
- Healthcheck: `/api/health`

## Vercel

Le fichier racine `vercel.json` route toutes les requêtes vers `server/src/index.js`, qui exporte l'app Express pour `@vercel/node`.


> Note: le relay utilise un store mémoire. C'est adapté à Railway/Render et aux démos Vercel. Pour un Vercel fortement scalé ou sans pertes au cold-start, ajoutez une base externe (`DATABASE_URL`) ou un KV/Redis et adaptez le store relay.

## Tests

```bash
npm test --prefix server -- --runInBand
```
