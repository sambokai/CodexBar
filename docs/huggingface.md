---
summary: "Hugging Face provider: bearer-token spend plus optional browser-session prepaid Credits balance."
read_when:
  - Configuring Hugging Face usage or prepaid Credits
  - Debugging Hugging Face billing-page cookie enrichment
  - Reviewing Hugging Face spend versus wallet presentation
---

# Hugging Face Provider

CodexBar keeps Hugging Face reported spend and the prepaid **Credits** wallet as separate values. The existing API
source reports billing-period spend and category totals. The optional web source reads the personal wallet shown by
[Hugging Face Billing](https://huggingface.co/settings/billing).

## Setup

1. Open **Settings -> Providers** and enable **Hugging Face**.
2. Configure a Hugging Face user access token, or set `HF_TOKEN`, for API-reported spend.
3. To show the prepaid wallet, leave **Cookie source** on **Automatic** after signing in to Hugging Face in a supported
   browser, or select **Manual** and paste a full `Cookie:` header from `huggingface.co/settings/billing`.
4. Select **Off** to disable billing-page cookie enrichment while retaining the API source.

The web source can show a balance without an API token. Automatic cookie import is limited to `huggingface.co` and
uses CodexBar's shared cached-cookie/browser-import path. Ordinary refresh does not open a browser or prompt for
Keychain access. Use **Open Hugging Face Billing** from Settings when a fresh authenticated session is needed.

## Data sources

- `GET https://huggingface.co/api/settings/billing/usage` with the bearer token reports billing-period spend and
  category totals. This is not the prepaid wallet.
- `GET https://huggingface.co/settings/billing` with a normal authenticated Hugging Face web session returns HTML
  containing server-rendered `div[data-props]` data. CodexBar reads the personal entity's `currentBalanceUsd` value as
  the prepaid wallet.

The current wallet field is already a finite, non-negative USD number. `$0.00` and fractional cents are valid. When
the current field is absent, CodexBar accepts the legacy top-level `invoiceCreditsCents` field only as a finite,
non-negative, JavaScript-safe integer and converts it from cents exactly once. It does not use visible page text,
`includedNanoUsd`, `usedNanoUsd`, `limitNanoUsd`, plan entitlements, or reported spend to derive a wallet balance.

## Display and source modes

- **Auto** keeps bearer-token spend authoritative and adds the wallet only when the billing-page entity name and the
  bearer `whoami-v2` account name match. A mismatch or missing identity omits enrichment instead of mixing accounts.
- **API** uses the bearer-token spend path and never looks up cookies or requests the billing page.
- **Web** requests the billing page and can display a balance-only snapshot when API spend is unavailable. When API
  spend is available, it is combined only after the same account-identity check; otherwise the wallet remains separate.

The provider Balance layout token and the provider balance row show the reported prepaid wallet. Hugging Face
Inference usage remaining and billing-period spend are separate concepts and are never substituted for Credits.

## Troubleshooting

### "No Hugging Face session cookies found"

Sign in to Hugging Face, open the billing page, and refresh. If automatic import is unavailable, switch to **Manual**
and paste a full `Cookie:` header for `huggingface.co`.

### The wallet is missing but spend is shown

The billing-page enrichment is optional. A missing/expired session, login redirect, non-HTML response, malformed
server-rendered payload, or unproven account match omits the wallet and leaves valid API spend unchanged.

### The wallet shows `$0.00`

That is a valid reported zero balance, distinct from an unavailable or malformed wallet response.

## Related files

- `Sources/CodexBarCore/Providers/HuggingFace/HuggingFaceProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/HuggingFace/HuggingFaceWebCreditsParser.swift`
- `Sources/CodexBarCore/Providers/HuggingFace/HuggingFaceWebFetchStrategy.swift`
- `Sources/CodexBar/Providers/HuggingFace/HuggingFaceProviderImplementation.swift`
- `Tests/CodexBarTests/HuggingFaceUsageStatsTests.swift`
