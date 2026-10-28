export function initAdminWorkspace(){
 const root=document.getElementById('protected'),view=new URLSearchParams(location.search).get('view')==='documents'?'documents':'overview';
 document.querySelector('.admin-shortcuts')?.remove();
 const nav=document.createElement('nav');nav.className='file-tabs';nav.setAttribute('aria-label','Administration');
 for(const [key,label,url] of [['overview','Overview','document-admin.html'],['clients','Clients','client-files.html'],['documents','Documents','document-admin.html?view=documents']]){const a=document.createElement('a');a.textContent=label;a.href=url;if(key===view){a.className='active';a.setAttribute('aria-current','page')}nav.append(a)}root.insertBefore(nav,document.getElementById('account').nextSibling);
 const incoming=document.getElementById('incoming-list').closest('section'),companies=document.getElementById('company-admin-list').closest('section'),upload=document.getElementById('upload').closest('.columns'),docs=document.getElementById('admin-documents').closest('section'),requests=document.getElementById('access-requests');
 companies.hidden=true;requests.hidden=view!=='overview';incoming.hidden=view!=='documents';upload.hidden=view!=='documents';docs.hidden=view!=='documents';
 if(view==='documents'){document.querySelector('h1').textContent='Documents.';document.querySelector('.intro p').textContent='Review received documents and manage the files shared with your clients.';const access=document.getElementById('member-list').closest('section');const fold=document.createElement('details');fold.className='panel';const summary=document.createElement('summary');summary.textContent='Advanced account access';fold.append(summary);while(access.firstChild)fold.append(access.firstChild);access.replaceWith(fold)}
}
