import type{RunMapping,RunRecord,StigDataset}from'./types';
const KEY='policy-studio-runs-v1';const MAX_RUNS=60;
export const datasetKey=(dataset:StigDataset)=>`${dataset.benchmark.title}|${dataset.benchmark.version}|${dataset.benchmark.release}`;
export function loadRuns():RunRecord[]{try{const value=JSON.parse(localStorage.getItem(KEY)??'[]');return Array.isArray(value)?value:[]}catch{return[]}}
export function saveRuns(runs:RunRecord[]){let next=runs.slice(-MAX_RUNS);while(next.length){try{localStorage.setItem(KEY,JSON.stringify(next));return next}catch{next=next.slice(1)}}try{localStorage.removeItem(KEY)}catch{}return next}
export const runsFor=(runs:RunRecord[],key:string)=>runs.filter(run=>run.datasetKey===key).sort((a,b)=>b.createdAt.localeCompare(a.createdAt));
export function mappingsFromRuns(runs:RunRecord[]){const result:Record<string,RunMapping>={};for(const run of[...runs].sort((a,b)=>a.createdAt.localeCompare(b.createdAt)))for(const mapping of run.results)result[mapping.id]=mapping;return result}
import{defaultProfile,sanitizeProfile,type AnalysisProfile}from'./analysisProfile';
const PROFILE_KEY='policy-studio-profiles-v1';
export function loadProfiles():Record<string,AnalysisProfile>{try{const value=JSON.parse(localStorage.getItem(PROFILE_KEY)??'{}');if(!value||typeof value!=='object')return{};return Object.fromEntries(Object.entries(value as Record<string,Record<string,unknown>>).map(([key,profile])=>[key,{azure:sanitizeProfile(profile?.azure),openai:sanitizeProfile(profile?.openai),google:sanitizeProfile(profile?.google)}]))}catch{return{}}}
export function saveProfiles(profiles:Record<string,AnalysisProfile>){try{localStorage.setItem(PROFILE_KEY,JSON.stringify(profiles))}catch{}return profiles}
export const profileFor=(profiles:Record<string,AnalysisProfile>,key:string)=>profiles[key]??defaultProfile();
