# DISA STIG → Intune Policy Studio

Lokaler TypeScript/React-Viewer für DISA-STIG-Pakete im XCCDF-Format. Die Oberfläche importiert originale ZIP-Dateien, erkennt Benchmark und Version, kategorisiert die Regeln und exportiert geprüfte Einstellungen als Microsoft-Graph-kompatible `windows10CustomConfiguration`.

## Start

```bash
npm install
cp .env.example .env   # optional: Azure OpenAI konfigurieren
npm start
```

Danach `http://localhost:5173` öffnen. Ohne Azure-Konfiguration ist der STIG-Viewer nutzbar; CSP-Mappings können erst nach Konfiguration geprüft werden.

## STIG-ZIP importieren

1. Die [STIGs Document Library](https://www.cyber.mil/stigs/downloads/) öffnen und das gewünschte aktuelle STIG-Paket herunterladen.
2. Im Arbeitsbereich **STIG Regeln** auf **DISA STIG ZIP importieren** klicken.
3. Die unveränderte ZIP-Datei auswählen. Ein manuelles Entpacken ist nicht erforderlich.
4. Titel, Version, Release-Datum und Regelanzahl im Viewer prüfen, bevor Regeln ausgewählt oder mit KI analysiert werden.

Getestete Beispiele:

- [Microsoft Windows 11 STIG V2R11](https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_MS_Windows_11_V2R11_STIG.zip)
- [Microsoft Entra ID STIG V1R2](https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_MS_Entra_ID_V1R2_STIG.zip)

Der Import verarbeitet XCCDF-Dateien innerhalb normaler und verschachtelter ZIP-Dateien direkt im Browser. ZIP-Inhalte werden nicht zum Server hochgeladen. Entsprechend der [Cyber.mil-FAQ](https://www.cyber.mil/stigs/faqs) sind die `MANUAL_STIG`-Pakete die menschenlesbaren XCCDF-Ausgaben. Die offizielle DISA-Anwendung und Dokumentation stehen zusätzlich unter [SRG and STIG Tools](https://www.cyber.mil/stigs/srg-stig-tools) bereit.

STIG-Versionen sind fachlich relevant: Vor Analyse oder Export muss geprüft werden, dass Version und Release zum gewünschten Sollstand passen. Das Repository enthält deshalb keine fest eingecheckte Windows-11-XCCDF-Datei und keine daraus generierten Regeln mehr.

## Azure OpenAI

Die Zugangsdaten liegen ausschließlich im lokalen API-Prozess. In `.env` werden Endpoint, API-Key und der Deploymentname `gpt-5-mini` gesetzt. Das Backend nutzt die Azure OpenAI Responses API v1; ein datierter `AZURE_OPENAI_API_VERSION`-Wert ist nicht erforderlich. Pro Aufruf werden maximal 30 ausgewählte Regeln analysiert. Modellantworten werden als Vorschläge behandelt; vor dem Intune-Produktiveinsatz müssen CSP-Pfade, Datentypen und Werte gegen die aktuelle Microsoft-Dokumentation geprüft und in einem Test-Ring validiert werden.

## Intune Policy Package

Der zweite Arbeitsbereich **Policy Package** liest die lokal mitgelieferten Exporte unter `Package/U_Intune_Policy_Package_July_2026`. Dieser Ordner wird bewusst nicht in Git aufgenommen. Die Übersicht kategorisiert die Policies nach Profiltyp, Produkt, Plattform und **Version**. Policies können ausgewählt, durch Azure OpenAI hinsichtlich Zweck, Abhängigkeiten und Risiken erklärt und anschließend als gemeinsames JSON-Paket exportiert werden.

Aktuelle offizielle DISA-Pakete stehen unter [DoD Cyber Exchange – Group Policy Objects](https://www.cyber.mil/stigs/gpo) bereit. Beim Austausch eines Pakets muss immer geprüft werden, ob die jeweilige STIG- und Policy-Version zur vorgesehenen Zielumgebung passt; gleichnamige Policies unterschiedlicher Releases sind nicht automatisch austauschbar.

Nach Änderungen am DISA-Paket werden die Metadaten neu erzeugt:

```bash
npm run generate:package
```

Mit `npm run generate` wird die Paketübersicht aktualisiert. Die Original-Policies bleiben unverändert. Entsprechend der Hersteller-README muss jede zusammengestellte Auswahl vor dem Produktiveinsatz in einer repräsentativen Testumgebung geprüft werden.
