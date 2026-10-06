# Windows 11 STIG → Intune Policy Studio

Lokaler TypeScript/React-Viewer für den mitgelieferten DISA Windows 11 STIG V2R11. Die Oberfläche kategorisiert alle XCCDF-Regeln, unterstützt Suche und Mehrfachauswahl und exportiert geprüfte Einstellungen als Microsoft-Graph-kompatible `windows10CustomConfiguration`.

## Start

```bash
npm install
npm run generate:stig
cp .env.example .env   # optional: Azure OpenAI konfigurieren
npm start
```

Danach `http://localhost:5173` öffnen. Ohne Azure-Konfiguration ist der STIG-Viewer nutzbar; CSP-Mappings können erst nach Konfiguration geprüft werden.

## Azure OpenAI

Die Zugangsdaten liegen ausschließlich im lokalen API-Prozess. In `.env` werden Endpoint, API-Key und der Deploymentname `gpt-5-mini` gesetzt. Das Backend nutzt die Azure OpenAI Responses API v1; ein datierter `AZURE_OPENAI_API_VERSION`-Wert ist nicht erforderlich. Pro Aufruf werden maximal 30 ausgewählte Regeln analysiert. Modellantworten werden als Vorschläge behandelt; vor dem Intune-Produktiveinsatz müssen CSP-Pfade, Datentypen und Werte gegen die aktuelle Microsoft-Dokumentation geprüft und in einem Test-Ring validiert werden.

## Daten aktualisieren

Nach Austausch der XCCDF-Datei:

```bash
npm run generate:stig
```

Der Generator liest Regeln, Schweregrad, CCI, Fix- und Prüfanweisungen sowie vorhandene Registry-Nachweise neu ein.
