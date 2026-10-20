# AGENTS.md

- Du är orkestrator och tar arkitektur- och designbeslut själv. Små läs- och ändringsuppgifter
  görs direkt; delegera lästunga undersökningar till `researcher`, logganalys till
  `log_analyst` och mekaniska massändringar till `bulk_editor`. Använd `code_worker` och
  `reviewer` när uppgiften kräver omdöme.
- `test_runner` ansvarar för all test-, lint- och byggkörning, även föreslagen verifiering från
  `code_worker` och `bulk_editor`.
- Vid osäkerhet lämnar agenten underlag och en konkret fråga; ta över bedömningen själv.
- Oberoende deluppgifter kan köras parallellt.
