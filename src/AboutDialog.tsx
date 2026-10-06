import{useEffect,useState}from'react';
import{ExternalLink,Info,X}from'lucide-react';
import type{AppMeta}from'./types';

export default function AboutDialog({onClose}:{onClose:()=>void}){
 const[meta,setMeta]=useState<AppMeta|null>(null);const[error,setError]=useState('');
 useEffect(()=>{void fetch('/api/about').then(response=>{if(!response.ok)throw new Error();return response.json()}).then(setMeta).catch(()=>setError('Die Metadaten konnten nicht vom lokalen Server geladen werden.'))},[]);
 const rows:[string,string][]=meta?[['Version',meta.version],['Autor',meta.author],['Kontakt',meta.contact],['Lizenz',meta.license]].filter((row):row is [string,string]=>Boolean(row[1])):[];
 return <div className="settings-overlay" onClick={onClose}><section className="settings-modal about-modal" role="dialog" aria-modal="true" aria-label="Über" onClick={event=>event.stopPropagation()}>
  <div className="settings-head"><div><span>ÜBER</span><h2>{meta?.name??'Policy Studio'}</h2></div><button onClick={onClose} aria-label="Schließen"><X/></button></div>
  {error&&<p className="settings-error">{error}</p>}
  {meta?.description&&<p className="about-description">{meta.description}</p>}
  {rows.length>0&&<dl className="about-list">{rows.map(([label,value])=><div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>}
  {meta&&!rows.length&&!meta.description&&<p className="about-description">Keine Metadaten konfiguriert. Setze APP_* Werte in der serverseitigen .env.</p>}
  <footer>{meta?.repositoryUrl&&<a className="about-link" href={meta.repositoryUrl} target="_blank" rel="noopener noreferrer"><ExternalLink/> Repository</a>}<button onClick={onClose}>Schließen</button></footer>
 </section></div>;
}
