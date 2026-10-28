import {catalog,fragments} from './portal-language-catalog.js?v=20261028-vip-alignment';
export const portalLanguages=[['en','English'],['nl','Nederlands'],['de','Deutsch'],['es','Español'],['ar','العربية']];
const supported=new Set(portalLanguages.map(x=>x[0])),storageKey='vip-portal-language';
let current=null;try{const p=new URL(location.href).searchParams.get('lang')||localStorage.getItem(storageKey);if(supported.has(p))current=p}catch{}
export const getLanguage=()=>current||'en';
export function translate(text,language=getLanguage()){
 if(language==='en')return text;
 if(catalog[text]?.[language])return catalog[text][language];
 const match=text.match(/^(\s*)(.*?)(\s*)$/s),core=match?.[2]||text;
 if(catalog[core]?.[language])return match[1]+catalog[core][language]+match[3];
 if(core.endsWith(' (optional)')&&catalog[core.slice(0,-11)]?.[language])return catalog[core.slice(0,-11)][language]+catalog[' (optional)'][language];
 return text;
}
const originals=new WeakMap(),attributeOriginals=new WeakMap();
const excluded='script,style,noscript,textarea,input,iframe,canvas,[data-contract-content],[data-i18n-skip],#nda-section,#client-file-title,#file-company-name,#account,#company-profile-summary,.file-row strong,.card h2,.pdf-preview-heading h2';
function textTranslation(node){
 if(!node.parentElement||node.parentElement.closest(excluded))return;
 const previous=originals.get(node),source=previous&&node.data===previous.rendered?previous.source:node.data;
 let rendered=translate(source);
 if(rendered===source&&node.parentElement.closest('.meta,.tag,#file-company-status,#company-profile-status')){
  for(const fragment of [...fragments].sort((a,b)=>b.length-a.length)){
   const target=translate(fragment);if(target!==fragment)rendered=rendered.split(fragment).join(target);
  }
 }
 originals.set(node,{source,rendered});if(node.data!==rendered)node.data=rendered;
}
let pending=false;
export function applyPortalLanguage(){
 document.documentElement.lang=getLanguage();document.documentElement.dir=getLanguage()==='ar'?'rtl':'ltr';
 if(!document.body)return;
 // Document and agreement workspaces remain canonical English, including controls inside them.
 if(/\/(?:commission|spa|jv|fco)-agreements\.html$/.test(location.pathname)){const main=document.querySelector('main');if(main){main.dataset.contractContent='';main.lang='en';main.dir='ltr'}}
 for(const link of document.querySelectorAll('a[href*="privacy-policy"]')){try{const url=new URL(link.getAttribute('href'),location.href);if(url.origin===location.origin&&/\/privacy-policy(?:-(?:nl|de|es|ar))?\.html$/.test(url.pathname)){url.pathname='/privacy-policy'+(getLanguage()==='en'?'':'-'+getLanguage())+'.html';if(link.href!==url.href)link.href=url.href;}}catch{}}
 document.querySelectorAll('option').forEach(o=>{if(!o.hasAttribute('value'))o.value=originals.get(o.firstChild)?.source||o.textContent});
 const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let n;while(n=walker.nextNode())textTranslation(n);
 for(const el of document.querySelectorAll('[placeholder],[aria-label],[title],[alt]')){
  if(el.closest(excluded))continue;
  let records=attributeOriginals.get(el);if(!records){records={};attributeOriginals.set(el,records)}
  for(const key of ['placeholder','aria-label','title','alt'])if(el.hasAttribute(key)){const previous=records[key],value=el.getAttribute(key),source=previous&&value===previous.rendered?previous.source:value,rendered=translate(source);records[key]={source,rendered};if(value!==rendered)el.setAttribute(key,rendered)}
 }
}
export function setLanguage(language){if(!supported.has(language))throw Error('Select a supported language');current=language;try{localStorage.setItem(storageKey,language)}catch{}applyPortalLanguage();window.dispatchEvent(new CustomEvent('vip-language-change',{detail:language}))}
export function languageSelect(value='',id='portal-language'){const select=document.createElement('select');select.id=id;select.required=true;select.name='language';const empty=new Option(translate('Select a language'),'');empty.disabled=true;select.add(empty);for(const [code,label]of portalLanguages)select.add(new Option(label,code));select.value=supported.has(value)?value:'';return select}
export async function initializeAccountLanguage(db,{required=true}={}){
 const result=await db.rpc('my_portal_language');if(result.error)throw result.error;
 if(supported.has(result.data)){setLanguage(result.data);return result.data}
 if(!required)return null;
 return new Promise(resolve=>{
  const dialog=document.createElement('dialog');dialog.className='language-dialog';dialog.innerHTML='<h2>Portal &amp; email language</h2><p>Select your portal and email language. No language has been selected for you.</p><form><label for="initial-language">Portal &amp; email language</label><div class="language-select-slot"></div><p class="language-policy">All documents, MCNDAs and Commission Agreements remain in English. English is the working language of VIP Capital.</p><button type="submit">Save language</button><p role="status"></p></form>';
  const select=languageSelect('','initial-language');dialog.querySelector('.language-select-slot').append(select);document.body.append(dialog);dialog.addEventListener('cancel',e=>e.preventDefault());select.onchange=()=>setLanguage(select.value);
  dialog.querySelector('form').onsubmit=async e=>{e.preventDefault();if(!select.reportValidity())return;const button=dialog.querySelector('button');button.disabled=true;const saved=await db.rpc('save_my_portal_language',{p_language:select.value});if(saved.error){dialog.querySelector('[role=status]').textContent='Unable to save language. Please try again.';button.disabled=false;return}setLanguage(select.value);dialog.close();dialog.remove();resolve(select.value)};
  applyPortalLanguage();dialog.showModal();
 });
}
export function mountLanguagePreference({db,container,message=()=>{}}){
 const section=document.createElement('section');section.className='panel language-preference';section.innerHTML='<h3>Portal &amp; email language</h3><p>Language changes apply to the portal and future emails. Existing documents and signatures remain unchanged.</p><form><label for="profile-language-choice">Portal &amp; email language</label><div class="language-select-slot"></div><p class="language-policy">All documents, MCNDAs and Commission Agreements remain in English. English is the working language of VIP Capital.</p><button type="submit" class="secondary">Save language</button><p role="status"></p></form>';
 const select=languageSelect(current,'profile-language-choice');section.querySelector('.language-select-slot').append(select);container.append(section);
 section.querySelector('form').onsubmit=async e=>{e.preventDefault();if(!select.reportValidity())return;const b=section.querySelector('button');b.disabled=true;try{const result=await db.rpc('save_my_portal_language',{p_language:select.value});if(result.error)throw result.error;setLanguage(select.value);section.querySelector('[role=status]').textContent='Language saved.';message('Language saved.')}catch{section.querySelector('[role=status]').textContent='Unable to save language. Please try again.'}finally{b.disabled=false}};
 window.addEventListener('vip-language-change',()=>select.value=getLanguage());applyPortalLanguage();return section;
}
function boot(){applyPortalLanguage();new MutationObserver(()=>{if(!pending){pending=true;requestAnimationFrame(()=>{pending=false;applyPortalLanguage()})}}).observe(document.body,{childList:true,subtree:true,characterData:true})}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
