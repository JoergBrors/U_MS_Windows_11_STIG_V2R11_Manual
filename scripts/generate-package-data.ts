import{readFile,readdir,writeFile}from'node:fs/promises';
import{basename,dirname,extname,join,relative,sep}from'node:path';

const root='Package/U_Intune_Policy_Package_July_2026';
const policiesRoot=join(root,'Intune Policies');

async function walk(dir:string):Promise<string[]>{const entries=await readdir(dir,{withFileTypes:true});const nested=await Promise.all(entries.map(entry=>entry.isDirectory()?walk(join(dir,entry.name)):Promise.resolve([join(dir,entry.name)])));return nested.flat()}
function decode(buffer:Buffer){if(buffer[0]===0xff&&buffer[1]===0xfe)return buffer.subarray(2).toString('utf16le');return buffer.toString('utf8').replace(/^\uFEFF/,'')}
function product(name:string){for(const [label,pattern] of [['Windows 11',/Windows 11/i],['Windows 10',/Windows 10/i],['Microsoft Defender',/Defender/i],['Microsoft Edge',/Edge/i],['Google Chrome',/Chrome/i],['Microsoft 365 Apps',/M365|Office/i],['Adobe Acrobat',/Adobe Acrobat/i],['Internet Explorer',/Internet Explorer/i],['Mozilla Firefox',/Firefox/i],['OneDrive',/OneDrive/i],['Windows',/Windows|USB|\.NET/i]] as const)if(pattern.test(name))return label;return'Weitere'}
function platform(value:unknown,name:string){const raw=String(value??'').toLowerCase();if(raw.includes('mac')||/macOS/i.test(name))return'macOS';if(raw.includes('android')||/Android/i.test(name))return'Android';return'Windows'}
function version(name:string){const match=name.match(/\bv\d+r\d+\b/i)??name.match(/\b(\d+)vr(\d+)\b/i);return match?match[0].replace(/^(\d+)vr(\d+)$/i,'v$1r$2').toLowerCase():'Ohne Versionsangabe'}
function countSettings(json:Record<string,unknown>){if(typeof json.settingCount==='number')return json.settingCount;for(const key of['settings','omaSettings','definitionValues','customSettings'])if(Array.isArray(json[key]))return json[key].length;return undefined}

const paths=(await walk(policiesRoot)).filter(path=>extname(path).toLowerCase()==='.json');
const policies=[];
for(const path of paths){
 const text=decode(await readFile(path));let json:Record<string,unknown>={};try{json=JSON.parse(text)}catch{console.warn(`Could not parse ${path}`)}
 const rel=relative(root,path).split(sep).join('/');const category=relative(policiesRoot,dirname(path)).split(sep)[0];const name=String(json.name??json.displayName??basename(path,'.json'));
 policies.push({id:rel,name,version:version(name),category,product:product(name),platform:platform(json.platforms,name),description:String(json.description??''),settings:countSettings(json),technology:String(json.technologies??json['@odata.type']??category),sourceFile:rel,fileSize:Buffer.byteLength(text)});
}
policies.sort((a,b)=>a.category.localeCompare(b.category)||a.name.localeCompare(b.name));
const output={package:{name:'DISA STIG Intune Policy Package',release:'July 2026',scope:'Windows 10/11 und ergänzende Anwendungsprofile',warning:'Alle Richtlinien müssen vor dem Produktiveinsatz in einer repräsentativen Testumgebung geprüft werden.',guidance:'Settings-Catalog-Profile bündeln Betriebssystem- oder Anwendungsanforderungen. Bestehende Microsoft Security Baselines können stattdessen mit administrativen Vorlagen, Endpoint Security und Custom Profiles kombiniert werden.',knownIssues:['Checklist-Zuordnungen befinden sich im separaten DISA STIG GPO Package.','Das Google-Chrome-App-Konfigurationsprofil deckt nicht alle STIG-Anforderungen ab.','Custom-Policy-Imports enthalten keine erforderliche OMA-URI für ADMX-Ingestion; diese muss nach dem Import ergänzt werden.','Microsoft Edge für macOS benötigt für vollständige Abdeckung zusätzliche Preference-File-Einstellungen.']},policies};
await writeFile('src/data/package-policies.json',JSON.stringify(output,null,2));
console.log(`Generated ${policies.length} package policies`);
