import{useEffect,useState}from'react';
import{LogOut}from'lucide-react';

interface Me{authenticated:boolean;name?:string;email?:string;photoAvailable?:boolean}
const initials=(name:string)=>name.split(/[\s@.]+/).filter(Boolean).slice(0,2).map(part=>part[0]?.toUpperCase()).join('')||'?';

// Zeigt die über Entra ID angemeldete Person samt Profilbild und Abmelden. Lokal (ohne Anmeldung) bleibt der Bereich leer.
export default function UserMenu(){
 const[me,setMe]=useState<Me|null>(null);const[photoFailed,setPhotoFailed]=useState(false);
 useEffect(()=>{void fetch('/api/me').then(response=>response.ok?response.json():null).then(setMe).catch(()=>setMe(null))},[]);
 if(!me?.authenticated)return null;
 const name=me.name||me.email||'Angemeldet';
 return <div className="user-menu" title={me.email||name}>
  {me.photoAvailable&&!photoFailed?<img className="avatar" src="/api/me/photo" alt="" onError={()=>setPhotoFailed(true)}/>:<span className="avatar fallback" aria-hidden="true">{initials(name)}</span>}
  <span className="user-text"><b>{name}</b>{me.email&&me.email!==name&&<small>{me.email}</small>}</span>
  <a className="logout" href="/.auth/logout?post_logout_redirect_uri=/" title="Abmelden" aria-label="Abmelden"><LogOut/></a>
 </div>;
}
