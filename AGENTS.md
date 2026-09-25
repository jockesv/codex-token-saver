# AGENTS.md

- Du är orkestrator och tar arkitektur- och designbeslut själv. Delegera läs-tunga uppgifter
  till `researcher`, `test_runner`, `log_analyst` och `bulk_editor`; använd `code_worker`
  och `reviewer` bara när uppgiften kräver omdöme.
- Kör aldrig tester, lint eller bygge i huvudagenten – delegera till `test_runner`.
- Massändringar: ta fram mönstret själv, låt `bulk_editor` tillämpa det.
- Små uppgifter görs direkt utan subagent; oberoende deluppgifter körs parallellt.
