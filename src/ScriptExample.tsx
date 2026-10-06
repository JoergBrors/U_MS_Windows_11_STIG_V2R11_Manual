import{useState}from'react';
import{Check,Copy}from'lucide-react';

export default function ScriptExample({language,code}:{language?:string;code?:string}){
 const[copied,setCopied]=useState(false);
 if(!code?.trim())return null;
 async function copy(){try{await navigator.clipboard.writeText(code??'')}catch{const area=document.createElement('textarea');area.value=code??'';document.body.appendChild(area);area.select();document.execCommand('copy');area.remove()}setCopied(true);window.setTimeout(()=>setCopied(false),1800)}
 return <div className="script-example"><div className="script-head"><span>Beispiel-Skript{language?` · ${language}`:''}</span><button onClick={copy}>{copied?<Check/>:<Copy/>}{copied?'Kopiert':'Kopieren'}</button></div><pre><code>{code}</code></pre></div>;
}
