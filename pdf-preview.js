let viewer=null,objectUrl=null,generation=0,authClient=null;
export function closePdfPreview(){generation++;if(viewer){viewer.querySelector('iframe')?.setAttribute('src','about:blank');viewer.remove();viewer=null}if(objectUrl){URL.revokeObjectURL(objectUrl);objectUrl=null}}
window.addEventListener('pagehide',closePdfPreview);
export function pdfBadge(){const badge=document.createElement('span');badge.className='pdf-file-mark';badge.setAttribute('aria-label','PDF document');badge.innerHTML='<svg width="40" height="48" viewBox="0 0 40 48" aria-hidden="true"><path d="M4 1h22l10 10v35H4z" fill="#f7f9fc" stroke="#002040" stroke-width="1.4"/><path d="M26 1v11h10" fill="none" stroke="#bd9a45" stroke-width="1.5"/><path d="M10 19h19M10 23h14" stroke="#bd9a45" stroke-width="1.5"/><text x="9" y="37" fill="#002040" font-family="Arial,sans-serif" font-size="11" font-weight="700">PDF</text></svg>';return badge}
export function previewButton({db,bucket,path,title,canDownload=true,documentId=null}){
 const button=document.createElement('button');button.type='button';button.className='secondary document-preview-button';button.textContent='Preview';button.setAttribute('aria-label','Preview '+title);
 button.onclick=async()=>{
  closePdfPreview();const tick=generation;
  if(authClient!==db){authClient=db;db.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT')closePdfPreview()})}
  button.disabled=true;const panel=document.createElement('section');panel.className='panel private-pdf-preview';
  const top=document.createElement('div');top.className='pdf-preview-heading';const heading=document.createElement('h2');heading.textContent=title;
  const close=document.createElement('button');close.type='button';close.className='secondary';close.textContent='Close preview';close.onclick=()=>{closePdfPreview();button.focus()};top.append(pdfBadge(),heading,close);
  const state=document.createElement('p');state.setAttribute('role','status');state.textContent='Loading private preview…';panel.append(top,state);viewer=panel;document.querySelector('main').append(panel);panel.scrollIntoView({behavior:'smooth',block:'start'});
  try{
   if(canDownload===false){
    if(!documentId)throw Error('The document preview is unavailable.');
    const metadata=await db.from('portal_document_previews').select('storage_prefix,page_count').eq('document_id',documentId).maybeSingle();if(metadata.error)throw metadata.error;if(!metadata.data)throw Error('VIP Capital has not prepared this preview yet.');
    const controls=document.createElement('div');controls.className='document-actions';const previous=document.createElement('button'),next=document.createElement('button'),count=document.createElement('span');
    previous.type=next.type='button';previous.className=next.className='secondary';previous.textContent='Previous page';next.textContent='Next page';count.className='account';controls.append(previous,count,next);
    const image=document.createElement('img');image.className='pdf-page-image';panel.append(controls,image);let pageNumber=1,pageRequest=0;
    async function showPage(n){const request=++pageRequest;previous.disabled=next.disabled=true;state.textContent='Loading page '+n+'…';try{const file=await db.storage.from('vip-document-previews').download(metadata.data.storage_prefix+'/page-'+String(n).padStart(4,'0')+'.webp');if(file.error)throw file.error;if(tick!==generation||request!==pageRequest)return;if(objectUrl)URL.revokeObjectURL(objectUrl);objectUrl=URL.createObjectURL(file.data);image.src=objectUrl;image.alt=title+' · page '+n;pageNumber=n;count.textContent='Page '+n+' of '+metadata.data.page_count;state.textContent='Preview only · original PDF download is not enabled.'}catch(error){if(tick===generation)state.textContent='Unable to load preview page. '+error.message}finally{previous.disabled=pageNumber<=1;next.disabled=pageNumber>=metadata.data.page_count}}
    previous.onclick=()=>showPage(pageNumber-1);next.onclick=()=>showPage(pageNumber+1);await showPage(1);
   }else{
    const result=await db.storage.from(bucket).download(path);if(result.error)throw result.error;const blob=result.data;if(new TextDecoder().decode(await blob.slice(0,5).arrayBuffer())!=='%PDF-')throw Error('This file could not be displayed as a PDF.');if(tick!==generation)return;
    objectUrl=URL.createObjectURL(new Blob([blob],{type:'application/pdf'}));const frame=document.createElement('iframe');frame.title='PDF preview: '+title;frame.src=objectUrl+'#page=1&toolbar=0&navpanes=0';frame.loading='eager';const download=document.createElement('a');download.className='button secondary';download.href=objectUrl;download.download=title.replace(/[^a-zA-Z0-9 ._-]/g,'_')+'.pdf';download.textContent='Download PDF';state.textContent='Private document · PDF preview';panel.append(frame,download);
   }
  }catch(error){if(tick===generation)state.textContent='Unable to show this preview. '+(error.message||'Please try again.')}finally{button.disabled=false}
 };return button;
}
