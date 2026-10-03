# garden-api

The Cloudflare Worker between the Garden app and Pluggy ([DESIGN.md §13](../docs/DESIGN.md)).
It keeps the Pluggy secrets, pulls Meu Pluggy data on request, and **stores no financial data**. KV holds only:
- the itemId whitelist
- hashes of device tokens
- the ingestion lease
- item fingerprints
- a CNPJ cache

## Deploy to your account (one time)

```bash
cd worker
npm install --legacy-peer-deps
npx wrangler login
npx wrangler secret put PLUGGY_CLIENT_ID      # dashboard.pluggy.ai ▸ Applications
npx wrangler secret put PLUGGY_CLIENT_SECRET
npx wrangler secret put ADMIN_TOKEN           # any long random string; only you use it
npx wrangler deploy                           # creates the KV namespace on first deploy
```

Then pair the app:

```bash
GARDEN_URL=https://garden-api.<your-subdomain>.workers.dev ADMIN_TOKEN=<same value> npm run pair
```

Paste the address and the 8-letter code into **Garden ▸ Ajustes ▸ Bancos (Meu Pluggy)**. The code is single-use and expires in 10 minutes.

Add your connections by itemId on the same screen. In the Pluggy dashboard: **Applications ▸ your app ▸ Demo ▸ Connect account ▸ MeuPluggy**, then copy each bank's item `id`. Do this **before the 15-day dashboard trial ends**.

### Optional: silent pushes

When an item refreshes, the hourly cron can wake the app. This needs an APNs auth key and the app's real bundle id:

```bash
npx wrangler secret put APNS_KEY_P8   # contents of AuthKey_XXXX.p8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
# and set APNS_TOPIC (the bundle id) in wrangler.jsonc vars
```

Without these, the app still syncs on launch, on returning to the foreground, and on pull-to-refresh.

## Develop locally without Pluggy

```bash
cp .dev.vars.example .dev.vars        # set PLUGGY_API_BASE=http://127.0.0.1:8788
npm run dev:mock-pluggy               # fixtures: a Nubank + BTG day, an installment, a saque, a card bill
npm run dev                           # wrangler dev on :8787
npm run pair                          # code for http://127.0.0.1:8787
```

Mock items: `11111111-1111-4111-8111-111111111111` (Nubank) and `22222222-2222-4222-8222-222222222222` (BTG).
`MOCK_DROP=nu-t8 npm run dev:mock-pluggy` makes a transaction disappear, to exercise tombstones.

For a Debug simulator build, launch arguments pair and sync in one go:
`-pairURL http://127.0.0.1:8787 -pairCode <code> -pluggyItems <id1>,<id2>`

## Tests

```bash
npm test        # vitest inside workerd: pairing, auth, whitelist, snapshot cursors, SSRF guard, lease, CNPJ, cron
npm run typecheck
```
