import {getLanguage} from './portal-language.js?v=20261029-mfa1';
import {securityCopy} from './account-security-copy.js?v=20261029-mfa1';
const watched=new WeakSet();
export function securityDestination(){
 const destination=location.pathname+location.search+location.hash;
 return '/account-security.html?return='+encodeURIComponent(destination);
}
export async function ensurePortalSecurity(db){
 const {data,error}=await db.auth.getSession();if(error)throw error;
 if(!data.session){location.replace('/client-login.html');return false;}
 const result=await db.rpc('my_portal_security');if(result.error)throw result.error;
 if(!result.data?.active)throw Error((securityCopy[getLanguage()]||securityCopy.en).inactive);
 if(!result.data.allowed){location.replace(securityDestination());return false;}
 const text=(securityCopy[getLanguage()]||securityCopy.en).securityLink;
 for(const nav of document.querySelectorAll('header nav'))if(!nav.querySelector('[data-security-link]')){const a=document.createElement('a');a.href=securityDestination();a.dataset.securityLink='';a.dataset.i18nSkip='';a.textContent=text;nav.append(a)}
 if(!watched.has(db)){
  watched.add(db);let checking=false;
  const recheck=()=>{if(checking||document.visibilityState==='hidden')return;checking=true;ensurePortalSecurity(db).catch(()=>location.replace(securityDestination())).finally(()=>{checking=false})};
  db.auth.onAuthStateChange(event=>{if(['TOKEN_REFRESHED','MFA_CHALLENGE_VERIFIED'].includes(event))setTimeout(recheck,0)});
  document.addEventListener('visibilitychange',recheck);window.addEventListener('pageshow',event=>{if(event.persisted)recheck()});
 }
 return true;
}
