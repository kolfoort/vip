import {PDFDocument,StandardFonts,rgb} from './assets/vendor/pdf-lib.esm.min.js';

export const MCNDA_VERSION='VIP-MCNDA-2026-10-29';
export async function createNda(values,signature,stamp,{now=new Date(),reference='',email='',draft=false,loadTemplate}={}){
 const personal=values.ACCOUNT_TYPE==='individual',kind=personal?'individual':'company';
 const required=personal?['B_COMPANY','B_ADDRESS','B_COUNTRY','B_EMAIL','B_PHONE','PASSPORT_NUMBER']:['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_EMAIL','B_PHONE'];
 if(required.some(key=>!String(values[key]||'').trim()))throw Error('Complete all required profile and identity details before preparing the MCNDA.');
 const bytes=loadTemplate?await loadTemplate(kind):await (async()=>{const r=await fetch(new URL('./assets/mcnda/vip-mcnda-'+kind+'-20261029.pdf',import.meta.url));if(!r.ok)throw Error('The MCNDA template could not be loaded. Please contact VIP Capital.');return r.arrayBuffer()})();
 const pdf=await PDFDocument.load(bytes);
 if(pdf.getPageCount()!==8)throw Error('Unexpected MCNDA template. Please contact VIP Capital.');
 // The approved legal pages retain their original per-page, two-column flow.
 // Only the execution page is populated with this counterparty's private details.
 pdf.removePage(7);
 const page=pdf.addPage([595.28,841.89]),font=await pdf.embedFont(StandardFonts.Helvetica),bold=await pdf.embedFont(StandardFonts.HelveticaBold),serif=await pdf.embedFont(StandardFonts.TimesRoman);
 const navy=rgb(0,32/255,64/255),gold=rgb(189/255,154/255,69/255),grey=rgb(.43,.48,.53);
 function text(s,x,y,size=9,f=font,color=navy){page.drawText(String(s),{x,y,size,font:f,color})}
 function wrap(s,width,size=9,f=font){const lines=[];let line='';for(const word of String(s).trim().split(/\s+/)){if(f.widthOfTextAtSize((line?line+' ':'')+word,size)<=width){line+=(line?' ':'')+word;continue}if(line){lines.push(line);line=''}for(const ch of word){if(f.widthOfTextAtSize(line+ch,size)>width){lines.push(line);line=''}line+=ch}}if(line)lines.push(line);return lines}
 function para(s,x,y,width=509,size=9,f=font){const lines=wrap(s,width,size,f);for(const line of lines){text(line,x,y,size,f);y-=12}return y}
 text('VIP CAPITAL',43,820,8,bold);text('PRIVATE & CONFIDENTIAL',424,820,7,serif,grey);
 page.drawLine({start:{x:43,y:811},end:{x:552,y:811},thickness:.7,color:gold});
 text('20. EXECUTION',43,786,13,bold);
 para('IN WITNESS WHEREOF, the Parties execute this Agreement as of the date of the last authorised signature. Party B signs first; VIP Capital is bound only upon its authorised countersignature. A pre-inserted signature image, stamp or release notification does not itself constitute that countersignature.',43,766,509,9,serif);
 text('PARTY A · VIP CAPITAL',43,709,10,bold);
 text('Oude Apeldoornseweg 45-067, 7333 NR Apeldoorn, The Netherlands.',43,693);
 text('J.P. Kolfoort | Managing Director (MD)',43,679);
 page.drawRectangle({x:43,y:550,width:509,height:115,borderWidth:.5,borderColor:gold});
 text('Pending explicit final VIP Capital approval and countersignature',55,646,9);
 text('PARTY B · COUNTERPARTY DETAILS',43,524,10,bold);
 let y=505;
 const details=personal?[
  ['Full name',values.B_COMPANY],['Residential address',values.B_ADDRESS],['Country of residence',values.B_COUNTRY],['Email',values.B_EMAIL],['Telephone',values.B_PHONE],['Passport number',values.PASSPORT_NUMBER],['Capacity','Private individual · Broker / Introducer']
 ]:[
  ['Legal company name',values.B_COMPANY],['Registration number',values.B_REGISTRATION],['Registered address',values.B_ADDRESS],['Country of incorporation',values.B_COUNTRY],['Authorised representative',values.B_REPRESENTATIVE],['Position / title',values.B_TITLE],['Email',values.B_EMAIL],['Telephone',values.B_PHONE],...(values.B_WEBSITE?[['Website',values.B_WEBSITE]]:[])
 ];
 for(const [label,value]of details){text(label+':',43,y,8.5,bold);y=para(value,172,y,380,9)-4;}
 if(y<275)throw Error('Your profile details exceed the execution page. Please shorten the address or website.');
 const boxes=personal?[{x:43,w:509,label:'Personal signature'}]:[{x:43,w:240,label:'Authorised representative signature'},{x:310,w:242,label:'Company stamp (if supplied)'}];
 for(const box of boxes){text(box.label,box.x,258,9,bold);page.drawRectangle({x:box.x,y:150,width:box.w,height:96,borderWidth:.5,borderColor:gold})}
 for(const [data,box]of [[signature,boxes[0]],...(!personal?[[stamp,boxes[1]]]:[])])if(data&&!draft){const image=await pdf.embedPng(data),scale=Math.min((box.w-20)/image.width,76/image.height);page.drawImage(image,{x:box.x+(box.w-image.width*scale)/2,y:160+(76-image.height*scale)/2,width:image.width*scale,height:image.height*scale})}
 const day=new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/Amsterdam',day:'numeric',month:'long',year:'numeric'}).format(now);
 text('Party B signature date: '+(draft?'Not signed':day),43,134,8);
 text('Account: '+email,43,120,8);text('Reference: '+reference,43,106,8);
 text(draft?'UNSIGNED PREVIEW · Not submitted':'Client signed · Awaiting explicit VIP Capital countersignature',43,87,8,bold);
 if(personal)text('The passport copy is stored separately with restricted access; it is not attached to this agreement.',43,73,8);
 page.drawLine({start:{x:43,y:30},end:{x:552,y:30},thickness:.3,color:grey});text('VIP CAPITAL | MCNDA',43,19,7,serif,grey);text('8',548,19,7,serif,grey);
 if(draft)for(const p of pdf.getPages())p.drawText('UNSIGNED PREVIEW',{x:244,y:19,size:7,font:bold,color:navy});
 pdf.setTitle('VIP Capital MCNDA · '+values.B_COMPANY);pdf.setSubject(MCNDA_VERSION+'|'+kind);pdf.setCreationDate(now);
 return new Blob([await pdf.save()],{type:'application/pdf'});
}
