import {createClient} from 'npm:@supabase/supabase-js@2.102.0';

const vipOrigin = 'https://vipcapital.eu';
const origins = new Set([vipOrigin, 'https://www.vipcapital.eu']);
const countries = new Set('AT BE BG CY CZ DE DK EE EL ES FI FR HR HU IE IT LT LU LV MT NL PL PT RO SE SI SK XI'.split(' '));
const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {auth:{persistSession:false}});

Deno.serve(async request => {
 const origin = request.headers.get('origin') || vipOrigin;
 const headers = {
  'Access-Control-Allow-Origin': origins.has(origin) ? origin : vipOrigin,
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
  'Vary': 'Origin'
 };
 const reply = (body: object, status=200) => Response.json(body,{status,headers});
 if(!origins.has(origin))return reply({status:'forbidden'},403);
 if(request.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(request.method!=='POST')return reply({status:'method_not_allowed'},405);

 const token = request.headers.get('authorization')?.match(/^Bearer (\S+)$/i)?.[1];
 if(!token)return reply({status:'forbidden'},401);
 const {data:{user}} = await db.auth.getUser(token);
 if(!user)return reply({status:'forbidden'},401);
 const {data:member} = await db.from('portal_members').select('active,is_admin').eq('user_id',user.id).maybeSingle();
 if(!member?.active || !member.is_admin)return reply({status:'forbidden'},403);

 let vat: string, requesterVat: string;
 try {
  const raw = await request.text();
  if(raw.length>1024)return reply({status:'invalid_input'},400);
  const body = JSON.parse(raw);
  const normalize = (value:unknown) => typeof value==='string' ? value.toUpperCase().replace(/[\s.-]/g,'') : '';
  vat = normalize(body.vat);
  requesterVat = normalize(body.requesterVat);
 } catch {
  return reply({status:'invalid_input'},400);
 }
 const countryCode = vat.slice(0,2), vatNumber = vat.slice(2);
 if(!countries.has(countryCode) || !/^[A-Z0-9]{2,12}$/.test(vatNumber))return reply({status:'invalid_input'},400);

 const requesterMemberStateCode = requesterVat.slice(0,2), requesterNumber = requesterVat.slice(2);
 if(!countries.has(requesterMemberStateCode) || !/^[A-Z0-9]{2,12}$/.test(requesterNumber))return reply({status:'invalid_requester'});
 try {
  const result = await fetch('https://ec.europa.eu/taxation_customs/vies/rest-api/check-vat-number',{
   method:'POST', headers:{'Content-Type':'application/json'},
   body:JSON.stringify({countryCode,vatNumber,requesterMemberStateCode,requesterNumber}), signal:AbortSignal.timeout(10000)
  });
  if(!result.ok)return reply({status:'unavailable'});
  const info = await result.json();
  if(typeof info.valid!=='boolean' || (Array.isArray(info.errorWrappers) && info.errorWrappers.length>0) || (info.userError && !['VALID','INVALID'].includes(info.userError)))return reply({status:'unavailable'});
  const check = {
   status:info.valid?'valid':'invalid',
   checkedAt:new Date().toISOString(),
   name:typeof info.name==='string' && info.name.trim()!=='---' ? info.name.trim() : '',
   requestIdentifier:typeof info.requestIdentifier==='string' ? info.requestIdentifier : ''
  };
  const {error} = await db.from('admin_billing_vies_checks').upsert({
   owner:user.id, vat, requester_vat:requesterVat, status:check.status,
   checked_at:check.checkedAt, name:check.name, request_identifier:check.requestIdentifier
  },{onConflict:'owner,vat,requester_vat'});
  return reply({...check,saved:!error});
 } catch {
  return reply({status:'unavailable'});
 }
});
