# Probe notes: The X Subscription (Grok + Cursor + X)

Date: 2026-10-15  
Status: **research only** — no UI change yet. Account under test is **not** on the new plan (`cursorMerged: false`).

## Why this matters for Grok Usage

Today the app shows **two meters**:

1. **SuperGrok** — `cli-chat-proxy.grok.com` weekly credits (+ product breakdown)
2. **Grok Bot** — Cursor `GetSandUsageStatus` weekly pool (often linked from SuperGrok)

**The X Subscription** (announced 2026-10-12) sells Grok, Grok Bot, Cursor, and X Premium as **one plan** with **one shared weekly usage pool** across Grok apps and Cursor (including Grok Bot on Premium+). If we keep two independent meters after merge, users will see confusing double counting or mismatched labels.

We do **not** need to buy the new plan just to start. Existing APIs already expose a merge flag on the legacy account.

---

## Public plan ladder (official Cursor docs / pricing)

| Tier | Price | Included usage | Grok Bot | Notes |
|------|-------|----------------|----------|-------|
| Free | $0 | Limited | No | Starter Cursor + daily Grok |
| Plus | $8/mo | Base (1×) | No | Grok + Cursor first-party models |
| Premium | $30/mo | 4× Plus | Yes | Replaces SuperGrok + Cursor Pro + X Premium+ bundle pitch |
| Super | $100/mo | 15× Plus | Yes | Priority at peak |
| Ultra | $200/mo | 50× Plus | Yes | Earliest access |

Paid tiers: **one weekly pool** shared by editor Agent, CLI, Cloud Agents, **Grok Bot**, and Grok apps. Third-party models (Claude/GPT, etc.) stay **API list price** from prepaid credit on Premium+.

Legacy SuperGrok / Cursor / X Premium can stay as-is; switching is optional (and reportedly permanent once accounts are combined). New customers buy only The X Subscription.

Sources: [cursor.com/docs/models-and-pricing](https://cursor.com/docs/models-and-pricing), [cursor.com/pricing](https://cursor.com/pricing), SpaceXSI / xAI announcements (2026-10-12).

---

## What our app already reads

### SuperGrok (`UsageFetcher`)

| Endpoint | Used fields today |
|----------|-------------------|
| `GET …/v1/billing?format=credits` | `creditUsagePercent`, period, `productUsage[]`, prepaid, on-demand, `isUnifiedBillingUser` |
| `GET …/v1/user?include=subscription` | `subscriptionTier` → UI plan name |

### Bot (`BotUsageFetcher`)

| Endpoint | Used fields today |
|----------|-------------------|
| `POST …/GetSandUsageStatus` | `usagePercent`, period, `grokPlanLabel`, `cursorPlanName`, `hasAvailableUsage` |
| `GetSandAccessStatus` / `GetHardLimit` / `usage-summary` | access + on-demand |

### Plan display mapping (`Models.swift`)

- `GrokPro` → SuperGrok  
- `GrokProPlus` / `GrokPlus` → SuperGrok Plus  
- `GrokHeavy` → SuperGrok Heavy  

No mapping yet for X Subscription names: `Plus` / `Premium` / `Super` / `Ultra`.

---

## Live probe on this machine (2026-10-15, redacted)

Account is still **legacy SuperGrok**, not merged.

### `/v1/user?include=subscription` (keys of interest)

```json
{
  "subscriptionTier": "GrokPro",
  "cursorMerged": false,
  "hasGrokCodeAccess": true,
  "xUserId": "<present>",
  "isUnifiedBillingUser": "(on billing, not here)"
}
```

**`cursorMerged` is the smoking gun** for “accounts combined into The X Subscription.” We already receive it and currently ignore it.

### `/v1/billing?format=credits`

Still the familiar weekly SuperGrok shape (`USAGE_PERIOD_TYPE_WEEKLY`, product breakdown Build/Chat, prepaid cents, on-demand cap 0). No new “X Subscription” string in this payload on the legacy account.

### Cached Bot snapshot

- `planLabel`: `SuperGrok`  
- `cursorPlanName`: `Free`  

= classic “Cursor Free + SuperGrok grant” Bot meter, **not** a single X Subscription seat.

---

## Hypotheses (to validate when someone is on the new plan)

1. **`cursorMerged` flips to `true`** after switch; may stay true even if billing period rolls.
2. **`subscriptionTier`** may change from `GrokPro` / `GrokProPlus` / `GrokHeavy` to something like `Plus` / `Premium` / `Super` / `Ultra`, or a new enum (`XPremium`, `XSubscriptionPremium`, …). **Capture raw string.**
3. **Shared pool**: SuperGrok `creditUsagePercent` and Bot `usagePercent` may converge to the **same** weekly %, or one endpoint may become authoritative and the other empty/duplicate.
4. **Product breakdown** may gain Cursor-related products, or stay Grok-only while Cursor spend is only visible on Cursor APIs.
5. **Bot `cursorPlanName`** may stop saying `Free` and show `Premium`/`Super`/`Ultra`; `grokPlanLabel` may disappear or mirror the X tier.
6. **On-demand / prepaid** semantics may shift (third-party models vs Grok overflow). Do not assume old “Extra credits” copy still fits.

---

## Recommended approach (without buying the plan)

### Phase A — probe instrumentation (cheap, safe)

1. Persist (locally, never commit) redacted JSON samples when:
   - `cursorMerged == true`, or
   - `subscriptionTier` is outside the known `Grok*` set.
2. Surface a soft debug line in UI only behind a hidden flag, **or** write samples under `~/Library/Application Support/GrokUsage/probe/` with secrets stripped.
3. Extend plan display map with unknown → show raw tier string (already partly true via `default` in `planDisplayName`).

### Phase B — UI once samples exist

| Signal | Suggested UI |
|--------|----------------|
| `cursorMerged == false` | Keep current dual SuperGrok + Bot modules |
| `cursorMerged == true` + two meters ≈ equal | One primary “X Subscription” meter; optional collapsed product/Bot detail |
| `cursorMerged == true` + only one meter populated | Show that one; hide the empty module |
| Unknown tier string | Show raw API value; never invent a wrong marketing name |

Do **not** hard-delete the Bot module until we confirm Bot no longer has a separate grant on merged accounts.

### Phase C — what to ask a volunteer on the new plan

Ask them (or yourself after switching) to save redacted responses from:

1. `GET https://cli-chat-proxy.grok.com/v1/user?include=subscription`
2. `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
3. `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus`
4. `GET https://cursor.com/api/usage-summary` (cookie session)

Redact: tokens, email, user/team IDs. Keep: all plan / percent / period / product / on-demand / `cursorMerged` fields.

---

## Product advice

- **Do not** join the new plan solely to build this feature. The merge flag already exists on legacy accounts; volunteers or a future switch give the rest.
- **Do** treat this as a **compatibility layer**: legacy dual-meter stays default; merged plan gets a different presentation when signals are clear.
- **Risk**: switching to The X Subscription is described as **permanent** account combining in third-party writeups — decide billing for yourself separately from this app’s needs.
- **Scope guard**: X Premium social benefits are out of scope for a usage menu bar; only plan label + shared AI pool matter here.

---

## Next concrete engineering step (when approved)

Add optional probe dump of `/v1/user` fields `cursorMerged` + `subscriptionTier` (and Bot `grokPlanLabel` / `cursorPlanName`) into Application Support, gated off by default or always-on with redaction — then pause until a merged-account sample arrives.
