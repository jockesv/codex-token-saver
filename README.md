# Codex-agenter – liten kontext, rätt modell för uppgiften

En färdig konfiguration för Codex med specialiserade subagenter. Syftet är att minska
kostnaden och hålla huvudagentens kontext liten genom att låta billiga, snabba modeller
göra avgränsade läs- och analysjobb. Den totala tokenförbrukningen minskar inte garanterat.

Se lathunden i [`docs/codex-agent-setup.png`](docs/codex-agent-setup.png) för en visuell översikt.

## Idén i korthet

- **GPT-6.1 Sol** (`gpt-6.1-sol`) – resonerar, planerar och fattar beslut.
- **GPT-6 Luna** (`gpt-6-luna`) – söker, läser och utför. Snabb och betydligt billigare.
- **GPT-6 Astra** (`gpt-6-astra`) – för de mest krävande uppgifterna; ingår som
  prisreferens men används inte i den här konfigurationen.

Lästunga uppgifter kan förbruka mycket input-tokens: filer, testutdata, byggloggar och
CI-loggar. Därför passar Luna för avgränsade läs- och analysjobb, medan Sol används för
design, icke-trivial logik och granskning.

En extra vinst med subagenter är att huvudagentens kontext hålls liten. Subagenten läser
tusen rader testutdata, huvudagenten får tillbaka tre rader om vad som gick fel.

## Priser

USD per 1M tokens med **Standard-bearbetning**, kontrollerat 2026-10-20 mot
[OpenAI Docs – API-priser](https://developers.openai.com/api/docs/pricing).
*Kort kontext* innebär högst 272 000 input-tokens i prompten, *lång* innebär fler.

| Modell | Kontext | Input | Cachad input | Cache-skrivning | Output |
|---|---|---:|---:|---:|---:|
| `gpt-6-astra` | kort | $10.00 | $1.00 | $12.50 | $50.00 |
| | lång | $20.00 | $2.00 | $25.00 | $75.00 |
| `gpt-6.1-sol` | kort | $2.00 | $0.10 | $2.50 | $10.00 |
| | lång | $4.00 | $0.20 | $5.00 | $15.00 |
| `gpt-6-luna` | kort | $0.10 | $0.01 | $0.125 | $0.50 |
| | lång | $0.20 | $0.02 | $0.25 | $0.75 |

Lunas input, cache-skrivning och output kostar en tjugondel av Sols; cachad input
kostar en tiondel. När prompten överstiger 272 000 input-tokens dubbleras input- och
cache-priserna och output-priset höjs med 50 % för hela anropet, ännu ett skäl att
hålla huvudagentens kontext liten.

Batch och Flex kostar 50 % av Standard; Fast kostar dubbelt så mycket.
Regional bearbetning medför ett påslag på 10 % där den erbjuds. Tabellen visar
API-priser; användning inom en ChatGPT-/Codex-prenumeration följer abonnemangets villkor.

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
| *huvudagenten* | Sol | – | Orkestrering: planera, bryta ner, besluta, delegera, integrera och verifiera |
| `researcher` | Luna | read-only | Lästunga, avgränsade undersökningar; små läsuppgifter görs direkt |
| `test_runner` | Luna | workspace-write | Köra tester, lint och bygge – returnerar bara felen |
| `log_analyst` | Luna | read-only | Hitta rotorsak i stora loggar och CI-körningar |
| `bulk_editor` | Luna | workspace-write | Namnbyten, migreringar, importer, beroendeuppgraderingar, lint-fixar, README/changelog/PR-texter |
| `code_worker` | Sol | workspace-write | Implementera avgränsade uppgifter med icke-trivial logik och skriva tester vid behov |
| `reviewer` | Sol | read-only | Granska korrekthet, säkerhet och testtäckning |

Huvudagenten och alla agenter utom `reviewer` använder `medium` effort; `reviewer` använder
`high`.

## Arbetsfördelning och eskalering

Gör små läs- och ändringsuppgifter direkt. Använd agenter för lästunga undersökningar,
mekaniska massändringar och avgränsad implementation. `code_worker` skriver eller uppdaterar
tester när ändringen behöver dem; `test_runner` kör all testning, lint och bygge, även på
förslag från `code_worker` och `bulk_editor`.

Om en Luna-agent inte kan belägga ett svar eller en orsak, eller stöter på en fråga utanför
uppdraget, gissar den inte och upprepar inte samma försök. Den rapporterar
osäkerheten, undersökt underlag med sökväg och radnummer eller kommandoutdata samt en konkret
fråga. Orkestratorn avgör om den ska ta över, höja effort eller använda Sol. Agenten byter
inte modell själv.

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

Flera oberoende deluppgifter kan köras parallellt. Delegering har dock overhead, och fler
parallella agenter garanterar inte lägre kostnad. Mät kostnad, tid och omarbete för
jämförbara uppgifter innan du drar slutsatser om besparingen.

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
  respektive fil i `.codex/agents/`. Luna stöder `none`, `low`, `medium`, `high`, `xhigh`
  och `max`; Sol stöder `low`, `medium`, `high`, `xhigh` och `max`.
  Vid tunna eller osäkra Luna-svar väljer orkestratorn nästa steg efter uppgiftens svårighet:
  den kan höja effort eller ta över med Sol.
- **Antal parallella subagenter:** `max_concurrent_threads_per_session` i `.codex/config.toml`
  (satt till 4 för att hålla kostnaden nere).
- **Ny agent:** skapa en ny `.toml`-fil i `.codex/agents/` med `name`, `description` och
  `developer_instructions`. Huvudagenten väljer agent utifrån `description`, så skriv den
  tydligt, och lägg till agentens namn i rätt lista i `AGENTS.md`. Skriv inte modellnamn i
  `description` eller `AGENTS.md` – då blir texten fel när någon byter modell.
  Lägg bara till agenter ni faktiskt använder – varje ny agent gör valet svårare för
  huvudagenten.

## Referenser

- [OpenAI Docs – aktuella modellfamiljer](https://developers.openai.com/api/docs/models)
- [OpenAI Docs – API-priser](https://developers.openai.com/api/docs/pricing)
- [OpenAI Docs – GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
- [OpenAI Docs – GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna)
- [Codex – subagenter](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- [Codex – modeller](https://learn.chatgpt.com/docs/models)
