import {PDFDocument,StandardFonts,rgb} from '../assets/vendor/pdf-lib.esm.min.js';
const dictionary={
nl:{title:'FACTUUR',credit:'CREDITNOTA',draft:'CONCEPT',page:'Pagina',bill_to:'FACTUUR AAN',registration:'KVK',vat_id:'BTW Nr.',invoice_date:'Factuurdatum',due_date:'Vervaldatum',currency:'Valuta',reference:'Referentie',services:'Datum / werkzaamheden',hours:'Uren',rate:'Tarief',amount:'Bedrag',next_day:'+1 dag',break:'Pauze',subtotal:'Subtotaal',vat:'Btw',total:'Totaal',reverse:'Btw verlegd / VAT reverse charged.',reverse_label:'Btw verlegd',exempt:'Vrijgesteld van btw',vat_eur:'Btw-bedrag in EUR',payment:'Betaalinstructies',thanks:'Dank voor uw vertrouwen.',credit_ref:'Volledige creditnota voor factuur'},
en:{title:'INVOICE',credit:'CREDIT NOTE',draft:'DRAFT',page:'Page',bill_to:'BILL TO',registration:'KVK',vat_id:'VAT Nr.',invoice_date:'Invoice date',due_date:'Due date',currency:'Currency',reference:'Reference',services:'Date / services',hours:'Hours',rate:'Rate',amount:'Amount',next_day:'+1 day',break:'Break',subtotal:'Subtotal',vat:'VAT',total:'Total',reverse:'Reverse charge - VAT payable by the recipient.',reverse_label:'VAT (reverse charge)',exempt:'VAT exempt',vat_eur:'VAT amount in EUR',payment:'Payment instructions',thanks:'Thank you for your business.',credit_ref:'Full credit note for invoice'},
de:{title:'RECHNUNG',credit:'STORNORECHNUNG',draft:'ENTWURF',page:'Seite',bill_to:'RECHNUNGSEMPFÄNGER',registration:'Handelsregister NL',vat_id:'USt-IdNr.',invoice_date:'Rechnungsdatum',due_date:'Fälligkeitsdatum',currency:'Währung',reference:'Referenz',services:'Leistungsdatum / Beschreibung',hours:'Stunden',rate:'Stundensatz',amount:'Betrag',next_day:'+1 Tag',break:'Pause',subtotal:'Zwischensumme',vat:'USt.',total:'Gesamt',reverse:'Steuerschuldnerschaft des Leistungsempfängers (Reverse Charge).',reverse_label:'USt. (Reverse Charge)',exempt:'USt. befreit',vat_eur:'Umsatzsteuerbetrag in EUR',payment:'Zahlungsinformationen',thanks:'Vielen Dank für Ihr Vertrauen.',credit_ref:'Vollständige Stornorechnung zu Rechnung'}
};
const norm=s=>String(s??'').replace(/[\u2011\u2013\u2014]/g,'-').replace(/[\u2018\u2019]/g,"'").replace(/[\u201c\u201d]/g,'"').replace(/[^\x20-\x7e\xa0-\xff\n]/g,'?');
function addressWithCountry(address,country){
 const parts=String(address??'').trimEnd().split(/\r?\n/);
 const countryName=String(country??'').trim();
 if(countryName && parts.at(-1)?.trim().toLowerCase()!==countryName.toLowerCase())parts.push(countryName);
 return parts.filter(part=>part.trim()).join('\n');
}
export async function createInvoicePDF(inv){
 const s=inv.snapshot,issuer=s.issuer,lang=s.language||'nl',t=dictionary[lang],locale={nl:'nl-NL',en:'en-GB',de:'de-DE'}[lang],pdf=await PDFDocument.create(),font=await pdf.embedFont(StandardFonts.Helvetica),bold=await pdf.embedFont(StandardFonts.HelveticaBold),logo=await pdf.embedPng(await(await fetch(new URL('./lce-logo.png',import.meta.url))).arrayBuffer());let page,y,pageNo=0;
 const navy=rgb(.0,.125,.25),gold=rgb(.68,.55,.31),grey=rgb(.45,.49,.52),white=rgb(1,1,1),amount=n=>new Intl.NumberFormat(locale,{minimumFractionDigits:2,maximumFractionDigits:2}).format(n/100),hours=n=>new Intl.NumberFormat(locale,{minimumFractionDigits:2,maximumFractionDigits:2}).format(n/60),date=v=>new Date(v+'T12:00:00Z').toLocaleDateString(locale,{day:'2-digit',month:'2-digit',year:'numeric',timeZone:'UTC'}),isCredit=inv.doc_type==='credit';
 function draw(x,yy,txt,size=9,f=font,color=navy){page.drawText(norm(txt),{x,y:yy,size,font:f,color})}
 function lines(txt,width=507,size=9,f=font){let out=[];for(const para of norm(txt).split('\n')){let line='';for(const word of para.split(/\s+/)){if(f.widthOfTextAtSize(line+(line?' ':'')+word,size)>width&&line){out.push(line);line=''}for(const char of word){if(f.widthOfTextAtSize(line+char,size)>width){out.push(line);line=''}line+=char}line+=' '}out.push(line.trim())}return out}
 function right(yy,txt,size=9,f=font){const v=norm(txt);draw(552-f.widthOfTextAtSize(v,size),yy,v,size,f)}
 function newPage(){page=pdf.addPage([595,842]);pageNo++;page.drawImage(logo,{x:43,y:687,width:142,height:142});let yy=801;right(yy,issuer.name.toUpperCase(),9,bold);yy-=15;
 for(const l of lines(addressWithCountry(issuer.address,issuer.country),230,9)){right(yy,l);yy-=12}yy-=8;
 for(const item of [issuer.website,issuer.email,issuer.phone])if(item){for(const l of lines(item,230,9)){right(yy,l);yy-=12}}yy-=8;right(yy,t.registration+': '+issuer.kvk);yy-=12;right(yy,t.vat_id+': '+issuer.vat);
 const numberLabel={nl:'Factuurnummer',en:'Invoice number',de:'Rechnungsnummer'}[lang];
 draw(43,652,isCredit?t.credit:t.title,25);draw(43,628,numberLabel+': '+inv.number+(inv.status==='draft'?' | '+t.draft:''),9,bold,gold);page.drawLine({start:{x:43,y:611},end:{x:552,y:611},thickness:.75,color:gold});draw(43,39,inv.number+(inv.status==='draft'?' | '+t.draft:''),7,font,grey);right(39,t.page+' '+pageNo,7);y=588;}
 newPage();draw(43,y,t.bill_to,9,bold,gold);y-=18;let ly=y;
 for(const item of [s.client.name,addressWithCountry(s.client.address,s.client.country),s.client.vat?t.vat_id+': '+s.client.vat:''])if(item)for(const l of lines(item,250)){draw(43,ly,l);ly-=13}
 function metadataColumn(x,width,fields){
  let yy=y;
  for(const [label,value] of fields){
   draw(x,yy,label,8,bold);
   yy-=13;
   for(const line of lines(value,width,8)){draw(x,yy,line,8);yy-=12}
   yy-=3;
  }
  return yy;
 }
 const datesBottom=metadataColumn(325,96,[[t.invoice_date,date(s.issue_date)],[t.due_date,date(s.due_date)]]);
 const referenceBottom=metadataColumn(439,113,[[t.currency,s.currency],[t.reference,s.reference||'-']]);
 y=Math.min(ly,datesBottom,referenceBottom)-20;
 function columnRight(x,yy,text,f=font,color=navy){
  draw(x-f.widthOfTextAtSize(norm(text),8),yy,text,8,f,color);
 }
 function tableHead(){
  if(y<125)newPage();
  page.drawRectangle({x:43,y:y-8,width:509,height:22,color:navy});
  draw(49,y,t.services,8,bold,white);
  for(const [x,label] of [[369,t.hours],[452,t.rate],[541,t.amount]])columnRight(x,y,label,bold,white);
  y-=23;
 }
 const rowBlue=rgb(.91,.95,.98), rowBottom=76, rowPadding=19, lineHeight=10;
 tableHead();
 for(const [index,r] of s.lines.entries()){
  const fields=[];
  if(r.start_time)fields.push([r.start_time+' - '+r.end_time+(r.next_day?' ('+t.next_day+')':'')+(Number(r.break_minutes)?' | '+t.break+' '+r.break_minutes+' min':''),font]);
  const project=r.project_name?.trim(),description=r.description?.trim();
  if(lang==='de' && /^Bediening Koning(?:s)?hoek$/i.test(project||'') && /^Bediening$/i.test(description||'')){
   fields.push(['Service im Landgasthof Koninghoek',bold]);
  }else{
   if(project)fields.push([project,bold]);
   if(description && description!==project)fields.push([description,font]);
  }
  const details=fields.flatMap(([txt,f])=>lines(txt,275,8,f).map(line=>[line,f]));
  const height=rowPadding+lineHeight*details.length;
  if(y-height<rowBottom && (height<=565-rowBottom || y<125)){newPage();tableHead()}
  const fill=index%2===0?rowBlue:white;
  let offset=0,first=true;
  do {
   const capacity=Math.max(0,Math.floor((y-rowBottom-rowPadding)/lineHeight));
   const chunk=details.slice(offset,offset+capacity);
   const step=rowPadding+lineHeight*chunk.length;
   page.drawRectangle({x:43,y:y+7-step,width:509,height:step,color:fill});
   draw(49,y-5,date(r.work_date),8,bold);
   if(first){
    columnRight(369,y-5,hours(r.minutes));
    columnRight(452,y-5,amount(r.rate_cents));
    columnRight(541,y-5,amount(r.total_cents));
   }
   chunk.forEach(([line,f],i)=>draw(49,y-5-(i+1)*lineHeight,line,8,f));
   y-=step;
   offset+=chunk.length;
   first=false;
   if(offset<details.length){newPage();tableHead()}
  } while(offset<details.length);
 }
 y-=14;
 if(y<160)newPage();
 const taxLabel=s.tax_mode==='reverse'?t.reverse_label:s.tax_mode==='exempt'?t.exempt:t.vat+' '+s.tax_rate+'%';
 const totals=[[t.subtotal,s.subtotal_cents],[taxLabel,s.vat_cents],[t.total+' '+s.currency,s.total_cents]];
 const rowFills=[rgb(.93,.95,.97),rgb(.98,.98,.99),navy];
 totals.forEach(([label,val],index)=>{
  const color=index===2?white:navy;
  const number=amount(val),size=index===2?11:10;
  page.drawRectangle({x:311,y:y-8,width:241,height:22,color:rowFills[index]});
  draw(322,y,label,9,bold,color);
  draw(541-bold.widthOfTextAtSize(number,size),y,number,size,bold,color);
  y-=22;
 });
 y-=10;
 const notes=[];if(isCredit)notes.push(t.credit_ref+' '+s.original_number);if(s.tax_mode==='reverse')notes.push(t.reverse);if(s.tax_mode==='exempt')notes.push(t.exempt+': '+s.tax_note);else if(s.tax_note)notes.push(s.tax_note);if(s.currency==='USD'&&s.vat_cents)notes.push(t.vat_eur+': '+amount(s.vat_eur_cents)+' | 1 USD = '+s.fx_rate+' EUR | '+s.fx_source);const bank=s.currency==='EUR'?issuer.eur_bank:issuer.usd_bank;
 const accountLabel={nl:'Rekeninghouder',en:'Account holder',de:'Kontoinhaber'}[lang];
 const paymentDetails=String(bank??'').replace(/^Rekeninghouder(?=\s*:)/m,accountLabel);
 const paymentReference={
  nl:'Betaal op onderstaande rekening onder vermelding van factuurnummer '+inv.number+'.',
  en:'Please pay to the account below using invoice number '+inv.number+' as the payment reference.',
  de:'Bitte überweisen Sie den Rechnungsbetrag auf das unten angegebene Konto. Verwendungszweck: '+inv.number+'.'
 }[lang];
 const paymentNote=isCredit||!paymentDetails?'':t.payment+'\n'+paymentReference+'\n'+paymentDetails;
 notes.push(paymentNote,s.note);
 for(const note of notes){if(!note)continue;for(const l of lines(note,507,8)){if(y<75)newPage();draw(43,y,l,8);y-=12}y-=7;}
 const footer=issuer.footer==='Dank voor uw vertrouwen.'?t.thanks:issuer.footer;
 if(footer){
  const boldItalic=await pdf.embedFont(StandardFonts.HelveticaBoldOblique);
  for(const line of lines(footer,507,8,boldItalic)){
   if(y<75)newPage();
   draw(43,y,line,8,boldItalic);
   y-=12;
  }
 }
 const stamp=new Date(inv.reserved_at||inv.created_at);pdf.setCreationDate(stamp);pdf.setModificationDate(stamp);pdf.setTitle((isCredit?t.credit:t.title)+' '+inv.number);pdf.setAuthor(issuer.name);return pdf.save();
}
