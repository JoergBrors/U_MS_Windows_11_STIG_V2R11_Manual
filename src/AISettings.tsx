import{useEffect,useState}from'react';
import{Cloud,FileUp,KeyRound,LoaderCircle,RefreshCw,X}from'lucide-react';
import type{AiConfig,AiProvider}from'./types';

const providerNames:{id:AiProvider;label:string;hint:string}[]=[
 {id:'azure',label:'Azure OpenAI',hint:'Azure-Endpunkt mit Deployment gpt-5-mini'},
 {id:'openai',label:'OpenAI API',hint:'Verfügbare Textmodelle aus dem OpenAI-Konto'},
 {id:'google',label:'Google AI',hint:'Gemini-Modelle mit generateContent-Unterstützung'}
];
async function parseJson(response:Response){const text=await response.text();try{return JSON.parse(text)}catch{throw new Error('Der lokale API-Server hat keine gültige JSON-Antwort geliefert.')}}
function parseEnv(text:string):AiConfig{
 const values:Record<string,string>={};
 for(const raw of text.split(/\r?\n/)){const line=raw.trim().replace(/^export\s+/,'');if(!line||line.startsWith('#'))continue;const index=line.indexOf('=');if(index<1)continue;const key=line.slice(0,index).trim();let value=line.slice(index+1).trim();if((value.startsWith('"')&&value.endsWith('"'))||(value.startsWith("'")&&value.endsWith("'")))value=value.slice(1,-1);values[key]=value}
 const configured=values.AI_PROVIDER?.toLowerCase();const provider:AiProvider=configured==='openai'||configured==='google'||configured==='azure'?configured:values.OPENAI_API_KEY?'openai':values.GOOGLE_AI_API_KEY||values.GEMINI_API_KEY?'google':'azure';
 if(provider==='azure')return{provider,apiKey:values.AZURE_OPENAI_API_KEY??'',endpoint:values.AZURE_OPENAI_ENDPOINT??'',model:values.AZURE_OPENAI_DEPLOYMENT??'gpt-5-mini'};
 if(provider==='openai')return{provider,apiKey:values.OPENAI_API_KEY??'',endpoint:'',model:values.OPENAI_MODEL??''};
 return{provider,apiKey:values.GOOGLE_AI_API_KEY??values.GEMINI_API_KEY??'',endpoint:'',model:values.GOOGLE_AI_MODEL??values.GEMINI_MODEL??''};
}

export default function AISettings({value,onSave,onClose}:{value:AiConfig;onSave:(next:AiConfig)=>void;onClose:()=>void}){
 const[draft,setDraft]=useState(value);const[models,setModels]=useState<string[]>([]);const[serverProviders,setServerProviders]=useState<Partial<Record<AiProvider,string>>>({});const[busy,setBusy]=useState(false);const[error,setError]=useState('');
 useEffect(()=>{setModels([]);setError('')},[draft.provider]);
 useEffect(()=>{void fetch('/api/health').then(response=>response.json()).then(json=>setServerProviders(Object.fromEntries((json.configuredProviders??[]).map((item:{provider:AiProvider;model:string})=>[item.provider,item.model])))).catch(()=>undefined)},[]);
 async function loadEnv(file?:File){if(!file)return;try{setDraft(parseEnv(await file.text()));setModels([]);setError('')}catch{setError('Die .env-Datei konnte nicht gelesen werden.')}}
 async function loadModels(){setBusy(true);setError('');try{const response=await fetch('/api/ai/models',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({ai:draft})});const json=await parseJson(response);if(!response.ok)throw new Error(json.error);setModels(json.models??[]);if(!draft.model&&json.models?.length)setDraft(current=>({...current,model:json.models[0]}))}catch(reason){setError(reason instanceof Error?reason.message:'Modelle konnten nicht geladen werden.')}finally{setBusy(false)}}
 return <div className="settings-overlay"><section className="settings-modal">
  <div className="settings-head"><div><span>KI-PROVIDER</span><h2>Analyse im Browser konfigurieren</h2></div><button onClick={onClose}><X/></button></div>
  <p className="settings-note"><KeyRound/> Zugangsdaten bleiben nur in dieser Browser-Sitzung gespeichert und werden ausschließlich über den lokalen Server an den gewählten Provider gesendet.</p>
  <label className="env-import"><input type="file" accept=".env,text/plain" onChange={event=>{void loadEnv(event.target.files?.[0]);event.currentTarget.value=''}}/><FileUp/><span><b>.env-Datei laden</b><small>Provider, Schlüssel, Endpoint und Modell lokal übernehmen</small></span></label>
  <div className="provider-grid">{providerNames.map(provider=><button key={provider.id} className={draft.provider===provider.id?'active':''} onClick={()=>setDraft(current=>({...current,provider:provider.id,apiKey:'',endpoint:provider.id==='azure'?current.endpoint:'',model:serverProviders[provider.id]??(provider.id==='azure'?'gpt-5-mini':'')}))}><Cloud/><b>{provider.label}</b><small>{provider.hint}</small>{serverProviders[provider.id]!==undefined&&<em>Server-.env · {serverProviders[provider.id]||'Modell wählen'}</em>}</button>)}</div>
  <div className="settings-fields">{draft.provider==='azure'&&<label><span>Azure OpenAI Endpoint</span><input value={draft.endpoint} onChange={event=>setDraft({...draft,endpoint:event.target.value})} placeholder="https://…openai.azure.com"/></label>}<label><span>API-Key</span><input type="password" value={draft.apiKey} onChange={event=>setDraft({...draft,apiKey:event.target.value})} placeholder="Leer lassen, um die serverseitige .env zu verwenden"/></label>{draft.provider==='azure'?<label><span>Deployment</span><input value={draft.model} onChange={event=>setDraft({...draft,model:event.target.value})} placeholder="gpt-5-mini"/></label>:<label><span>Modell</span><div className="model-row"><select value={draft.model} onChange={event=>setDraft({...draft,model:event.target.value})}><option value="">Modell auswählen…</option>{draft.model&&!models.includes(draft.model)&&<option>{draft.model}</option>}{models.map(model=><option key={model}>{model}</option>)}</select><button onClick={loadModels} disabled={busy}>{busy?<LoaderCircle className="spin"/>:<RefreshCw/>} Modelle laden</button></div></label>}</div>
  {error&&<p className="settings-error">{error}</p>}<footer><button onClick={onClose}>Abbrechen</button><button className="save" onClick={()=>{onSave(draft);onClose()}}>Für diese Sitzung speichern</button></footer>
 </section></div>;
}
