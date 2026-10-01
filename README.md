# Codex-agenter – mindre tokens, mer gjort

Specialiserade subagenter håller huvudagentens kontext liten. Läsning, logganalys
och mekaniska ändringar delegeras; huvudagenten fattar arkitektur- och designbeslut.

Modeller väljs dynamiskt från en modellkatalog enligt
[`.codex/model-policy.json`](.codex/model-policy.json). Policyn anger familjer och
resonemangsnivå, aldrig en bestämd modellversion. Resolvern väljer den senaste
lämpliga versionen inom den första tillgängliga familjen i prioriteringsordningen.

## Roller

| Roll | Familjeordning | Resonemang | Uppgift |
|---|---|---|---|
| Huvudagent | Sol → Astra → Luna | medium | Planera, besluta och delegera |
| Standard för subagenter | Luna → Terra → Sol | medium | Fallback för roller utan eget modellval |
| `researcher` | Luna → Terra → Sol | medium | Söka i kodbas och dokumentation |
| `log_analyst` | Luna → Terra → Sol | medium | Hitta rotorsak i stora loggar |
| `test_runner` | Luna → Terra → Sol | low | Köra tester, lint och bygge |
| `bulk_editor` | Luna → Terra → Sol | low | Utföra mekaniska massändringar |
| `code_worker` | Sol → Astra → Luna | medium | Implementera avgränsad logik |
| `reviewer` | Sol → Astra → Luna | high | Granska kod, tester och design |

## Kom igång

Kräver Windows PowerShell 5.1 eller PowerShell 7, Python 3.11+ och Codex CLI på
`PATH` med en befintlig ChatGPT-inloggning. Python använder bara standardbiblioteket.

Paketet ska distribueras med dessa källfiler:

```text
AGENTS.md
.codex/model-policy.json
.codex/apply_models.py
.codex/templates/config.toml
.codex/templates/agents/*.toml
tools/Resolve-CodexModels.ps1
README.md
README-model-selection.md
```

Kopiera paketets innehåll till projektroten. Om projektet redan har en `AGENTS.md`,
införliva orkestreringsreglerna i stället för att skriva över projektets fil. Om
projektet redan har Codex-agenter, flytta bestående instruktioner till mallarna innan
du genererar runtime-filerna.

Checka inte in dessa lokala, genererade filer:

```text
.codex/config.toml
.codex/agents/*.toml
.codex/resolved-models.json
```

De skapas från mallarna och modellkatalogen för den användare som kör Codex.
`.gitignore` i paketet innehåller motsvarande regler.

Förhandsgranska valen:

```powershell
powershell.exe -NoProfile -File tools/Resolve-CodexModels.ps1 -WhatIf
```

Generera runtime-konfigurationen och starta sedan en ny Codex-session:

```powershell
powershell.exe -NoProfile -File tools/Resolve-CodexModels.ps1
```

Projektet behöver vara betrott i Codex för att projektets konfiguration ska läsas.
Kör resolvern igen före en ny session när du vill fånga upp nya modeller eller har
bytt konto. Det sker ingen bakgrundsbevakning och en pågående session byter inte modell.

Kontrollera först att Codex är inloggad:

```powershell
codex login status
```

Kör `-WhatIf` före den första genereringen. Om katalogen bara innehåller en modell
som inte matchar policyn avbryter resolvern utan att ändra runtime-filerna. När valet
ser rätt ut kör du samma kommando utan `-WhatIf` och startar sedan en ny Codex-session.

Uppdatera senare genom att köra samma resolver igen. Nya modellversioner väljs då
automatiskt från katalogen; `.codex/model-policy.json` behöver normalt inte ändras.

Se [modellvalets dokumentation](README-model-selection.md) för katalogkällor,
felhantering, kontrolläge och begränsningar.

## Filer och ansvar

| Fil | Ansvar |
|---|---|
| `AGENTS.md` | Övergripande orkestreringspolicy |
| `.agents/skills/*/SKILL.md` i målprojektet | Task-specifika workflows; påverkas inte av resolvern |
| `.codex/model-policy.json` | Versionsoberoende familjeordning och resonemang per roll |
| `.codex/templates/config.toml` | Gemensamma inställningar för huvudagent och subagenter |
| `.codex/templates/agents/*.toml` | Agentdefinitioner: instruktioner, beskrivning och sandbox |
| `tools/Resolve-CodexModels.ps1` | Hämtar katalog och löser policyn |
| `.codex/apply_models.py` | Validerar och genererar TOML och manifest |
| `.codex/config.toml`, `.codex/agents/*.toml` | Lokalt genererad runtime, ignorerad av Git |
| `.codex/resolved-models.json` | Lokalt manifest med modellval och katalogkälla |

Runtime-filerna skapas från mallarna och skrivs över vid nästa generering. Lägg
bestående ändringar i mallarna. Den tidigare manuella `models.toml`-mappningen
ersätts av rollpolicyn; modellernas resonemangsnivå anges också i policyn.

## Anpassa

- Ändra familjeordning och resonemang i `.codex/model-policy.json`.
- Ändra agentens instruktioner eller sandbox i `.codex/templates/agents/`.
- Ändra parallellitetsgränsen i `.codex/templates/config.toml`.
- Lägg till en ny agent både i `templates/agents/` och i policyns `roles`.
  Modellfält ska inte finnas i mallarna.

## Exempel

```text
Använd researcher för att hitta hur autentiseringen fungerar.
Låt test_runner köra testerna efter implementationen.
Låt log_analyst hitta orsaken till felet i byggloggen.
Byt namn på UserService med bulk_editor och granska med reviewer.
```

Håll uppgifter avgränsade och peka på filer i stället för att klistra in stora
textmängder. Använd nya sessioner för oberoende uppgifter.

## Verifiering

```powershell
python -m unittest discover -s tests -v
```

Testerna använder temporära projekt och syntetiska kataloger, utan modellanrop.

## Referenser

- [Codex app-server: modellkatalog och inloggning](https://learn.chatgpt.com/docs/app-server)
- [Kontospecifik modellkatalog och cachebegränsningar](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
