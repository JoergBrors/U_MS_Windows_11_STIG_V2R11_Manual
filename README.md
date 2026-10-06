# DISA STIG → Intune Policy Studio

Lokaler TypeScript/React-Viewer für DISA-STIG-Pakete im XCCDF-Format. Die Oberfläche importiert originale ZIP-Dateien, erkennt Benchmark und Version, kategorisiert die Regeln und exportiert geprüfte Einstellungen als Microsoft-Graph-kompatible `windows10CustomConfiguration`.

## Start

```bash
npm install
cp .env.example .env   # optional: Azure OpenAI konfigurieren
npm start
```

`npm start` beendet vor dem Start alte, eindeutig als Vite- oder Projekt-API erkannte Prozesse des aktuellen Benutzers auf den Entwicklungsports 5173–5179 und 8787. Ein unbekannter Prozess wird aus Sicherheitsgründen nicht beendet; der Start bricht dann mit der betreffenden PID ab. Vite verwendet anschließend fest Port 5173 und weicht nicht unbemerkt auf eine alte oder zusätzliche Instanz aus. API und Frontend werden gemeinsam beendet, sobald einer der beiden Prozesse endet.

Danach `http://localhost:5173` öffnen. Ohne Azure-Konfiguration ist der STIG-Viewer nutzbar; CSP-Mappings können erst nach Konfiguration geprüft werden.

## STIG-ZIP importieren

1. Die [STIGs Document Library](https://www.cyber.mil/stigs/downloads/) öffnen und das gewünschte aktuelle STIG-Paket herunterladen.
2. Im Arbeitsbereich **STIG Regeln** auf **DISA STIG ZIP importieren** klicken.
3. Die unveränderte ZIP-Datei auswählen. Ein manuelles Entpacken ist nicht erforderlich.
4. Titel, Version, Release-Datum und Regelanzahl im Viewer prüfen, bevor Regeln ausgewählt oder mit KI analysiert werden.

Getestete Beispiele:

- [Microsoft Windows 11 STIG V2R11](https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_MS_Windows_11_V2R11_STIG.zip)
- [Microsoft Entra ID STIG V1R2](https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_MS_Entra_ID_V1R2_STIG.zip)
- [Oracle Linux 9 STIG V1R7](https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_Oracle_Linux_9_V1R7_STIG.zip)

Der Import verarbeitet XCCDF-Dateien innerhalb normaler und verschachtelter ZIP-Dateien direkt im Browser. ZIP-Inhalte werden nicht zum Server hochgeladen. Entsprechend der [Cyber.mil-FAQ](https://www.cyber.mil/stigs/faqs) sind die `MANUAL_STIG`-Pakete die menschenlesbaren XCCDF-Ausgaben. Die offizielle DISA-Anwendung und Dokumentation stehen zusätzlich unter [SRG and STIG Tools](https://www.cyber.mil/stigs/srg-stig-tools) bereit.

STIG-Versionen sind fachlich relevant: Vor Analyse oder Export muss geprüft werden, dass Version und Release zum gewünschten Sollstand passen. Das Repository enthält deshalb keine fest eingecheckte Windows-11-XCCDF-Datei und keine daraus generierten Regeln mehr.

## Azure OpenAI

Die Zugangsdaten liegen ausschließlich im lokalen API-Prozess. In `.env` werden Endpoint, API-Key und der Deploymentname `gpt-5-mini` gesetzt. Das Backend nutzt die Azure OpenAI Responses API v1; ein datierter `AZURE_OPENAI_API_VERSION`-Wert ist nicht erforderlich. Pro Aufruf werden maximal 30 ausgewählte Regeln analysiert. Modellantworten werden als Vorschläge behandelt; vor dem Intune-Produktiveinsatz müssen CSP-Pfade, Datentypen und Werte gegen die aktuelle Microsoft-Dokumentation geprüft und in einem Test-Ring validiert werden.

Die KI-Analyse ist nicht auf Microsoft-Produkte beschränkt. Sie muss Produkt, Plattform, Version und technische Steuerungsebene aus Benchmark und Regeltext erkennen, bevor sie ein Werkzeug auswählt. Jede Anforderung wird zunächst einem Zielsystem zugeordnet:

- native Intune-Richtlinie oder CSP-Einstellung,
- Microsoft-Entra-Portal beziehungsweise Entra Graph API,
- anderer Microsoft-365-Workload,
- deklaratives Konfigurationsmanagement wie Ansible, DSC, Puppet, Chef oder Salt,
- native Hersteller-API, Betriebssystem- oder Anwendungskonfiguration,
- Cloud-API beziehungsweise Infrastructure as Code,
- PowerShell-, Bash-, Python- oder lokale Skriptautomatisierung,
- ausschließlich manuelle Maßnahme oder nicht anwendbar.

Für jeden analysierten Eintrag werden Plattform, Steuerungsebene, Automatisierungsmethode, API/CLI, erforderliche Berechtigungen, erzeugbare Artefakte, Umsetzung, Validierung, Rollback und eine manuelle Alternative ausgegeben. Für Linux wird ein idempotenter Ansible- oder vergleichbarer Konfigurationsmanagement-Ansatz bevorzugt; OpenSCAP kann die Validierung unterstützen, ersetzt aber nicht automatisch die Remediation. Intune-Konfigurationsprofile verwenden typischerweise `DeviceManagementConfiguration.ReadWrite.All`; Intune-Skripte `DeviceManagementScripts.ReadWrite.All`; Conditional-Access-Richtlinien `Policy.Read.All` und `Policy.ReadWrite.ConditionalAccess`. Nicht belegbare APIs, Module oder Befehle dürfen nicht erfunden werden.

## KI-Provider im Browser

Über das Regler-Symbol oben rechts kann der Provider für die aktuelle Browser-Sitzung gewählt werden:

- **Azure OpenAI** mit Endpoint, API-Key und Deployment `gpt-5-mini`; alternativ werden die Werte aus der lokalen `.env` verwendet.
- **OpenAI API** mit API-Key und einer dynamisch über `GET /v1/models` geladenen Modellauswahl.
- **Google AI** mit Gemini-API-Key und einer dynamisch geladenen Auswahl aller Modelle, die `generateContent` unterstützen.

Browser-Einstellungen werden ausschließlich in `sessionStorage` gehalten und beim Schließen des Tabs verworfen. Der API-Key wird an den lokalen Node-Server und von dort ausschließlich an den ausgewählten Provider übertragen. Er wird weder in Projektdateien geschrieben noch in Analyseberichten exportiert. Auf gemeinsam genutzten Rechnern sollte die Sitzung nach Verwendung geschlossen werden.

Alternativ kann im Dialog eine lokale `.env`-Datei ausgewählt werden. Sie wird im Browser gelesen und nicht hochgeladen oder in das Repository kopiert. Dieselben Variablen können serverseitig in der Projektdatei `.env` gesetzt werden:

```dotenv
# Azure OpenAI
AI_PROVIDER=azure
AZURE_OPENAI_ENDPOINT=https://RESOURCE.openai.azure.com
AZURE_OPENAI_API_KEY=...
AZURE_OPENAI_DEPLOYMENT=gpt-5-mini

# oder OpenAI
AI_PROVIDER=openai
OPENAI_API_KEY=...
OPENAI_MODEL=gpt-5-mini

# oder Google AI
AI_PROVIDER=google
GOOGLE_AI_API_KEY=...
GOOGLE_AI_MODEL=gemini-flash-latest
```

Wenn noch keine Browser-Einstellung in der Sitzung existiert, übernimmt die Oberfläche Provider und Modell automatisch aus der serverseitigen `.env`. Schlüssel werden dabei niemals an den Browser zurückgegeben.

Die KI-Antworten werden vor der Anzeige normalisiert. Dadurch führen ältere oder unvollständige Backend-Antworten nicht mehr zu einem Abbruch der React-Oberfläche. Nach einem Softwareupdate sollten trotzdem sowohl Vite-Frontend als auch API-Prozess gemeinsam mit `npm start` neu gestartet werden.

## Intune Policy Package

Der zweite Arbeitsbereich **Policy Package** importiert ein originales DISA Intune Policy Package direkt als ZIP-Datei. Ein manuelles Entpacken und ein lokaler `Package/`-Ordner sind nicht erforderlich. Die Übersicht kategorisiert die enthaltenen Policy-JSONs nach Profiltyp, Produkt, Plattform und **Version**. Policies können ausgewählt, durch Azure OpenAI hinsichtlich Zweck, Abhängigkeiten und Risiken erklärt und anschließend mit ihren unveränderten Originalobjekten als gemeinsames JSON-Paket exportiert werden.

Vorgehen:

1. Das aktuelle Paket unter [DoD Cyber Exchange – Group Policy Objects](https://www.cyber.mil/stigs/gpo) herunterladen.
2. Im Arbeitsbereich **Policy Package** auf **Intune Policy ZIP importieren** klicken.
3. Die unveränderte ZIP-Datei auswählen.
4. Package-Release und erkannte Policy-Versionen prüfen.
5. Gewünschte Policies auswählen, optional mit KI erklären lassen und das Auswahlpaket exportieren.

Die ZIP-Datei und ihre Policy-Inhalte werden ausschließlich lokal im Browser verarbeitet und nicht zum Server übertragen. Das Repository enthält deshalb weder das originale Intune Policy Package noch daraus generierte Metadaten. Beim Austausch eines Pakets muss immer geprüft werden, ob die jeweilige STIG- und Policy-Version zur vorgesehenen Zielumgebung passt; gleichnamige Policies unterschiedlicher Releases sind nicht automatisch austauschbar. Jede zusammengestellte Auswahl muss vor dem Produktiveinsatz in einer repräsentativen Testumgebung geprüft werden.
