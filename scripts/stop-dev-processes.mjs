import { execFileSync } from 'node:child_process';

const ports=[5173,5174,5175,5176,5177,5178,5179,8787];

function listenerPids(port){
  try{
    return execFileSync('lsof',['-tiTCP:'+port,'-sTCP:LISTEN'],{encoding:'utf8'})
      .split(/\s+/).filter(Boolean).map(Number).filter(Number.isInteger);
  }catch{return[]}
}

const pids=[...new Set(ports.flatMap(listenerPids))].filter(pid=>pid!==process.pid);
function processInfo(pid){
  try{
    const output=execFileSync('ps',['-p',String(pid),'-o','uid=','-o','command='],{encoding:'utf8'}).trim();
    const match=output.match(/^(\d+)\s+(.+)$/s);
    return match?{uid:Number(match[1]),command:match[2]}:null;
  }catch{return null}
}

const ownUid=typeof process.getuid==='function'?process.getuid():undefined;
const projectPids=pids.filter(pid=>{
  const info=processInfo(pid);
  if(!info||ownUid!==undefined&&info.uid!==ownUid)return false;
  const isVite=/(?:^|[/\\])vite(?:\s|$)/.test(info.command);
  const isTsxServer=/(?:[/\\]node_modules[/\\](?:\.bin[/\\]tsx|tsx[/\\]))/.test(info.command)&&/\bserver[/\\]index\.ts\b/.test(info.command);
  return isVite||isTsxServer;
});
const skipped=pids.filter(pid=>!projectPids.includes(pid));
if(skipped.length){
  console.error(`Port belegt durch nicht als Projektprozess erkannten Prozess: ${skipped.join(', ')}. Dieser Prozess wird nicht beendet.`);
  process.exit(1);
}
if(!projectPids.length){
  console.log('Keine alten Entwicklungsprozesse auf den Projektports gefunden.');
  process.exit(0);
}

for(const pid of projectPids){
  try{
    process.kill(pid,'SIGTERM');
    console.log(`Alten Entwicklungsprozess ${pid} beendet.`);
  }catch(error){
    if(error?.code!=='ESRCH')throw error;
  }
}

await new Promise(resolve=>setTimeout(resolve,500));
for(const pid of projectPids){
  try{process.kill(pid,0)}catch{continue}
  try{
    process.kill(pid,'SIGKILL');
    console.log(`Prozess ${pid} musste erzwungen beendet werden.`);
  }catch(error){
    if(error?.code!=='ESRCH')throw error;
  }
}
