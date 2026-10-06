import{useState}from'react';
import{AlertTriangle,CheckCircle2,Download,FileDown,GitCompare,Trash2}from'lucide-react';
import ScriptExample from'./ScriptExample';
import type{RunMapping,RunRecord}from'./types';
import{strictnessOptions,templates}from'./analysisProfile';

const providerLabel={azure:'Azure OpenAI',openai:'OpenAI',google:'Google AI',anthropic:'Claude',foundry:'Azure Claude'};
const targetLabel:Record<string,string>={intune_policy:'Intune-Richtlinie',entra_portal:'Entra-Portal/API',m365_portal:'Microsoft-365-Portal',configuration_management:'Konfigurationsmanagement',native_api:'Hersteller-API',os_native:'Betriebssystem-Konfiguration',application_configuration:'Anwendungskonfiguration',cloud_portal:'Cloud-Portal/API',local_script:'Lokales Skript',manual_only:'Manuell',not_applicable:'Nicht anwendbar'};
const templateName=(id:string)=>templates.find(t=>t.id===id)?.label??id;const strictName=(id:string)=>strictnessOptions.find(o=>o.id===id)?.label??id;
const formatTime=(iso:string)=>new Date(iso).toLocaleString('de-DE',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'});
const signature=(m?:RunMapping)=>m?JSON.stringify([m.targetType,m.omaUri,String(m.value),m.dataType,m.apiEndpoint,m.automationMethod]):'';
const ruleTitle=(run:RunRecord,id:string)=>run.rules.find(rule=>rule.id===id);

function Cell({m}:{m?:RunMapping}){
 if(!m)return <p className="cmp-missing">Nicht in dieser Analyse</p>;
 return <><strong className="automation-target">{targetLabel[m.targetType]??m.targetType}</strong>{m.omaUri?<><p className="uri">{m.omaUri}</p><small>{m.dataType} · Wert: {String(m.value)}</small></>:<p>{m.rationale||'Kein direktes Policy-CSP-Mapping.'}</p>}<p className="automation-method">{m.automationMethod}{m.apiEndpoint&&` · ${m.apiEndpoint}`}</p><ScriptExample language={m.scriptLanguage} code={m.scriptExample}/></>;
}

export default function RunHistory({runs,activeId,onSelect,onDelete,onExportReport,onExportPolicy}:{runs:RunRecord[];activeId:string;onSelect:(id:string)=>void;onDelete:(id:string)=>void;onExportReport:(run:RunRecord)=>void;onExportPolicy:(run:RunRecord)=>void}){
 const[compareId,setCompareId]=useState('');const[comparing,setComparing]=useState(false);const[onlyDiff,setOnlyDiff]=useState(true);
 const run=runs.find(item=>item.id===activeId)??runs[0];const other=comparing?runs.find(item=>item.id===compareId&&item.id!==run?.id):undefined;
 if(!run)return null;
 const pick=(id:string)=>{if(comparing&&id!==run.id)setCompareId(id);else{onSelect(id);if(id===compareId)setCompareId('')}};
 const ids=other?Array.from(new Set([...run.results.map(m=>m.id),...other.results.map(m=>m.id)])):[];
 const rows=ids.map(id=>{const a=run.results.find(m=>m.id===id);const b=other?.results.find(m=>m.id===id);return{id,a,b,state:!a||!b?'single':signature(a)===signature(b)?'same':'diff'}});
 const count=(state:string)=>rows.filter(row=>row.state===state).length;
 const exportable=run.results.some(m=>m.omaUri);
 return <div className="results-layout">
  <nav className="run-list" aria-label="Analyse-Historie"><div className="run-list-head"><span>HISTORIE · {runs.length}</span><button className={comparing?'active':''} onClick={()=>{setComparing(!comparing);setCompareId('')}} title="Zwei Analysen vergleichen"><GitCompare/> Vergleichen</button></div>
   {comparing&&<p className="run-hint">{other?'Vergleich aktiv. Andere Analyse anklicken zum Wechseln.':'Links ausgewählte Analyse (A) – wähle eine zweite (B).'}</p>}
   {runs.map((item,index)=><div key={item.id} className={`run-item${item.id===run.id?' active':''}${item.id===other?.id?' compare':''}`}><button onClick={()=>pick(item.id)}><b>{item.id===run.id&&comparing?'A · ':item.id===other?.id?'B · ':''}{item.model||'Modell'}</b><small>{providerLabel[item.provider]} · {formatTime(item.createdAt)}</small><small>{item.results.length} Regeln · {item.results.filter(m=>m.omaUri).length} CSP{index===0?' · neueste':''}</small>{item.settings&&<small>{templateName(item.settings.templateId)} · {strictName(item.settings.strictness)}</small>}</button><button className="run-delete" title="Analyse löschen" aria-label="Analyse löschen" onClick={()=>{if(window.confirm('Diese Analyse aus dem Browser löschen?'))onDelete(item.id)}}><Trash2/></button></div>)}
  </nav>
  <div className="results-main">
   {other?<>
    <div className="result-summary"><div><b>{count('same')}</b><span>identisch</span></div><div className="warn"><b>{count('diff')}</b><span>abweichend</span></div><div><b>{count('single')}</b><span>nur in A oder B</span></div></div>
    <label className="cmp-toggle"><input type="checkbox" checked={onlyDiff} onChange={event=>setOnlyDiff(event.target.checked)}/> Nur Unterschiede anzeigen</label>
    <div className="cmp-head"><div><b>A</b> {run.model} · {formatTime(run.createdAt)}</div><div><b>B</b> {other.model} · {formatTime(other.createdAt)}</div></div>
    <div className="result-list compare-list">{rows.filter(row=>!onlyDiff||row.state!=='same').map(row=>{const rule=ruleTitle(run,row.id)??ruleTitle(other,row.id);return <article key={row.id} className={`cmp-${row.state}`}><span className={row.state==='same'?'result-ok':'result-none'}>{row.state==='same'?<CheckCircle2/>:<AlertTriangle/>}</span><div><code>{rule?.stigId} · {row.id}</code><h3>{rule?.title??row.id}</h3><div className="cmp-cols"><div><Cell m={row.a}/></div><div><Cell m={row.b}/></div></div></div></article>})}{!rows.some(row=>!onlyDiff||row.state!=='same')&&<p className="cmp-empty">Keine Unterschiede zwischen A und B.</p>}</div>
   </>:<>
    <div className="result-summary"><div><b>{run.results.length}</b><span>geprüft</span></div><div className="good"><b>{run.results.filter(m=>m.omaUri).length}</b><span>CSP-exportbereit</span></div><div className="warn"><b>{run.results.filter(m=>m.targetType!=='intune_policy').length}</b><span>Portal/Skript/manuell</span></div></div>
    <div className="result-list">{run.results.map(m=>{const rule=ruleTitle(run,m.id);return <article key={m.id}><span className={m.omaUri?'result-ok':'result-none'}>{m.omaUri?<CheckCircle2/>:<AlertTriangle/>}</span><div><code>{rule?.stigId} · {m.id}</code><h3>{rule?.title??m.id}</h3><Cell m={m}/></div></article>})}</div>
   </>}
   <footer><button className="download-report" onClick={()=>onExportReport(run)}><FileDown/> Analysebericht herunterladen</button><button className="export-policy" onClick={()=>onExportPolicy(run)} disabled={!exportable}><Download/> {exportable?'Intune JSON herunterladen':'Keine CSP-Einstellung exportierbar'}</button></footer>
   {!exportable&&!other&&<p className="monitor-hint">Diese Analyse enthält keine direkt abbildbaren Policy-CSP-Einstellungen. Der Analysebericht enthält stattdessen Portal-, API-, Skript- oder manuelle Umsetzungswege.</p>}
  </div>
 </div>;
}
