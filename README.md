# Codex-agenter – mindre tokens, mer gjort

En färdig konfiguration för Codex med specialiserade subagenter. Syftet är att minska
tokenförbrukningen genom att låta billiga, snabba modeller göra det tunga läsjobbet,
medan den dyrare modellen bara används där det krävs omdöme.

Se lathunden i [`docs/codex-agent-setup.png`](docs/codex-agent-setup.png) för en visuell översikt.

## Idén i korthet

- **Sol** (`gpt-6-sol`) – resonerar, planerar och fattar beslut. Dyr.
- **Luna** (`gpt-6-luna`) – söker, läser och utför. Snabb och betydligt billigare.

Det mesta av tokenförbrukningen i vardagen kommer inte från det modellen skriver, utan från
det den *läser*: filer, testutdata, byggloggar och CI-loggar. Därför gäller principen
**Luna först**: allt som läser mycket men levererar lite och väldefinierat går till Luna.
Sol används för design, icke-trivial logik och granskning.

En extra vinst med subagenter är att huvudagentens kontext hålls liten. Subagenten läser
tusen rader testutdata, huvudagenten får tillbaka tre rader om vad som gick fel.

## Priser

USD per 1M tokens, per 2026-09-25. *Kort kontext* är upp till 272k tokens, *lång* är mer.

| Modell | Kontext | Input | Cachad input | Cache-skrivning | Output |
|---|---|---:|---:|---:|---:|
| `gpt-6-astra` | kort | $10.00 | $1.00 | $12.50 | $50.00 |
| | lång | $20.00 | $2.00 | $25.00 | $75.00 |
| `gpt-6-sol` | kort | $2.00 | $0.20 | $2.50 | $10.00 |
| | lång | $4.00 | $0.40 | $5.00 | $15.00 |
| `gpt-6-luna` | kort | $0.10 | $0.01 | $0.125 | $0.50 |
| | lång | $0.20 | $0.02 | $0.25 | $0.75 |

Luna kostar en tjugondel av Sol. Över 272k tokens dubbleras priset för input och
output-priset höjs med 50 %, ännu ett skäl att hålla huvudagentens kontext liten.
Astra används inte i den här konfigurationen.

## Innehåll

```
.
├── AGENTS.md                  # Regler: när och hur agenterna används
├── .codex/
│   ├── config.toml            # Huvudagentens modell + inställningar för subagenter
│   └── agents/
│       ├── researcher.toml    # Luna – söker i kodbas och dokumentation
│       ├── test_runner.toml   # Luna – kör tester/lint/bygge, rapporterar bara fel
│       ├── log_analyst.toml   # Luna – analyserar applikations- och CI-loggar
│       ├── bulk_editor.toml   # Luna – mekaniska ändringar över många filer, dokumentation
│       ├── code_worker.toml   # Sol  – implementerar icke-trivial logik
│       └── reviewer.toml      # Sol  – granskar kod, tester och design
└── docs/
    └── codex-agent-setup.png  # Lathund
```

## Agenterna

| Agent | Modell | Sandbox | Använd för |
|---|---|---|---|
| *huvudagenten* | Sol | – | Orkestrering: planera, bryta ner, besluta, delegera, verifiera |
| `researcher` | Luna | read-only | Hitta kod, läsa dokumentation, svara på "var/hur görs X?" |
| `test_runner` | Luna | workspace-write | Köra tester, lint och bygge – returnerar bara felen |
| `log_analyst` | Luna | read-only | Hitta rotorsak i stora loggar och CI-körningar |
| `bulk_editor` | Luna | workspace-write | Namnbyten, migreringar, importer, beroendeuppgraderingar, lint-fixar, README/changelog/PR-texter |
| `code_worker` | Sol | workspace-write | Implementera avgränsade uppgifter med icke-trivial logik |
| `reviewer` | Sol | read-only | Granska korrekthet, säkerhet och testtäckning |

## Kom igång

### 1. Kopiera in filerna i ditt projekt

Kopiera `AGENTS.md` och katalogen `.codex/` till roten av det repo du jobbar i:

```bash
cp -r /sökväg/till/codex-token-saver/.codex /sökväg/till/ditt-repo/
cp /sökväg/till/codex-token-saver/AGENTS.md /sökväg/till/ditt-repo/
```

Har projektet redan en `AGENTS.md`? Klistra då in punkterna från den här filen i den
befintliga i stället för att skriva över den.

Håll `AGENTS.md` kort – den skickas med i varje request. Vad varje agent gör står i
dess `description` i `.codex/agents/` och behöver inte upprepas i `AGENTS.md`.

Vill du ha agenterna i alla dina projekt kan du lägga agentfilerna i din personliga
Codex-katalog (`~/.codex/agents/`) i stället.

### 2. Markera projektet som betrott

Codex läser bara in en projektlokal `.codex/config.toml` för projekt som är markerade som
betrodda (trusted). Svara ja när Codex frågar om du litar på projektet första gången du
startar det i repot. Annars används inte modellinställningarna.

### 3. Checka in filerna

Checka in `AGENTS.md` och `.codex/` i repot så att hela teamet får samma setup.

## Så använder du det

Du behöver oftast inte nämna agenterna – huvudagenten läser `AGENTS.md` och delegerar
själv. Men du kan styra explicit när du vill:

```text
Använd researcher för att ta reda på hur autentiseringen fungerar i den här tjänsten.
```

```text
Implementera paginering i /orders-endpointen. Låt test_runner köra testerna efteråt.
```

```text
CI-bygget failar på main. Låt log_analyst hitta orsaken i build.log.
```

```text
Byt namn på UserService till AccountService i hela kodbasen med bulk_editor.
```

```text
Granska mina ändringar mot main med reviewer innan jag skapar PR:en.
```

Tips: flera oberoende deluppgifter kan köras parallellt – t.ex. tre `researcher` som
undersöker olika delar av systemet samtidigt.

## Sessionsvanor som sparar tokens

Konfigurationen hjälper, men vanorna gör minst lika stor skillnad:

- **Håll kontexten kort.** Ge bara relevant information – peka på filer i stället för att
  klistra in dem.
- **Dela upp stora uppgifter.** Låt subagenter ta hand om tunga eller väldefinierade delar.
- **Rensa vid behov.** Kör `/compact` när konversationen blivit lång.
- **Nya sessioner.** Starta en ny session för varje ny, oberoende uppgift.
- **Håll ordning.** Använd `.gitignore` så att genererade filer, beroenden och byggartefakter
  inte söks igenom i onödan.

## Anpassa

- **Byta modell eller resonemangsnivå:** ändra `model` och `model_reasoning_effort` i
  respektive fil i `.codex/agents/`. Luna stöder `medium` och uppåt, Sol stöder `low` och uppåt.
  Blir Lunas svar för tunna, testa `high` innan du byter till Sol.
- **Antal parallella subagenter:** `max_concurrent_threads_per_session` i `.codex/config.toml`
  (satt till 4 för att hålla kostnaden nere).
- **Ny agent:** skapa en ny `.toml`-fil i `.codex/agents/` med `name`, `description` och
  `developer_instructions`. Huvudagenten väljer agent utifrån `description`, så skriv den
  tydligt, och lägg till agentens namn i rätt lista i `AGENTS.md`. Skriv inte modellnamn i
  `description` eller `AGENTS.md` – då blir texten fel när någon byter modell.
  Lägg bara till agenter ni faktiskt använder – varje ny agent gör valet svårare för
  huvudagenten.

## Referenser

- [Codex – subagenter](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- [Codex – modeller](https://learn.chatgpt.com/docs/models)
