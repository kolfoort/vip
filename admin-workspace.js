export function initAdminWorkspace(){
 const root=document.getElementById('protected'),documents=new URLSearchParams(location.search).get('view')==='documents';document.querySelector('.admin-shortcuts')?.remove();
 const nav=document.createElement('nav');nav.className='file-tabs';nav.setAttribute('aria-label','Administration');
 for(const [title,url]of [['Werkomgevingen','admin-home.html'],['Uren & facturen','billing/'],['Overview','document-admin.html'],['Clients & agreements','client-files.html'],['Documents','document-admin.html?view=documents']]){const a=document.createElement('a');a.textContent=title;a.href=url;nav.append(a)}root.insertBefore(nav,document.getElementById('account').nextSibling);
 const company=document.getElementById('company-admin-list').closest('section');company.hidden=true;
 for(const id of ['incoming-list','admin-documents'])document.getElementById(id).closest('section').hidden=!documents;
 document.getElementById('upload').closest('.columns').hidden=!documents;
 document.getElementById('access-requests').hidden=documents;
 if(!documents){const card=document.createElement('section');card.className='panel';card.innerHTML='<span class="eyebrow">VIP Capital</span><h2>Client files.</h2><p>Manage company profiles, shared documents and MCNDAs. Review client signatures before final approval.</p><a class="button" href="client-files.html">Open client files</a>';root.insertBefore(card,document.getElementById('access-requests'))}
}
