import {catalog,fragments} from './portal-language-catalog.js?v=20261028-vip-alignment';
export const portalLanguages=[['en','English'],['nl','Nederlands'],['de','Deutsch'],['es','Español'],['ar','العربية']];
const supported=new Set(portalLanguages.map(x=>x[0])),storageKey='vip-portal-language';
const authPage=/\/(?:client-login|request-access|forgot-password|set-password|account-security)\.html$/.test(location.pathname),websiteLanguageKey=storageKey+'-website';
let current=null;try{const explicit=new URL(location.href).searchParams.get('lang');let referring=null;if(document.referrer){const ref=new URL(document.referrer);if(ref.origin===location.origin){const path=ref.pathname.match(/^\/(nl|de|es|ar)(?:\/|-)/);referring=ref.searchParams.get('lang')||path?.[1]||(/\/(?:client-login|request-access|forgot-password|set-password|account-security)\.html$/.test(ref.pathname)?null:'en')}}const p=explicit||(authPage?(referring||localStorage.getItem(websiteLanguageKey)):null)||localStorage.getItem(storageKey);if(supported.has(p))current=p}catch{}
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
const excluded='script,style,noscript,textarea,input,iframe,canvas,[data-contract-content],[data-i18n-skip],[data-auth-language-picker],#nda-section,#client-file-title,#file-company-name,#account,#company-profile-summary,.file-row strong,.card h2,.pdf-preview-heading h2';
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
 if(authPage){for(const link of document.querySelectorAll('a[href]:not([data-lang])')){try{const url=new URL(link.getAttribute('href'),location.href);if(url.origin!==location.origin)continue;if(/\/(?:client-login|request-access|forgot-password|set-password|account-security)\.html$/.test(url.pathname)){url.searchParams.set('lang',getLanguage());if(link.href!==url.href)link.href=url.href}else if(url.pathname==='/index.html'||/^\/(?:nl|de|es|ar)?\/?$/.test(url.pathname)){url.pathname=getLanguage()==='en'?'/':'/'+getLanguage()+'/';if(link.href!==url.href)link.href=url.href}}catch{}}updateAuthLanguagePicker()}
 document.querySelectorAll('option').forEach(o=>{if(!o.hasAttribute('value'))o.value=originals.get(o.firstChild)?.source||o.textContent});
 const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let n;while(n=walker.nextNode())textTranslation(n);
 for(const el of document.querySelectorAll('[placeholder],[aria-label],[title],[alt]')){
  if(el.closest(excluded))continue;
  let records=attributeOriginals.get(el);if(!records){records={};attributeOriginals.set(el,records)}
  for(const key of ['placeholder','aria-label','title','alt'])if(el.hasAttribute(key)){const previous=records[key],value=el.getAttribute(key),source=previous&&value===previous.rendered?previous.source:value,rendered=translate(source);records[key]={source,rendered};if(value!==rendered)el.setAttribute(key,rendered)}
 }
}
export function setLanguage(language){if(!supported.has(language))throw Error('Select a supported language');current=language;if(authPage){const url=new URL(location.href);url.searchParams.set('lang',language);history.replaceState(null,'',url)}try{localStorage.setItem(storageKey,language);if(authPage)localStorage.setItem(websiteLanguageKey,language)}catch{}applyPortalLanguage();window.dispatchEvent(new CustomEvent('vip-language-change',{detail:language}))}
export function languageSelect(value='',id='portal-language'){const select=document.createElement('select');select.id=id;select.required=true;select.name='language';const empty=new Option('Select a language','');empty.disabled=true;select.add(empty);for(const [code,label]of portalLanguages){const option=new Option(label,code);option.dataset.i18nSkip='';select.add(option);}select.value=supported.has(value)?value:'';return select}
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

const authFlags={"en": "<svg preserveAspectRatio=\"none\" viewBox=\"0 0 60 30\" xmlns=\"http://www.w3.org/2000/svg\"><path fill=\"#012169\" d=\"M0 0h60v30H0z\"/><path stroke=\"#fff\" stroke-width=\"6\" d=\"m0 0 60 30m0-30L0 30\"/><path stroke=\"#c8102e\" stroke-width=\"2\" d=\"m0 0 60 30m0-30L0 30\"/><path stroke=\"#fff\" stroke-width=\"10\" d=\"M30 0v30M0 15h60\"/><path stroke=\"#c8102e\" stroke-width=\"6\" d=\"M30 0v30M0 15h60\"/></svg>", "nl": "<svg preserveAspectRatio=\"none\" viewBox=\"0 0 60 40\" xmlns=\"http://www.w3.org/2000/svg\"><path fill=\"#ae1c28\" d=\"M0 0h60v13.333H0z\"/><path fill=\"#fff\" d=\"M0 13.333h60v13.334H0z\"/><path fill=\"#21468b\" d=\"M0 26.667h60V40H0z\"/></svg>", "de": "<svg preserveAspectRatio=\"none\" viewBox=\"0 0 60 40\" xmlns=\"http://www.w3.org/2000/svg\"><path fill=\"#000\" d=\"M0 0h60v14H0z\"/><path fill=\"#d00\" d=\"M0 13.33h60v13.34H0z\"/><path fill=\"#ffce00\" d=\"M0 26.66h60V40H0z\"/></svg>", "es": "<svg preserveAspectRatio=\"none\" viewBox=\"0 0 60 40\" xmlns=\"http://www.w3.org/2000/svg\"><path fill=\"#aa151b\" d=\"M0 0h60v40H0z\"/><path fill=\"#f1bf00\" d=\"M0 10h60v20H0z\"/><g transform=\"translate(15 14)\"><path fill=\"#eee\" stroke=\"#aa151b\" stroke-width=\".6\" d=\"M0 1h8v8c0 5-8 5-8 0z\"/><path fill=\"#aa151b\" d=\"M0 1h4v5H0zM4 6h4v4H4z\"/><path fill=\"#f1bf00\" d=\"M1 2h2v3H1zM5 7h2v2H5z\"/><path fill=\"#aa151b\" d=\"M-1 0h10v-2H-1z\"/></g></svg>", "ar": "<svg preserveAspectRatio=\"none\" viewBox=\"0 0 60 40\" xmlns=\"http://www.w3.org/2000/svg\"><path fill=\"#00732f\" d=\"M0 0h60v13.333H0z\"/><path fill=\"#fff\" d=\"M0 13.333h60v13.334H0z\"/><path fill=\"#000\" d=\"M0 26.667h60V40H0z\"/><path fill=\"#f00\" d=\"M0 0h15v40H0z\"/></svg>"};
function updateAuthLanguagePicker(){const picker=document.querySelector('[data-auth-language-picker]');if(!picker)return;const lang=getLanguage();if(picker.dataset.currentLanguage===lang)return;picker.dataset.currentLanguage=lang;const label={en:'Choose language',nl:'Kies taal',de:'Sprache wählen',es:'Elegir idioma',ar:'اختر اللغة'}[lang];picker.querySelector('button').setAttribute('aria-label',label);picker.querySelector('[data-current-flag]').innerHTML=authFlags[lang];picker.querySelector('[data-current-code]').textContent=lang.toUpperCase();for(const link of picker.querySelectorAll('a[data-lang]')){if(link.dataset.lang===lang)link.setAttribute('aria-current','page');else link.removeAttribute('aria-current')}}
function mountAuthLanguagePicker(){if(!authPage||document.querySelector('[data-auth-language-picker]'))return;const nav=document.querySelector('header .nav');if(!nav)return;const picker=document.createElement('div');picker.className='auth-language-picker';picker.dataset.authLanguagePicker='';picker.dir='ltr';picker.innerHTML='<button type="button" aria-expanded="false" aria-controls="auth-language-options"><span class="language-flag" data-current-flag></span><span data-current-code></span></button><div id="auth-language-options" class="auth-language-options" hidden>'+portalLanguages.map(([code,label])=>'<a href="?lang='+code+'" lang="'+code+'" data-lang="'+code+'"><span class="language-flag">'+authFlags[code]+'</span><span>'+label+'</span></a>').join('')+'</div>';nav.append(picker);const button=picker.querySelector('button'),options=picker.querySelector('.auth-language-options'),links=[...options.querySelectorAll('a')];const open=value=>{button.setAttribute('aria-expanded',String(value));options.hidden=!value};button.onclick=()=>open(options.hidden);button.onkeydown=e=>{if(e.key==='ArrowDown'){e.preventDefault();open(true);links[0].focus()}};for(const link of links){const url=new URL(location.href);url.searchParams.set('lang',link.dataset.lang);link.href=url.href;link.onclick=e=>{e.preventDefault();setLanguage(link.dataset.lang);const url=new URL(location.href);url.searchParams.set('lang',link.dataset.lang);history.replaceState(null,'',url);open(false);button.focus()}}picker.onkeydown=e=>{if(e.key==='Escape'){e.preventDefault();open(false);button.focus()}if(['ArrowDown','ArrowUp'].includes(e.key)&&links.includes(document.activeElement)){e.preventDefault();const i=links.indexOf(document.activeElement);links[(i+(e.key==='ArrowDown'?1:-1)+links.length)%links.length].focus()}};document.addEventListener('click',e=>{if(!picker.contains(e.target))open(false)});picker.addEventListener('focusout',e=>{if(!picker.contains(e.relatedTarget))open(false)});updateAuthLanguagePicker()}

function boot(){mountAuthLanguagePicker();applyPortalLanguage();new MutationObserver(()=>{if(!pending){pending=true;requestAnimationFrame(()=>{pending=false;applyPortalLanguage()})}}).observe(document.body,{childList:true,subtree:true,characterData:true})}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
