# Design review log (2026-10-03)

Three independent review agents judged design v0.1. Each finding below is listed with the decision taken in v0.2.

## U · Tap-count & HIG auditor

| ID | Finding | Decision |
|---|---|---|
| U1 | The Mapa tab doesn't earn its spot: its data is incomplete and it's used weekly. Search had no fast path. | Map → Movimentações toolbar toggle plus an Início hotspot card. The freed tab becomes **Buscar** (`Tab(role: .search)`). |
| U2 | "Tudo certo" accepted low-confidence rows the user hadn't seen, and the widget accepted them blind. | Bulk accept covers **high-confidence only**. The widget just opens the review screen. |
| U3 | Submenus (▸) made F6 and F9 take 3 taps. | The top 3 limits sit inline in context and badge menus. Mac uses number keys. |
| U4 | F1's nearby-place chips loaded late and shifted. The account was hidden, and the decimal pad has no Return key. | Chip order is stable (recent merchants first, nearby places appended). The account chip sits in the header, with a Salvar button above the keyboard. |
| U5 | A Shortcuts dialog can't carry buttons; notification actions are fixed. | The extension posts its own notification with actions. ⚠️ A spike is needed; fallback is a static action. |
| U6 | F10 was really 5–7 taps. | Parse "PARC n/N" and match repeat payments, then suggest the plan in review (1 tap). |
| U7 | F11 was really 3–4 taps. | Register the `.ofx` file type. Import straight away when the account matches, with an undo toast. |
| U8 | The map misleads, because only captures have a location. | The caption shows coverage ("62 % com local"), next to a ranked list. |
| U9 | Mac had no multi-select and no inspector. | `List(selection:)` with bulk actions, the inspector for detail, a menu listing every key shortcut, and a Settings scene opened with ⌘,. |
| U10 | Claimed `allowedExecutionTargets` doesn't exist. | **Rejected:** `allowedExecutionTargets: IntentExecutionTargets` is in the iOS 27 SDK swiftinterface. |
| U11 | The iOS 27 notification trigger is unverified. | **Accepted as a risk.** Added as a Phase 0 spike, and DESIGN §2.2 flags it. |

## P · Brazilian user personas (Ana, Seu Carlos, Júlia)

| ID | Finding | Decision |
|---|---|---|
| P1 | Racha reimbursements counted as income, which broke Sobra. | **Linked transactions** (`reimbursement`, `refund`, `cashback`, `fee`) and **net cost**. F15 Dividi a conta added. |
| P2 | A 10x purchase captured by Apple Pay was counted twice. | Reconciliation matches the capture to parcel × N or `totalAmount`, and the capture becomes the plan header. |
| P3 | A saque counted as spending, and the cash spending counted again. | Saque becomes a transfer to **Carteira**. Lançar defaults to Carteira for 3 days after one. |
| P4 | No bills (boleto, Pix agendado, Pix Automático); Upcoming was empty. | **Contas a pagar**, built from several sources (DESIGN §9). |
| P5 | No fatura view; rotativo not handled. | Fatura view; partial payment becomes a liability; interest goes to Juros e tarifas. |
| P6 | `expectedIncome` was undefined; 13º and two-part salary not handled. | Months follow the **pay cycle**. Extra income (renda extra) is kept out of the baseline. Sobra has a plan mode and an income mode. |
| P7 | Business and personal money mixed (Carlos). | The `space` field is in the model now. The UI is in the *Later* phase. |
| P8 | Shared household (Júlia). | A Person can be marked *household*. A shared CloudKit budget comes *Later*. |
| P9 | Long-press-only actions and the AX sizes. | Every hidden action also appears as a visible button. AX5 verification is in Phase 5. |
| P10 | Copy: Gastos, Orçamentos, Patrimônio, Livre para gastar. | Renamed to Movimentações, Planejamento/Limites, Meu dinheiro, Sobra do mês (DESIGN §17). |
| P11 | Setup is impossible for non-developers. | Accepted. Meu Pluggy's personal-use terms make Garden a self-hosted app for now. Manual + OFX mode stays useful on its own. |

## C · Data correctness & security

| ID | Sev | Finding | Decision |
|---|---|---|---|
| C1 | Crit | Several devices ingesting created CloudKit duplicates and conflicting merges. | Single-writer **lease**, **UUIDv5** ids, deterministic survivor after each import, and reconciliation run on every insert or import. |
| C2 | Crit | The dedupeKey merged both sides of an own Pix, broke when the Pluggy account changed, depended on `ordinalWithinDay`, and changed when PENDING became POSTED. | `provenanceKeys[]` on a stable account id plus direction. PENDING is provisional. Deletes become tombstones. |
| C3 | Crit | Following `createdTransactionsLink` from an unsigned webhook could leak the API key. | **Webhook removed.** Hourly cron with a `lastUpdatedAt` fingerprint, and only hard-coded hosts are called. |
| C4 | Crit | `TRANSFERENCIA_MESMA_INSTITUICAO` and mirrored amounts hid real spending. | Signals now in order: E2E pair → own counterparty account → CPF + name + known account. Mirrored amounts only go to review. |
| C5 | High | Parcels were counted 2–3 times across capture, commitment and spending. | Commitments exclude linked parcels and full-at-purchase plans. |
| C6 | High | Net worth subtracted twice (card balance plus parcels; loans plus plans; account plus holdings). | One source per liability; investments at net value; snapshots keyed by day. |
| C7 | High | Reconciliation: two coffees, declined then retried, two automations, FX/IOF, tips, wrong parses. | 1:1 matching, capture-to-capture dedupe, FX ±8 %, tip rule, strict parsers. *(Later the user chose both triggers on every card, so capture-to-capture dedupe merges them instead of a one-source rule.)* |
| C8 | High | Invoice payment counted as a transfer when the card isn't tracked, so its spending vanished. | Counted as an expense on "Cartão (não conectado)". |
| C9 | High | A salted SHA-256 of a CPF can be brute-forced; D1 kept plaintext financial data. | HMAC with a key held in the device Keychain. No financial data stored on Cloudflare. Single-use, rate-limited pairing code. |
| C10 | Med | Masked-CPF false positives (relatives). | Full name **and** a previously seen account must match; otherwise it asks "É você mesmo?". |
| C11 | Med | The 6-hourly 30-day re-pull was wasteful; the KV apiKey cache raced; silent pushes are dropped. | Pull only when `lastUpdatedAt` changes. apiKey cached in memory with re-auth on 401. Foreground + BGAppRefresh as fallbacks. |
| C13 | Med | D1, the Queue and the webhook were over-engineered for one user. | Removed. The Worker is a stateless proxy plus KV. |
