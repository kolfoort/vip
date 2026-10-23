// Display only documents explicitly granted to the authenticated client account.
// Database row-level security and private storage rules continue to enforce access.
export async function loadAssignedDocuments(db,userId,columns){
 const grants=await db.from('portal_document_access').select('document_id,can_download').eq('user_id',userId);
 if(grants.error)throw grants.error;
 const ids=[...new Set(grants.data.map(row=>row.document_id))];if(!ids.length)return [];
 const docs=await db.from('portal_documents').select(columns).eq('published',true).in('id',ids).order('version_date',{ascending:false});
 if(docs.error)throw docs.error;const permission=new Map(grants.data.map(row=>[row.document_id,row.can_download]));return docs.data.map(doc=>({...doc,can_download:permission.get(doc.id)===true}));
}
