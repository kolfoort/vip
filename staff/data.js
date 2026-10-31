import {config} from '../portal-config.js';
const checked=r=>{if(r.error)throw Error(r.error.message);return r.data};
let db;
export async function client(){if(!db){const {createClient}=await import('https://esm.sh/@supabase/supabase-js@2.102.0');db=createClient(config.url,config.publishableKey,{auth:{storage:sessionStorage,persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}})}return db}
export const Staff={
 async init(){const c=await client();const {session}=checked(await c.auth.getSession());if(!session){location.replace('login.html');return false}c.auth.onAuthStateChange(e=>{if(e==='SIGNED_OUT'){document.getElementById('app').replaceChildren();location.replace('login.html')}});return true},
 async state(){const c=await client();try{return checked(await c.rpc('staff_state'))}catch(e){if(e.message.includes('STAFF_MFA_')){location.replace('login.html?mfa=1');return new Promise(()=>{})}throw e}},
 async action(action,payload={}){return checked(await (await client()).rpc('staff_action',{p_action:action,p_payload:payload,p_request:crypto.randomUUID()}))},
 async signOut(){checked(await (await client()).auth.signOut());location.replace('login.html')},
 async export(){const s=await this.state();await this.action('export');const q=x=>'"'+String(x??'').replace(/"/g,'""')+'"';const rows=[['Person','Kunde','Beginn UTC','Ende UTC','Arbeitsminuten','Pausenminuten','Status','Bruttostundenlohn EUR bei Schichtbeginn']];for(const x of s.shifts){if(!x.end)continue;const e=s.employees.find(e=>e.id===x.employee);rows.push(["'"+(e?.name||''),'Koninghoek',x.effective_start,x.effective_end,x.net_minutes,x.break_minutes,x.status,x.rate_snapshot?((x.rate_snapshot.cents||0)/100).toFixed(2):''])}const u=URL.createObjectURL(new Blob(['\ufeff'+rows.map(r=>r.map(q).join(';')).join('\r\n')],{type:'text/csv;charset=utf-8'}));const a=document.createElement('a');a.href=u;a.download='Koninghoek-Arbeitszeiten.csv';a.click();setTimeout(()=>URL.revokeObjectURL(u),5000)}
};
