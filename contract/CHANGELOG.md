# Client-Vertrag — Änderungen

Neueste oben. Je Abschnitt: was sich geändert hat, und was ein Client tun **muss** (Bruch, Frist) bzw. tun **darf** (neues Feld, neuer Weg). Regeln: [README.md](README.md).

## api 1 · editorApi 1

Erster festgeschriebener Stand. Er beschreibt, was macOS (3.27) und Android (`65408bb`) heute nutzen, plus drei Ergänzungen:

- **`GET /config` → `clientContract: { api, editorApi }`.** Damit erkennt ein Client Features (`api >= n`).
- **`PUT /content/pages/{page_id}` mit `base_html`:** Bei veraltetem Stempel mergt der Server blockweise mit derselben Engine wie der Mac-Client. Kollisionsfrei kommt `200` mit `merged: true` zurück; `html` ist dann der neue Stand und lokal zu übernehmen, die Save-Kennung des Pushs gilt. Bei echter Kollision kommt `409 PAGE_CONFLICT` mit `merge_conflicts: [data-bid]`, und es wird nichts geschrieben. Ohne `base_html` bleibt alles wie bisher.
- **Bundle:** Das `bundle-manifest.json` trägt `editorApi`. `GET /content/editor-bundle.zip` liest den Header `X-Editor-Api` (Majors, die die Schale kann; ohne Header gilt 1). Passt kein Major, kommt `409 EDITOR_API_UNSUPPORTED` mit `params: { client, server }`.

**Clients dürfen:** `base_html` beim Push mitschicken (Android: damit gibt es Auto-Merge ohne eigene Merge-Logik), `X-Editor-Api: 1` senden und `409 EDITOR_API_UNSUPPORTED` als «gecachtes Bundle behalten, Update-Hinweis» behandeln.

**Clients sollen:** Ihre Decoding-Tests auf `contract/fixtures/` umstellen (`scripts/sync-contract.sh` im Client-Repo).

**macOS soll:** Den Fallback auf `controller._focusUpdateActive` in `applyGranularity` streichen; `setGranularity` liefert jedes Bundle seit dem Standalone-Hook. Danach `npm run contract:surface`, und der Eintrag fällt aus der Schuldenliste in `tests/unit/editor-surface.test.js`.
