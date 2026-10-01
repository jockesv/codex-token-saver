# Dynamiskt modellval för Codex

Integrationen utgår från `codex-dynamic-model-selection.zip`. Paketets rollpolicy
behålls, medan kataloghämtning och generering har anpassats till detta repos mallar.

## Policy och urval

`.codex/model-policy.json` anger familjer i prioriteringsordning samt
`reasoning_effort` för huvudagent, standard-subagent och varje namngiven roll.
Exempel:

```json
"reviewer": {
  "families": ["sol", "astra", "luna"],
  "reasoning_effort": "high"
}
```

Resolvern väljer den numeriskt högsta GPT-versionen i den första familj som har
en lämplig modell. Exempelvis sorteras `gpt-6.10-sol` efter `gpt-6.2-sol`.
En nyare Astra går inte före en lämplig Sol när Sol står först i policyn.
Endast fullständiga modellnamn av typen `gpt-<version>-<familj>` matchas;
förhandsversioner och namn med extra suffix väljs inte automatiskt.

Dolda modeller filtreras bort. Finns metadata om stödda resonemangsnivåer måste
modellen stödja exakt den begärda nivån. Nivån sänks inte automatiskt. Om katalogen
saknar sådan metadata används policyns nivå med en varning om att stödet inte är
verifierat. Om ingen modell passar avbryts körningen före skrivning.

## Katalogkällor

Utan extra parametrar startas `codex app-server` med befintlig Codex-inloggning.
Resolvern använder `initialize`, `account/read` och paginerad `model/list` och
kräver ChatGPT-inloggning. Kontouppgifter och tokens skrivs inte till manifestet.

```powershell
pwsh -NoProfile -File tools/Resolve-CodexModels.ps1 -WhatIf
pwsh -NoProfile -File tools/Resolve-CodexModels.ps1
```

`-CodexPath` kan ange sökvägen till Codex CLI och `-PythonPath` till Python.
CLI:n ska använda samma Codex-konto som du vill generera konfigurationen för.

Paketets OAuth-alternativ stöds också: om `ACCESS_TOKEN` finns i miljön används
den mot `https://api.openai.com/v1/models`. En uttrycklig `-AccessToken` fungerar
också, men miljövariabel undviker token i kommandoradshistoriken. En annan endpoint
tillåts inte. Skicka inte eller checka in tokens.

En sparad katalog har högst prioritet och används bara när du uttryckligen anger den:

```powershell
pwsh -NoProfile -File tools/Resolve-CodexModels.ps1 -CatalogPath ./models.json -WhatIf
```

Katalogfilen kan innehålla `models` med `slug`, `data` med `model`/`id`, eller en
JSON-array. Ett sparat resultat från `model/list` använder objektet under `result`.
En fil verifierar inte det aktuella kontots modellutbud. Manifestets
`catalog_source` skiljer `file`, `oauth-endpoint` och `codex-app-server` åt.

**Begränsning:** Codex app-server kan använda en cachad eller medföljande katalog.
Resolvern kan därför inte garantera färskt serverutbud eller faktisk inferensbehörighet.
OAuth-endpointen ger kontospecifika katalogval; ett lyckat modellanrop är den slutliga
verifieringen av åtkomst. Resolvern gör inga modellanrop och använder ingen egen
automatisk offline-fallback om hämtningen misslyckas.

## Generering och Git

Alla roller och mallar valideras innan runtime-filer skrivs. Mallarnas övriga
TOML-innehåll bevaras, inklusive instruktioner, sandbox och agentinställningar.
Standardmodellens inställningar hamnar i `[agents]`, huvudagentens i TOML-roten.

Följande filer genereras lokalt och ignoreras av Git:

- `.codex/config.toml`
- `.codex/agents/*.toml`
- `.codex/resolved-models.json`

Versionshantera policyn, mallarna och verktygen. Därmed kräver nya modellversioner
ingen ändring i Git. Vid migrering från den tidigare setupen tas runtime-filerna
ur Git-indexet, men behålls på disken. Införliva alltid egna runtime-inställningar
i mallarna först; lokala runtime-redigeringar skrivs över.

Till skillnad från originalpaketet redigerar verktyget inte handskrivna TOML-filer
och skapar därför inga `.bak`-filer. `-NoBackup` finns kvar för kompatibilitet.
Filer förbereds först och ersätts sedan atomiskt var för sig; hela filgruppen är
inte en atomisk transaktion vid ett operativsystemfel mitt under ersättningen.

## Kontroll och uppdatering

```powershell
pwsh -NoProfile -File tools/Resolve-CodexModels.ps1 -Check
```

Kontrolläget skriver inga runtime-filer och returnerar 0 om de stämmer med det
aktuella urvalet, annars 1. `-WhatIf` visar val utan att tillämpa dem.
En upprepad generering med samma urval ändrar inga filer.

Kör resolvern före en ny Codex-session för att uppdatera urvalet. Det finns ingen
bakgrundsbevakning. Byt konto i Codex CLI och kör om resolvern om du vill använda
ett annat kontos katalog. Inloggningsfel, tom katalog, okänd familj eller saknad
rollmall ger fel; befintlig runtime behålls vid valideringsfel.

Om katalogen exempelvis bara innehåller `gpt-5.5` kan den angivna familjepolicyn
inte välja en modell. Ett modellnamn utan familjesuffix räknas inte automatiskt
som Sol eller någon annan familj. Felmeddelandet visar de synliga modellnamnen.
Använd då en katalog/kontokonfiguration som exponerar de önskade familjerna,
eller besluta om en utökad urvalspolicy. Verktyget gör ingen sådan omklassning själv.

## Krav och källor

PowerShell 7+, Python 3.11+ och Codex CLI. Inga externa Python-paket behövs.

- [Codex app-server](https://learn.chatgpt.com/docs/app-server)
- [Kontospecifika modeller och inferens](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
