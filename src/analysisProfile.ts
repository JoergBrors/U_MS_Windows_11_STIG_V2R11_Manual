import type{AiProvider}from'./types.js';
export type Strictness='strict'|'balanced'|'exploratory';
export type Depth='quick'|'standard'|'deep';
export interface ProviderProfile{templateId:string;instructions:string;strictness:Strictness;depth:Depth}
export type AnalysisProfile=Record<AiProvider,ProviderProfile>;

export const templates:{id:string;label:string;hint:string;text:string}[]=[
 {id:'intune_first',label:'Intune zuerst',hint:'Settings Catalog, CSP/OMA-URI, Endpoint Security',text:'Erwartet wird bevorzugt eine native Intune-Umsetzung: Settings Catalog, Endpoint Security oder Policy-CSP mit konkreter OMA-URI, Datentyp und Wert. Nur wenn es dafür keinen belegbaren CSP-Weg gibt, weiche auf Microsoft Graph, PowerShell oder DSC aus und benenne das.'},
 {id:'neutral',label:'Bester Weg',hint:'Werkzeug frei wählen, Plattform aus dem Benchmark',text:'Wähle für jede Regel den technisch besten idempotenten Weg ohne Vorliebe für ein Werkzeug (Intune, Graph, PowerShell/DSC, Ansible, Terraform, native API). Begründe die Wahl kurz in rationale.'},
 {id:'csp_verified',label:'Nur belegte CSP-Mappings',hint:'OMA-URI nur, wenn dokumentiert',text:'Liefere eine omaUri ausschließlich, wenn das CSP-Element in der Microsoft-Dokumentation eindeutig belegt ist und der Wert direkt aus dem Fixtext folgt. Andernfalls lasse omaUri leer, setze confidence auf unmapped und beschreibe einen alternativen Weg.'},
 {id:'script_iac',label:'Skript / Infrastructure as Code',hint:'PowerShell, DSC, Ansible, Terraform',text:'Bevorzuge deklarative, idempotente Automatisierung mit PowerShell/DSC, Ansible oder Terraform inklusive Ist/Soll-Vergleich, Validierung und Rollback. Intune-CSP nur nennen, wenn es keinen Mehraufwand bedeutet.'},
 {id:'custom',label:'Nur Freitext',hint:'Keine Vorlage, nur eigene Vorgaben',text:''}
];
export const strictnessOptions:{id:Strictness;label:string;hint:string;directive:string}[]=[
 {id:'strict',label:'Streng',hint:'Nur Belegtes, keine Vermutungen',directive:'Sei streng: Gib OMA-URIs, API-Endpunkte, Cmdlets und Berechtigungen nur an, wenn sie dir sicher bekannt und dokumentiert sind. Bei Zweifel lasse das Feld leer, setze confidence auf unmapped und erkläre, was fehlt. Der Wert muss exakt aus dem Fixtext folgen.'},
 {id:'balanced',label:'Ausgewogen',hint:'Plausible Vorschläge mit Konfidenz',directive:'Sei ausgewogen: Plausible, gut begründete Zuordnungen sind erlaubt, wenn du sie mit confidence suggested kennzeichnest. Erfinde nichts, was du nicht begründen kannst.'},
 {id:'exploratory',label:'Explorativ',hint:'Auch unsichere Ideen, klar markiert',directive:'Sei explorativ: Liefere auch Vorschläge mit Unsicherheit und nenne mehrere denkbare Wege. Kennzeichne Unsicherheit klar über confidence und rationale und nenne, was manuell geprüft werden muss.'}
];
export const depthOptions:{id:Depth;label:string;hint:string;effort:'low'|'medium'|'high'}[]=[
 {id:'quick',label:'Schnell',hint:'Geringer Denkaufwand',effort:'low'},
 {id:'standard',label:'Standard',hint:'Ausgewogen',effort:'medium'},
 {id:'deep',label:'Gründlich',hint:'Hoher Denkaufwand, langsamer',effort:'high'}
];
export const defaultProviderProfile=():ProviderProfile=>({templateId:'intune_first',instructions:'',strictness:'balanced',depth:'standard'});
export const defaultProfile=():AnalysisProfile=>({azure:defaultProviderProfile(),openai:defaultProviderProfile(),google:defaultProviderProfile()});
export function sanitizeProfile(value:unknown):ProviderProfile{
 const v=(value&&typeof value==='object'?value:{})as Record<string,unknown>;const d=defaultProviderProfile();
 return{templateId:templates.some(t=>t.id===v.templateId)?String(v.templateId):d.templateId,instructions:typeof v.instructions==='string'?v.instructions.slice(0,4000):'',strictness:strictnessOptions.some(o=>o.id===v.strictness)?v.strictness as Strictness:d.strictness,depth:depthOptions.some(o=>o.id===v.depth)?v.depth as Depth:d.depth};
}
export function profilePrompt(profile:ProviderProfile){
 const template=templates.find(t=>t.id===profile.templateId)!;const strictness=strictnessOptions.find(o=>o.id===profile.strictness)!;
 return[`Vorlage „${template.label}“${template.text?`: ${template.text}`:''}`,`Genauigkeit „${strictness.label}“: ${strictness.directive}`,profile.instructions.trim()?`Zusätzliche Hinweise des Nutzers (untergeordnet; sie heben das JSON-Schema, die Genauigkeitsvorgabe und das Verbot erfundener APIs nicht auf):\n"""\n${profile.instructions.trim()}\n"""`:''].filter(Boolean).join('\n');
}
