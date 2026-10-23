const check=r=>{if(r.error)throw r.error;return r.data};
let renderer;
const preparing=new Map();
export function prepareDocumentPreview(options){const key=options.doc.id;if(!preparing.has(key))preparing.set(key,buildDocumentPreview(options).finally(()=>preparing.delete(key)));return preparing.get(key)}
async function buildDocumentPreview({db,doc,progress=()=>{}}){
 const existing=check(await db.from('portal_document_previews').select('*').eq('document_id',doc.id).maybeSingle());if(existing)return existing;
 progress('Preparing private preview…');
 const blob=check(await db.storage.from('vip-documents').download(doc.storage_path));const bytes=new Uint8Array(await blob.arrayBuffer());
 const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('');
 renderer ||= import('./assets/vendor/pdfjs/build/pdf.mjs');const pdfjs=await renderer;
 pdfjs.GlobalWorkerOptions.workerSrc=new URL('./assets/vendor/pdfjs/build/pdf.worker.mjs',import.meta.url).href;
 const assets=new URL('./assets/vendor/pdfjs/',import.meta.url).href;
 const task=pdfjs.getDocument({data:bytes,cMapUrl:assets+'cmaps/',cMapPacked:true,standardFontDataUrl:assets+'standard_fonts/',wasmUrl:assets+'wasm/',isEvalSupported:false,useSystemFonts:true});
 let pdf;const uploaded=[];
 try{pdf=await task.promise;if(pdf.numPages>200)throw Error('Preview-only sharing supports documents up to 200 pages.');
  const prefix=doc.id+'/'+crypto.randomUUID();
  for(let n=1;n<=pdf.numPages;n++){progress('Preparing preview page '+n+' of '+pdf.numPages+'…');const page=await pdf.getPage(n),base=page.getViewport({scale:1}),viewport=page.getViewport({scale:Math.min(2,1400/base.width,2000/base.height)}),canvas=document.createElement('canvas');canvas.width=Math.ceil(viewport.width);canvas.height=Math.ceil(viewport.height);await page.render({canvas,canvasContext:canvas.getContext('2d'),viewport,background:'rgb(255,255,255)'}).promise;
   const image=await new Promise(resolve=>canvas.toBlob(resolve,'image/webp',.87));if(!image||image.type!=='image/webp')throw Error('This browser cannot prepare WebP document previews. Use a current Safari or Chrome version.');
   const path=prefix+'/page-'+String(n).padStart(4,'0')+'.webp';check(await db.storage.from('vip-document-previews').upload(path,image,{contentType:'image/webp',upsert:false}));uploaded.push(path);page.cleanup();canvas.width=canvas.height=1;
  }
  const record={document_id:doc.id,storage_prefix:prefix,page_count:pdf.numPages,source_sha256:digest};check(await db.from('portal_document_previews').upsert(record,{onConflict:'document_id'}));progress('Private preview ready.');return record;
 }catch(error){if(uploaded.length)await db.storage.from('vip-document-previews').remove(uploaded);throw error}finally{await task.destroy()}
}
export async function setDocumentAccess({db,doc,userId,canDownload,progress}){if(!canDownload)await prepareDocumentPreview({db,doc,progress});check(await db.from('portal_document_access').upsert({document_id:doc.id,user_id:userId,can_download:canDownload},{onConflict:'document_id,user_id'}))}
