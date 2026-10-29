import {config} from './portal-config.js';
import {getLanguage,setLanguage} from './portal-language.js?v=20261029-mfa1';
import {securityCopy} from './account-security-copy.js?v=20261029-mfa1';
const {createClient}=await import('https://esm.sh/@supabase/supabase-js@2.102.0');
const db=createClient(config.url,config.publishableKey,{auth:{storage:sessionStorage,persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
const root=document.getElementById('security-root'),make=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e};
let t=securityCopy[getLanguage()]||securityCopy.en,status,busy=false,setup=null;
const check=r=>{if(r.error)throw r.error;return r.data};
function destination(){try{const url=new URL(new URL(location.href).searchParams.get('return')||'documents.html',location.origin);if(url.origin!==location.origin||!/^\/(?:documents|document-admin|client-files|admin-home|commission-agreements|spa-agreements|jv-agreements|fco-agreements|quote-requests|company-profile|set-password)\.html$/.test(url.pathname))return '/documents.html';return url.pathname+url.search+url.hash}catch{return '/documents.html'}}
function button(text,fn,secondary=false){const b=make('button',text);b.type='button';if(secondary)b.className='secondary';b.onclick=()=>run(fn);return b}
async function run(fn){if(busy)return;busy=true;const controls=[...root.querySelectorAll('button,input,select')];controls.forEach(e=>e.disabled=true);status.textContent=t.working;try{await fn()}catch{status.textContent=t.error}finally{busy=false;controls.filter(e=>e.isConnected).forEach(e=>e.disabled=false)}}
function actions(...buttons){const row=make('div');row.className='actions';row.append(...buttons);return row}
function appCodeForm(onVerify){const form=make('form'),label=make('label',t.code),input=make('input'),submit=make('button',t.verify);input.id='mfa-code';label.htmlFor=input.id;input.autocomplete='one-time-code';input.inputMode='numeric';input.type='text';input.pattern='[0-9]{6}';input.maxLength=6;input.required=true;input.dir='ltr';input.addEventListener('input',()=>{input.value=input.value.replace(/[٠-٩]/g,c=>String(c.charCodeAt(0)-1632)).replace(/[۰-۹]/g,c=>String(c.charCodeAt(0)-1776))});submit.type='submit';form.append(label,input,actions(submit));form.onsubmit=e=>{e.preventDefault();if(!form.reportValidity())return;run(async()=>{const code=input.value.trim();input.value='';await onVerify(code)})};return form}
async function verify(factorId,code){const challenge=await db.auth.mfa.challenge({factorId});if(challenge.error){status.textContent=t.error;return false}const verified=await db.auth.mfa.verify({factorId,challengeId:challenge.data.id,code});if(verified.error){status.textContent=t.invalid;return false}return true}
function recovery(){const details=make('details'),summary=make('summary',t.recovery);details.append(summary,make('p',t.recoveryText));return details}
async function enroll(){
 // This function runs only after the human account holder clicks Set up/Add.
 const state=check(await db.rpc('my_portal_security'));if(!state.active||!state.admin||state.enrolled&&!state.allowed)throw Error('MFA required');
 const nameInput=root.querySelector('#device-name');const friendlyName=nameInput?.value.trim().slice(0,60)||'Authenticator '+new Date().toISOString().slice(0,19);
 setup=check(await db.auth.mfa.enroll({factorType:'totp',friendlyName,issuer:config.url.includes('inndqvdryjiupfzkzsdl')?'Nexora International':'VIP Capital'}));
 showSetup();
}
function showSetup(){
 t=securityCopy[getLanguage()]||securityCopy.en;root.lang=getLanguage();root.dir=getLanguage()==='ar'?'rtl':'ltr';root.querySelector('h1').textContent=t.title;root.querySelector('h1').nextElementSibling.textContent=t.intro;
 const box=make('section');box.append(make('h2',t.setup),make('p',t.scan));
 const image=make('img');image.className='mfa-qr';image.alt='QR';image.src=setup.totp.qr_code.startsWith('data:')?setup.totp.qr_code:'data:image/svg+xml;charset=utf-8,'+encodeURIComponent(setup.totp.qr_code);box.append(image);
 const manual=make('details'),summary=make('summary',t.manual),key=make('input');key.readOnly=true;key.autocomplete='off';key.dir='ltr';key.value=setup.totp.secret;key.setAttribute('aria-label',t.manual);manual.append(summary,key);box.append(manual);
 box.append(appCodeForm(async code=>{if(await verify(setup.id,code)){image.removeAttribute('src');key.value='';setup=null;await render();status.textContent=t.enabled}}));
 box.append(button(t.cancel,async()=>{if(!confirm(t.cancelConfirm))return;check(await db.auth.mfa.unenroll({factorId:setup.id}));image.removeAttribute('src');key.value='';setup=null;await render()},true));
 root.querySelector('#security-content').replaceChildren(box);status.textContent='';
}
async function render(){
 root.replaceChildren();root.lang=getLanguage();root.dir=getLanguage()==='ar'?'rtl':'ltr';t=securityCopy[getLanguage()]||securityCopy.en;
 root.append(make('h1',t.title),make('p',t.intro));status=make('p');status.setAttribute('role','status');root.append(status);
 const {data,error}=await db.auth.getSession();if(error)throw error;
 if(!data.session){const a=make('a',t.login);a.href='client-login.html';root.append(a,recovery());return;}
 const state=check(await db.rpc('my_portal_security'));if(!state.active){status.textContent=t.inactive;root.append(actions(button(t.logout,async()=>{check(await db.auth.signOut());location.replace('client-login.html')})));return;}
 const all=check(await db.auth.mfa.listFactors()),verified=(all.totp||[]).filter(f=>f.status==='verified');
 const content=make('div');content.id='security-content';root.append(content);
 if(!state.allowed&&verified.length){
  content.append(make('p',t.verifyIntro));const label=make('label',t.choose),select=make('select');select.id='mfa-factor';label.htmlFor=select.id;for(const f of verified){const option=make('option',f.friendly_name||t.choose);option.value=f.id;select.append(option)}content.append(label,select,appCodeForm(async code=>{if(await verify(select.value,code)){await render();status.textContent=t.enabled}}));
 }else if(state.admin&&!verified.length){content.append(make('p',t.required),button(t.setup,enroll));}
 else if(state.allowed){
  content.append(actions(button(t.continue,async()=>{location.replace(destination())})));
  if(state.admin){content.append(make('h2',t.manage),make('p',t.backup));
   for(const f of verified){const row=make('div');row.className='factor';row.append(make('strong',f.friendly_name||t.choose));if(verified.length>1)row.append(button(t.remove,async()=>{if(!confirm(t.removeConfirm))return;const fresh=check(await db.auth.mfa.listFactors());if((fresh.totp||[]).filter(x=>x.status==='verified').length<2)throw Error('Keep one verified factor');check(await db.auth.mfa.unenroll({factorId:f.id}));check(await db.auth.refreshSession());await render()},true));content.append(row)}
   const label=make('label',t.name),name=make('input');name.id='device-name';name.maxLength=60;name.autocomplete='off';label.htmlFor=name.id;content.append(label,name,button(t.add,enroll));
  }else content.append(make('p',t.notRequired));
 }
 // Unfinished enrollments can be removed by the account holder; never remove verified factors automatically.
 for(const f of all.all||[])if(f.status==='unverified'&&f.factor_type==='totp'){const row=make('div');row.className='factor';row.append(make('span',f.friendly_name||t.setup),button(t.cancel,async()=>{if(!confirm(t.cancelConfirm))return;check(await db.auth.mfa.unenroll({factorId:f.id}));await render()},true));content.append(row)}
 root.append(recovery(),actions(button(t.logout,async()=>{check(await db.auth.signOut());location.replace('client-login.html')},true)));
}
const session=await db.auth.getSession();const preferred=session.data.session?.user?.user_metadata?.language;if(['en','nl','de','es','ar'].includes(preferred))setLanguage(preferred);
render().catch(()=>{root.replaceChildren(make('h1',t.title),make('p',t.error));const a=make('a',t.login);a.href='client-login.html';root.append(a)});
window.addEventListener('pagehide',()=>{for(const img of root.querySelectorAll('.mfa-qr'))img.removeAttribute('src');root.replaceChildren();setup=null});

window.addEventListener('pageshow',event=>{if(event.persisted)render().catch(()=>location.replace('client-login.html'))});

window.addEventListener('vip-language-change',()=>{if(busy)return;if(setup)showSetup();else render().catch(()=>{status.textContent=t.error})});
