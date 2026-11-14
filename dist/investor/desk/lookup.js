/* ===== Property lookup: address or PIN in, public-record dossier out, then "how do I see the inside?" =====
   Cook County + Lake County parcel data, City of Chicago open data and FEMA flood maps, queried straight from the browser (no keys).
   Other counties: parcel data is not reachable this way, so the dossier says so and still gives every link. */
(()=>{
const CK='https://datacatalog.cookcountyil.gov/resource/',CH='https://data.cityofchicago.org/resource/',LK='https://maps.lakecountyil.gov/arcgis/rest/services/GISMapping/WABParcels/MapServer/12';
const E=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const $$=id=>document.getElementById(id);
const money=n=>n==null||n===''||isNaN(n)?'—':'$'+Math.round(+n).toLocaleString('en-US');
const dt=s=>s?String(s).slice(0,10):'—';
const sq=s=>String(s).replace(/'/g,"''");
const num=v=>v==null||v===''?null:+v;
const SUFFIX=new Set(['ST','STREET','AVE','AV','AVENUE','RD','ROAD','DR','DRIVE','BLVD','BOULEVARD','CT','COURT','LN','LANE','PL','PLACE','TER','TERRACE','PKWY','PARKWAY','WAY','CIR','CIRCLE','HWY','HIGHWAY','TRL','TRAIL','SQ','SQUARE']);
const DIRS={N:'N',S:'S',E:'E',W:'W',NORTH:'N',SOUTH:'S',EAST:'E',WEST:'W'};
const pinFmt=p=>p&&p.length===14?`${p.slice(0,2)}-${p.slice(2,4)}-${p.slice(4,7)}-${p.slice(7,10)}-${p.slice(10)}`:p&&p.length===10?`${p.slice(0,2)}-${p.slice(2,4)}-${p.slice(4,7)}-${p.slice(7)}`:p;

async function sx(base,id,params){const u=new URL(base+id+'.json');Object.entries(params).forEach(([k,v])=>u.searchParams.set(k,v));const r=await fetch(u);if(!r.ok)throw Error(id+' returned '+r.status);return r.json()}

/* ---- parse what the user typed ---- */
function parseInput(raw){
 const t=String(raw||'').trim(),digits=t.replace(/[\s-]/g,'');
 if(/^\d{14}$/.test(digits))return{pin:digits,county:'cook'};
 if(/^\d{10}$/.test(digits))return{pin:digits,county:'lake'};
 const zip=(t.match(/\b(\d{5})(?:-\d{4})?\s*$/)||[])[1]||'';
 let street=t.split(',')[0].toUpperCase().replace(/[.#]/g,' ').replace(/\b(APT|UNIT|STE|SUITE|FL|FLOOR)\b.*$/,'').replace(/\s+/g,' ').trim();
 const m=street.match(/^(\d+)\s+(?:(N|S|E|W|NORTH|SOUTH|EAST|WEST)\s+)?(.+)$/);
 if(!m)return{err:'Type a street address like "1060 W Addison St, Chicago" or a PIN (14 digits in Cook, 10 in Lake).'};
 let dir=m[2]?DIRS[m[2]]:'';let words=m[3].replace(/\b\d{5}(-\d{4})?\s*$/,'').trim().split(' ');
 // The street ends at its suffix (ST, CT, AVE...). Anything after it is the city, state or ZIP, so addresses typed without commas work.
 // "1027 N Ave" is North Avenue: a direction word followed straight away by the suffix is the street's name, not a direction.
 if(dir&&SUFFIX.has(words[0])){words=[{N:'NORTH',S:'SOUTH',E:'EAST',W:'WEST'}[dir],...words];dir=''}
 const si=words.findIndex((w,i)=>i>=1&&SUFFIX.has(w));
 let rest='';
 if(si>0){rest=words.slice(si+1).join(' ');words=words.slice(0,si)}
 else if(!t.includes(',')){while(words.length>1&&/^(IL|ILLINOIS)$/.test(words[words.length-1]))words.pop();if(words.length>1){rest=words.slice(1).join(' ');words=[words[0]]}}   // no suffix typed: search on the first street word and let the picker narrow it
 const name=words.join(' ');
 return{num:m[1],dir,name,zip,city:(t.split(',')[1]||rest).trim().toUpperCase()};
}

/* ---- the lookup ---- */
async function findCook(p){
 if(p.pin){return (await sx(CK,'3723-97qp',{'$where':`pin='${p.pin}'`,'$order':'year DESC','$limit':'1'})).map(r=>({...r,src:'cook'}))}
 const pre=[p.num,p.dir,p.name].filter(Boolean).join(' ');
 let rows=await sx(CK,'3723-97qp',{'$where':`upper(prop_address_full) like '${sq(pre)}%'`,'$order':'year DESC','$limit':'200'});
 const top=Math.max(0,...rows.map(r=>+r.year||0));rows=rows.filter(r=>(+r.year||0)>=top-1);   // drop retired parcels
 const seen=new Set();return rows.filter(r=>seen.has(r.pin)?false:seen.add(r.pin)).map(r=>({...r,src:'cook'}));
}
const lakeRow=a=>({src:'lake',pin:a.PIN,prop_address_full:a.situs_addr_line_1||'',prop_address_city_name:a.situs_addr_city||'',prop_address_state:'IL',prop_address_zipcode_1:(a.situs_addr_zip_legdat||'').slice(0,5),
 mail_address_name:a.taxpayer_name||a.taxpayer_org_name||'',mail_address_full:a.taxpayer_addr_line_1||'',mail_address_city_name:a.taxpayer_addr_city||'',mail_address_state:a.taxpayer_addr_state||'',mail_address_zipcode_1:a.taxpayer_addr_zip||''});
async function lakeQuery(where,geo){const u=`${LK}/query?where=${encodeURIComponent(where)}&outFields=*&returnGeometry=${geo?'true':'false'}&outSR=4326&resultRecordCount=25&f=json`;const r=await fetch(u);if(!r.ok)throw Error('Lake County GIS '+r.status);const j=await r.json();if(j.error)throw Error(j.error.message||'Lake County GIS error');return j.features||[]}
async function findLake(p){
 if(p.pin)return (await lakeQuery(`PIN='${sq(p.pin)}'`)).map(f=>lakeRow(f.attributes));
 const w=`situs_cmptaddr_number_legdat='${sq(p.num)}' AND upper(situs_cmptaddr_name_legdat) like '${sq(p.name)}%'`+(p.dir?` AND situs_cmptaddr_direct_legdat='${p.dir}'`:'');
 return (await lakeQuery(w)).map(f=>lakeRow(f.attributes));
}
async function findPins(p){
 const tasks=p.pin?[p.county==='lake'?findLake(p):findCook(p)]:[findCook(p),findLake(p)];
 const res=await Promise.allSettled(tasks);
 if(res.every(r=>r.status==='rejected'))throw res[0].reason;
 let rows=res.flatMap(r=>r.status==='fulfilled'?r.value:[]);
 if(!rows.length&&p.dir&&!p.pin)return findPins({...p,dir:''});   // no match with that direction: show every direction so the picker can sort it out
 if(p.zip){const z=rows.filter(r=>(r.prop_address_zipcode_1||'').slice(0,5)===p.zip);if(z.length)rows=z}   // ZIP narrows the list only if it matches something
 return rows.slice(0,30);
}

async function dossier(addrRow){
 if(addrRow.src==='lake')return dossierLake(addrRow);
 const pin=addrRow.pin,dash=pinFmt(pin);
 const D={pin,dash,addr:addrRow,county:'Cook',when:new Date().toISOString(),errs:[]};
 const isChi=/CHICAGO/i.test(addrRow.prop_address_city_name||'');
 const pm=(addrRow.prop_address_full||'').toUpperCase().match(/^(\d+)\s+(?:(N|S|E|W)\s+)?(.+?)(?:\s+(?:ST|AVE|RD|DR|BLVD|CT|LN|PL|TER|PKWY|WAY|CIR|HWY))?$/)||[];
 const job=async(k,f)=>{try{D[k]=await f()}catch(e){D.errs.push(k+': '+e.message)}};
 await job('uni',async()=>(await sx(CK,'nj4t-kc8j',{'$where':`pin='${pin}'`,'$order':'year DESC','$limit':'1'}))[0]);
 const cls=D.uni?.class||'';
 const lat=num(D.uni?.lat),lon=num(D.uni?.lon);
 await Promise.all([
  job('res',()=>sx(CK,'x54s-btds',{'$where':`pin='${pin}'`,'$order':'year DESC','$limit':'4'})),
  job('condo',()=>sx(CK,'3r7i-mrz4',{'$where':`pin='${pin}'`,'$order':'year DESC','$limit':'1'})),
  job('av',()=>sx(CK,'uzyt-m557',{'$where':`pin='${pin}'`,'$order':'year DESC','$limit':'4'})),
  job('sales',()=>sx(CK,'wvhk-k5uv',{'$where':`pin='${pin}'`,'$order':'sale_date DESC','$limit':'10'})),
  job('appeals',()=>sx(CK,'y282-6ig3',{'$where':`pin='${pin}'`,'$order':'year DESC','$limit':'6'})),
  job('taxsale',()=>sx(CK,'55ju-2fs9',{'$where':`pin='${dash}'`,'$order':'tax_sale_year DESC','$limit':'10'})),
  job('flood',()=>fema(lat,lon)),
  ...(isChi&&pm[1]?[
   job('permits',()=>sx(CH,'ydr8-5enu',{'$where':`street_number='${pm[1]}'${pm[2]?` AND street_direction='${pm[2]}'`:''} AND upper(street_name)='${sq(pm[3])}'`,'$order':'issue_date DESC','$limit':'25'})),
   job('viol',()=>sx(CH,'22u3-xenr',{'$where':`address like '${sq(pm[1]+' '+(pm[2]?pm[2]+' ':'')+pm[3])}%'`,'$order':'violation_date DESC','$limit':'40'})),
   job('vacviol',()=>sx(CH,'kc9i-wq85',{'$where':`upper(property_address) like '${sq(pm[1]+' '+(pm[2]?pm[2]+' ':'')+pm[3])}%'`,'$order':'issued_date DESC','$limit':'10'})),
   job('scoff',()=>sx(CH,'crg5-4zyp',{'$where':`upper(address) like '${sq(pm[1]+' '+(pm[2]?pm[2]+' ':'')+pm[3])}%'`,'$limit':'5'})),
   job('vac311',()=>sx(CH,'7nii-7srd',{'$where':`address_street_number='${pm[1]}'${pm[2]?` AND address_street_direction='${pm[2]}'`:''} AND upper(address_street_name)='${sq(pm[3])}'`,'$order':'date_service_request_was_received DESC','$limit':'10'}))
  ]:[])
 ]);
 D.isChi=isChi;D.cls=cls;D.lat=lat;D.lon=lon;
 return D;
}

async function fema(lat,lon){if(lat==null||lon==null)return null;const u=`https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer/28/query?geometry=${lon},${lat}&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=FLD_ZONE,ZONE_SUBTY,SFHA_TF&returnGeometry=false&f=json`;const r=await fetch(u);if(!r.ok)throw Error('FEMA '+r.status);const j=await r.json();return(j.features||[])[0]?.attributes||{none:true}}
const ctr=g=>{const ring=(g&&g.rings&&g.rings[0])||[];if(!ring.length)return[null,null];return[ring.reduce((s,p)=>s+p[1],0)/ring.length,ring.reduce((s,p)=>s+p[0],0)/ring.length]};
async function dossierLake(row){
 const pin=row.pin,D={pin,dash:pinFmt(pin),addr:row,county:'Lake',when:new Date().toISOString(),errs:[],isChi:false};
 let at={},geo=null;
 try{const f=(await lakeQuery(`PIN='${sq(pin)}'`,true))[0];if(!f)throw Error('parcel not returned');at=f.attributes;geo=f.geometry}catch(e){D.errs.push('parcel: '+e.message)}
 const [lat,lon]=ctr(geo);D.lat=lat;D.lon=lon;
 const stories=at.stories,gar=at.garage_count?at.garage_count+(at.garage_size?' ('+at.garage_size+' sq ft)':''):null;
 D.res=[{char_yrblt:at.improve_year_built,char_bldg_sf:at.liv_sq_ft||at.bldg_sq_ft,char_beds:at.bedroom_count,char_fbath:at.full_baths,char_hbath:at.half_baths,char_stories:stories,char_const_type:at.const_type,char_cnst_qlty:at.qual_grade,char_repair_cnd:at.condition,char_roof_cnst:at.roof_cover,char_heat:at.heating,char_air:at.central_air,char_frpl:at.fireplace_stk_open,char_bsmt_sq_ft:at.bsmt_sq_ft,char_bsmt_sq_ft_fin:at.bsmt_sq_ft_fin,char_attic_sq_ft:at.attic_sq_ft,char_garage:gar,char_use:at.land_use_code,char_land_sf:at.lot_area_sf}];
 D.cls=at.prop_class_pardat||'';D.classText=[at.class_desc_pardat,at.land_use_code].filter(Boolean).join(' · ');
 D.uni={township_name:at.TOWNSHIPNAME||at.township,class:D.cls};
 D.av=[at.assess_total_assyr?{year:'Current assessment',certified_land:at.assess_land_assyr,certified_bldg:at.assess_bldg_assyr,certified_tot:at.assess_total_assyr}:null,at.assess_total_taxyr?{year:'Tax-year assessment',certified_land:at.assess_land_taxyr,certified_bldg:at.assess_bldg_taxyr,certified_tot:at.assess_total_taxyr}:null].filter(Boolean);
 D.sales=[1,2].map(i=>at['sale_date'+i]&&at['sale_amt'+i]!=null?{sale_date:new Date(at['sale_date'+i]).toISOString(),sale_price:at['sale_amt'+i],sale_filter_less_than_10k:!(at['sale_amt'+i]>=10000),doc_no:at['doc_num'+i]}:null).filter(Boolean).sort((a,b)=>b.sale_date.localeCompare(a.sale_date));
 D.extra=[['Municipality',at.MUNI_NAME],['Zoning',at.ZONING],['Elementary district',at.ELEM_NAME],['High school district',at.HIGH_NAME],['Fire district',at.FIRE_DIST],['TIF district',at.TIF_DIST],['Neighborhood',at.nghbr_desc],['Legal description',[at.legdesc1,at.legdesc2,at.legdesc3].filter(Boolean).join(' ').replace(/\s+/g,' ').trim()]].filter(r=>r[1]);
 D.exempt=at.exempt_ind==='Y';
 await Promise.all([ (async()=>{try{D.flood=await fema(lat,lon)}catch(e){D.errs.push('flood: '+e.message)}})() ]);
 return D;
}

/* ---- reading the records ---- */
const OWNER_ENTITY=/\b(LLC|L\.L\.C|INC|CORP|CORPORATION|LP|LLP|LTD|COMPANY|CO|PARTNERS|PARTNERSHIP|HOLDINGS|PROPERTIES|INVESTMENTS|REALTY|ASSOCIATION|BANK|MORTGAGE|FUND|CAPITAL)\b/i;
const OWNER_TRUST=/\b(TRUST|TR|TRUSTEE|TRUSTEES)\b/i;
const OWNER_ESTATE=/\b(ESTATE|DECEASED|HEIRS|EST OF|% )/i;
const norm=s=>String(s||'').toUpperCase().replace(/[^A-Z0-9 ]/g,' ').replace(/\b(STREET|AVENUE|ROAD|DRIVE|BOULEVARD|COURT|LANE|PLACE)\b/g,m=>m.slice(0,2)).replace(/\s+/g,' ').trim();
const classNote=c=>{c=String(c||'');if(c==='299')return'Residential condominium unit (class 299)';if(c[0]==='2')return'Residential, 1 to 6 units (class '+c+')';if(c[0]==='3')return'Multifamily, 7+ units (class '+c+')';if(c[0]==='1')return'Vacant land (class '+c+')';if(c[0]==='5')return'Commercial or industrial (class '+c+')';if(['6','7','8'].includes(c[0]))return'Commercial or industrial with tax incentive (class '+c+')';if(c==='0')return'Exempt';return c?'Class '+c:''};

// Street number + street name only: the tax bill often drops the direction or says ST where the parcel says AVE.
const core=s=>String(s||'').toUpperCase().replace(/[^A-Z0-9 ]/g,' ').split(/\s+/).filter(w=>w&&!DIRS[w]&&!SUFFIX.has(w)).join(' ');

function analyze(D){
 const A=D.addr,flags=[],f=(lvl,t,why)=>flags.push({lvl,t,why});
 const R=(D.res||[])[0],C=(D.condo||[])[0],ch=R||C||{};
 const owner=A.mail_address_name||A.owner_address_name||'';
 const ownerEnt=OWNER_ENTITY.test(owner),ownerTrust=OWNER_TRUST.test(owner),ownerEst=OWNER_ESTATE.test(owner);
 const absentee=!!A.mail_address_full&&core(A.mail_address_full)!==core(A.prop_address_full);
 const lastSale=(D.sales||[]).find(s=>!(s.sale_filter_less_than_10k));
 const yrBuilt=num(ch.char_yrblt);
 const avRow=(D.av||[]).find(v=>num(v.board_tot)>0||num(v.certified_tot)>0);const avTot=avRow?(num(avRow.board_tot)>0?num(avRow.board_tot):num(avRow.certified_tot)):null;
 const lake=D.county==='Lake',mult=lake?3:10;   // Cook assesses homes at 10%; the rest of Illinois at 33 1/3%
 const resClass=lake?D.cls==='RES':(/^2/.test(D.cls)||/^3/.test(D.cls));
 const impliedValue=(avTot&&resClass)?avTot*mult:null;
 const open=(D.viol||[]).filter(v=>/OPEN/i.test(v.violation_status||''));
 const sit=[];
 if(absentee)f('warn','Owner’s tax bill goes to a different address','Mailing address: '+[A.mail_address_full,A.mail_address_city_name,A.mail_address_state].filter(Boolean).join(', ')+'. Absentee owners are often landlords, heirs or tired owners. That address is where your letter goes.');
 else if(owner)f('info','Tax bill goes to the property itself','Likely owner-occupied, or a landlord who uses the property address for mail. Not proof of either.');
 if(ownerEnt)f('info','Owner is an entity ('+owner+')','Find the registered agent and managers at the Illinois Secretary of State. They are the ones who can say yes.');
 if(ownerTrust)f('info','Owner is a trust','The trustee decides. Pull the trust deed or recorded trustee name from the Recorder.');
 if(ownerEst)f('warn','Name suggests an estate or deceased owner','The personal representative (probate case) or heirs decide. Check the Clerk of the Circuit Court probate docket.');
 if(lastSale){const age=(Date.now()-new Date(lastSale.sale_date))/31557600000;
  f(age<1.5?'warn':'info','Last arm’s-length sale '+dt(lastSale.sale_date)+' for '+money(lastSale.sale_price),(lastSale.buyer_name?'Buyer: '+lastSale.buyer_name+'. ':'')+(age<1.5?'Sold recently, so listing photos and the buyer’s plans may still exist. ':'')+'Compare to the county’s implied value below.')}
 else if((D.sales||[]).length)f('info','Only non-market transfers on record (under $10,000, family, or deed changes)','Treat the price history as unknown.');
 if(D.taxsale?.length)f('bad','Appears in the county tax sale list ('+D.taxsale.map(t=>t.tax_sale_year).join(', ')+')','Delinquent taxes at some point. Check the Treasurer for what is owed now and whether a tax buyer holds it. The open-data list is not current; the Treasurer is the source.');
 const fl=D.flood;if(fl&&!fl.none){if(fl.SFHA_TF==='T')f('bad','FEMA special flood hazard area (zone '+fl.FLD_ZONE+')','Flood insurance is required with a mortgage and costs real money. Get a quote before you bid.');else f('ok','FEMA flood zone '+fl.FLD_ZONE,fl.ZONE_SUBTY||'')}
 if(yrBuilt&&yrBuilt<1978)f('warn','Built '+yrBuilt+': lead paint rules apply','Pre-1978. Plan for lead-safe work and disclosures if you rent or resell.');
 if(yrBuilt&&yrBuilt<1960)f('info','Built '+yrBuilt+': check for old wiring, plumbing and asbestos','These are the usual surprises in a house you have not seen inside.');
 if(D.isChi){
  if(open.length)f('bad',open.length+' open city building violation'+(open.length>1?'s':''),'Open violations transfer with the building. Read the inspector comments below: they describe the inside.');
  else if((D.viol||[]).length)f('info',(D.viol||[]).length+' past city building violations, none open','');
  if((D.vacviol||[]).length)f('bad','City vacant-building case on file','The city has treated this as a vacant building. Fines may follow the property. This is a strong sign nobody lives there.');
  if((D.vac311||[]).length)f('warn',(D.vac311||[]).length+' vacant/abandoned building report'+((D.vac311||[]).length>1?'s':'')+' to 311','Latest: '+dt(D.vac311[0].date_service_request_was_received)+(D.vac311[0].is_building_open_or_boarded_?' ('+D.vac311[0].is_building_open_or_boarded_.toLowerCase()+')':'')+'.');
  if((D.scoff||[]).length)f('bad','On the City’s Building Code Scofflaw list','Owner has ignored court-ordered code violations. Expect liens and a stubborn owner.');
 }
 // occupancy guess for the Access stage
 let guess='own',gwhy='Tax bill goes to the property.';
 if((D.vacviol||[]).length||(D.vac311||[]).length||(D.scoff||[]).length){guess='vac';gwhy='City records suggest vacant.'}
 else if(absentee||ownerEnt){guess='ten';gwhy=absentee?'Owner lives elsewhere, so a tenant may be there.':'Entity owner, so a tenant may be there.'}
 if(D.exempt)f('info','Tax-exempt parcel','Government, church, school or nonprofit owner. Different rules apply to buying it.');
 return{lake,mult,owner,ownerEnt,ownerTrust,ownerEst,absentee,lastSale,yrBuilt,avTot,impliedValue,open,flags,guess,gwhy,ch,R,C};
}

/* ---- how do I see the inside? Ranked by what the records say ---- */
function insidePlan(D,X){
 const a=D.addr,adr=[a.prop_address_full,a.prop_address_city_name,'IL'].filter(Boolean).join(', ');
 const steps=[];const add=(rank,t,body,go)=>steps.push({rank,t,body,go});
 add(1,'Start with photos that already exist (free, legal, today)','Old listings keep their interior photos. Search the address on Zillow, Redfin and Realtor.com and open "sold" or "off-market" history, not just active listings. Check the listing agent’s own site and any MLS virtual tour. Dated photos tell you the age of the kitchen, baths and floors even if they are years old.','photos');
 if((D.viol||[]).length&&D.isChi)add(2,'Read the city inspectors’ comments (they have been inside)','Chicago inspectors write what they see room by room. They are listed below. Anything marked FAILED or an unresolved complaint is a repair you will pay for. For full inspection files, request them from the Department of Buildings through a FOIA request.');
 if(!D.isChi)add(2,'Ask the city or village building department for the property file','Permits, inspections and code complaints are public records at the municipal building department (or the county, if unincorporated). Ask for the permit history and any open code cases by address; a records request is free or cheap. Permits date the kitchen, bath, roof, furnace and electrical work, and open cases tell you what the inside looks like to an inspector.');
 if((D.permits||[]).length)add(2,'Use the permit history to date the inside','Permits show electrical, plumbing, HVAC, kitchen and roof work and when. No permits on a house with obvious updates means unpermitted work, which becomes your cost.');
 if(X.guess==='own'&&!X.ownerEnt)add(3,'The occupant is probably the owner: ask them, in writing, first','Mail a short letter to the property address, then knock once in daytime hours. They can say no and that ends it. Never imply you are an inspector, the bank or the city. If the house is in foreclosure or behind on taxes, a purchase from them falls under the Illinois Mortgage Rescue Fraud Act, so use a lawyer and put everything in writing.','acc');
 if(X.absentee||X.ownerEnt||X.ownerTrust)add(3,'Reach whoever controls it, then ask them to show it',(X.absentee?`Send the letter to the owner’s mailing address (${[a.mail_address_full,a.mail_address_city_name].filter(Boolean).join(', ')}) and to the property. `:'')+(X.ownerEnt?'For an LLC or corporation, look up the registered agent and managers at the Illinois Secretary of State and write to them. ':'')+'If a tenant lives there, the landlord has to arrange entry with the notice the lease and local law require (Chicago has its own tenant ordinance). Never enter on the landlord’s word alone; the tenant has the right to possession.','acc');
 if(X.ownerEst)add(3,'The decision-maker is the estate’s representative','Find the probate case on the Clerk of the Circuit Court docket for the name. The representative can authorize a walkthrough. Heirs cannot, unless they have been appointed.','acc');
 if(X.guess==='vac')add(3,'It looks vacant: get written permission from whoever controls it','Owner, lender or servicer, court-appointed receiver, or city (if the city holds a demolition or receivership interest). Get a signed access agreement with a time window and who attends. Bring a second person and a licensed inspector. Do not open lockboxes, doors or windows, even if they are unlocked. That is trespass, and the owner or an unseen occupant can still be there.','acc');
 if(D.taxsale?.length)add(4,'If a tax buyer or the county has an interest, ask them directly','A tax buyer has no right to enter until they hold a deed. If the tax buyer or county has petitioned for a deed, the Treasurer’s and Clerk’s records list who. They can sometimes consent to a visit, usually not.');
 add(5,'If it is in foreclosure: you probably will not get in before the sale','Check the Clerk of the Circuit Court docket for the case and the plaintiff’s attorney, and for any receiver or order of possession. Call the attorney and ask if an interior inspection is offered. Most are not. At the sale, the property is as-is and often occupied. Price the unseen interior with the higher repair contingency (Interior access section of the Access stage).','acc');
 add(6,'Buy access instead of begging for it','A licensed Illinois real estate agent can request showings on listed or REO properties. Banks sell foreclosed homes through listing agents, HUD Home Store, HomePath (Fannie Mae) and HomeSteps (Freddie Mac); those show on request. For off-market ones, a local contractor or inspector you hire can walk it once the owner agrees. Only an owner or an authorized representative can grant that.');
 add(7,'Never do this','Do not enter an unlocked or vacant property, open a lockbox, remove a notice, misstate who you are to a tenant or neighbor, or peer into windows. In Illinois, entering a residence without authority is criminal trespass and can be a felony if anyone is home. It is not worth the deal.');
 return steps.sort((x,y)=>x.rank-y.rank);
}

/* ---- links for the things no free data feed has ---- */
function links(D,X){
 const a=D.addr,adr=[a.prop_address_full,a.prop_address_city_name,'IL',a.prop_address_zipcode_1].filter(Boolean).join(' '),own=X.owner,L=[];
 const add=(g,t,u,cp,w)=>L.push({g,t,u,cp,w});
 const q=encodeURIComponent(adr);
 add('Photos & interior','Zillow (sold and off-market photos)',`https://www.zillow.com/homes/${q}_rb/`,'','Open the property, then "Price history" and photos.');
 add('Photos & interior','Search all listing sites for the address',`https://www.google.com/search?q=${encodeURIComponent('"'+a.prop_address_full+'" '+(a.prop_address_city_name||'')+' Redfin OR Realtor OR Zillow OR Trulia')}`,'','Finds listing photos, virtual tours and agent pages.');
 add('Photos & interior','Street view',D.lat!=null?`https://www.google.com/maps/@?api=1&map_action=pano&viewpoint=${D.lat},${D.lon}`:`https://www.google.com/maps/search/?api=1&query=${q}`,'','Check the timeline control for older images.');
 add('Photos & interior','Aerial view (roof, yard, additions)',D.lat!=null?`https://www.google.com/maps/@${D.lat},${D.lon},100m/data=!3m1!1e3`:`https://www.google.com/maps/search/?api=1&query=${q}`,'','Roof condition, additions and parked equipment show from above.');
 if(D.county==='Lake'){
  add('Taxes & liens','Lake County property search (characteristics, tax summary)','https://tax.lakecountyil.gov/search/commonsearch.aspx?mode=realprop',D.pin,'Paste the PIN. Tax bills, delinquent installments and tax-sale history.');
  add('Taxes & liens','Lake County Recorder: deeds, mortgages, liens, lis pendens','https://lake.il.publicsearch.us/',own,'Search by owner name or PIN.');
  add('Taxes & liens','Lake County Circuit Clerk: foreclosure and probate cases','https://www.lakecountycircuitclerk.org/',own,'19th Judicial Circuit. Plaintiff\u2019s attorney, receiver, orders of possession.');
  add('Taxes & liens','Lake County Board of Review','https://www.lakecountyil.gov/135/Board-of-Review',D.pin,'Assessment appeal deadline and process.');
  add('Who owns it','Lake County GIS map viewer','https://www.lakecountyil.gov/636/GISMaps',D.pin,'Parcel lines, zoning, floodplain, wetlands.');
  add('Condition','Lake County permits & planning (unincorporated areas)','https://www.lakecountyil.gov/262/Planning-Building-Development',a.prop_address_full,'Inside a city or village, ask that municipality\u2019s building department instead.');
 } else {
 add('Taxes & liens','Cook County Assessor page for this PIN',`https://www.cookcountyassessoril.gov/pin/${D.pin}`,'','Characteristics, history, appeals.');
 add('Taxes & liens','Cook County Treasurer: what is owed now','https://www.cookcountytreasurer.com/',D.dash,'Paste the PIN. Unpaid installments and tax-sale status.');
 add('Taxes & liens','Recorder: deed, mortgage, liens, lis pendens','https://crs.cookcountyclerkil.gov/',D.dash,'Paste the PIN. Names the lender and any foreclosure filing.');
 add('Taxes & liens','Circuit Court docket: foreclosure and probate cases','https://casesearch.cookcountyclerkofcourt.org/',own,'Search the owner’s name. Plaintiff’s attorney, receiver, orders of possession.');
 add('Taxes & liens','Judicial Sales Corporation (Cook foreclosure sale list)','https://www.tjsc.com/','','Upcoming auction dates and terms.');
 }
 add('Who owns it','Illinois Secretary of State: LLC and corporation search','https://apps.ilsos.gov/businessentitysearch/',own,'Registered agent and managers.');
 if(D.county!=='Lake')add('Who owns it','CookViewer map','https://maps.cookcountyil.gov/cookviewer/',D.dash,'Lot lines, zoning, flood, TIF district.');
 add('Condition','FEMA flood map service center','https://msc.fema.gov/portal/search',adr,'Official flood map and letter.');
 if(D.isChi)add('Condition','Chicago building records search (inspections, permits)','https://webapps1.chicago.gov/buildingrecords/',a.prop_address_full,'Scanned inspection and permit files; FOIA for the rest.');
 return L;
}

/* ---- rendering ---- */
const TH='style="text-align:left"',LV={bad:'var(--bad)',warn:'var(--warn)',ok:'var(--ok)',info:'var(--mut)'};
const LBL={yrblt:'Year built',bldg_sf:'Building sq ft',unit_sf:'Unit sq ft',building_sf:'Whole building sq ft',beds:'Bedrooms',bedrooms:'Bedrooms',rooms:'Rooms',fbath:'Full baths',hbath:'Half baths',full_baths:'Full baths',half_baths:'Half baths',frpl:'Fireplaces',type_resd:'Style',cnst_qlty:'Construction quality',apts:'Apartments',attic_fnsh:'Attic finish',attic_type:'Attic',gar1_size:'Garage',gar1_att:'Garage attached',gar1_cnst:'Garage construction',gar1_area:'Garage in living area',bsmt:'Basement',bsmt_fin:'Basement finish',ext_wall:'Exterior walls',heat:'Heat',repair_cnd:'Condition (county’s rating)',roof_cnst:'Roof',use:'Use',air:'Air conditioning',porch:'Porch',tp_plan:'Plan',stories:'Stories',const_type:'Construction',bsmt_sq_ft:'Basement sq ft',bsmt_sq_ft_fin:'Finished basement sq ft',attic_sq_ft:'Attic sq ft',garage:'Garage'};
const HIDE=['ncu','site','land_sf','building_pins','building_non_units','tieback_proration_rate'];
const pretty=k=>{const b=k.replace(/^char_/,'');return LBL[b]||b.replace(/_/g,' ').replace(/\b\w/g,c=>c.toUpperCase())};
const kv=(o,skip=[])=>Object.entries(o||{}).filter(([k,v])=>k.startsWith('char_')&&v!==''&&v!=null&&!skip.includes(k)&&!HIDE.includes(k.replace(/^char_/,''))).map(([k,v])=>`<tr><td>${E(pretty(k))}</td><td>${E(String(v).replace(/\.0$/,''))}</td></tr>`).join('');

function render(D){
 const X=analyze(D),a=D.addr,c=X.ch,sit=insidePlan(D,X),L=links(D,X);
 const G={};L.forEach(l=>(G[l.g]=G[l.g]||[]).push(l));
 const sqft=c.char_bldg_sf||c.char_unit_sf||c.char_building_sf;
 const facts=[['PIN',D.dash],['Address',[a.prop_address_full,a.prop_address_city_name,a.prop_address_zipcode_1].filter(Boolean).join(', ')],['Township',D.uni?.township_name],['Property class',D.classText||classNote(D.cls)],['Owner on tax bill',X.owner],['Tax bill mailed to',[a.mail_address_full,a.mail_address_city_name,a.mail_address_state,a.mail_address_zipcode_1].filter(Boolean).join(', ')],['Year built',X.yrBuilt||null],['Living area',sqft?Math.round(sqft).toLocaleString()+' sq ft':null],['Lot',c.char_land_sf?Math.round(c.char_land_sf).toLocaleString()+' sq ft':null],['County assessed value',X.avTot?money(X.avTot)+' (latest year)':null],['County-implied market value',X.impliedValue?money(X.impliedValue)+(X.lake?' (assessed × 3, rough)':' (assessed ÷ 10%, rough)'):null],...(D.extra||[])].filter(r=>r[1]);
 let h=`<h3 style="margin-top:6px">${E(a.prop_address_full)}${a.prop_address_city_name?', '+E(a.prop_address_city_name):''}</h3>
 <p class="noprint"><button class="btn" onclick="lookUse()">Use in this deal</button> <button class="btn o" onclick="lookCopy()">Copy dossier</button> <span id="lkmsg" class="lead"></span></p>
 <h3>Red flags and what they mean</h3>${X.flags.map(x=>`<div class="chk" style="grid-template-columns:1fr"><div><b style="color:${LV[x.lvl]}">${E(x.t)}</b><div class="w">${E(x.why)}</div></div></div>`).join('')||'<p class="lead">Nothing flagged from the open data.</p>'}
 <h3 style="margin-top:18px">How do I actually see the inside?</h3>
 <p class="lead">${X.guess==='vac'?'Records suggest this may be vacant.':X.guess==='ten'?'The owner lives elsewhere or is an entity, so someone else may be living there.':'It looks owner-occupied.'} ${E(X.gwhy)} Everything below is legal and needs somebody’s consent.</p>
 ${sit.map((s,i)=>`<div class="chk" style="grid-template-columns:1fr"><div><b>${i+1}. ${E(s.t)}</b><div class="w">${E(s.body)}</div>${s.go==='acc'?`<div class="w"><a href="#" onclick="go(STAGES.findIndex(x=>x.id==='acc'));return false">Open Access & control (letters, contact log, visit log)</a></div>`:''}</div></div>`).join('')}
 <h3 style="margin-top:18px">What the county says is inside</h3><table><tr><th ${TH}>Item</th><th ${TH}>Record</th></tr>${kv(c,['char_land_sf'])||'<tr><td colspan="2">No building record found for this PIN (vacant land, exempt, commercial or new).</td></tr>'}</table>
 <h3 style="margin-top:18px">The record</h3><table>${facts.map(r=>`<tr><td>${E(r[0])}</td><td>${E(r[1])}</td></tr>`).join('')}</table>`;
 if((D.sales||[]).length)h+=`<h3 style="margin-top:18px">Sales and transfers</h3><table><tr><th ${TH}>Date</th><th>Price</th><th ${TH}>Seller → buyer</th></tr>${D.sales.map(s=>`<tr><td>${dt(s.sale_date)}</td><td>${s.sale_filter_less_than_10k?'under $10k':money(s.sale_price)}</td><td style="text-align:left">${E(s.seller_name||'')} → ${E(s.buyer_name||'')} <span class="lead">(${E(s.deed_type||s.mydec_deed_type||'')})</span></td></tr>`).join('')}</table>`;
 if((D.av||[]).length)h+=`<h3 style="margin-top:18px">Assessed values</h3><table><tr><th ${TH}>Year</th><th>Land</th><th>Building</th><th>Total</th></tr>${D.av.filter(v=>num(v.board_tot)>0||num(v.certified_tot)>0).map(v=>{const b=num(v.board_tot)>0,t=b?'board_':'certified_';return`<tr><td>${E(String(v.year).replace(/\.0$/,''))}</td><td>${money(v[t+'land'])}</td><td>${money(v[t+'bldg'])}</td><td>${money(v[t+'tot'])}</td></tr>`}).join('')}</table><p class="lead">${X.lake?'Outside Cook County, Illinois assesses at one-third of market value, so multiply by 3 for a rough value.':'In Cook County most homes are assessed at 10% of market value, so multiply by 10 for a rough value.'} It is a mass-appraisal estimate, not a comp. Run closed comps in the Comps stage.</p>`;
 if((D.appeals||[]).length)h+=`<p class="lead">Assessment appeals on record: ${D.appeals.map(x=>E(String(x.year).replace(/\.0$/,''))+' ('+E(x.hearing_type||'')+')').join(', ')}.</p>`;
 if((D.taxsale||[]).length)h+=`<h3 style="margin-top:18px">Tax sale history</h3><table><tr><th ${TH}>Year</th><th>Tax + penalty offered</th><th>Sold</th></tr>${D.taxsale.map(t=>`<tr><td>${E(t.tax_sale_year)}</td><td>${money(t.total_tax_and_penalty_amount_offered)}</td><td>${t.sold_at_sale?'Yes':'No (forfeited)'}</td></tr>`).join('')}</table>`;
 if((D.viol||[]).length)h+=`<h3 style="margin-top:18px">City building violations (inspectors have been inside)</h3>${D.viol.slice(0,10).map(v=>`<div class="chk" style="grid-template-columns:1fr"><div><b style="color:${/OPEN/i.test(v.violation_status)?'var(--bad)':'var(--mut)'}">${E(dt(v.violation_date))} · ${E(v.violation_status||'')}</b> · ${E(v.violation_description||'')} <span class="lead">(${E(v.inspection_category||'')}, ${E(v.inspection_status||'')})</span><div class="w">${E(v.violation_inspector_comments||'')}</div></div></div>`).join('')}`;
 if((D.permits||[]).length)h+=`<h3 style="margin-top:18px">Building permits</h3><table><tr><th ${TH}>Issued</th><th ${TH}>Type</th><th ${TH}>Work</th></tr>${D.permits.slice(0,12).map(p=>`<tr><td>${dt(p.issue_date)}</td><td style="text-align:left">${E((p.permit_type||'').replace('PERMIT - ',''))}</td><td style="text-align:left">${E((p.work_description||'').slice(0,220))}</td></tr>`).join('')}</table>`;
 h+=`<h3 style="margin-top:18px">Where to look next</h3><p class="lead">These are the sources with no free data feed. Each opens in a new tab; the PIN or name is copied first so you can paste it.</p>`+Object.entries(G).map(([g,ls])=>`<p class="lead" style="margin:10px 0 2px"><b>${E(g)}</b></p>`+ls.map(l=>`<div class="chk" style="grid-template-columns:1fr"><div><a href="#" data-u="${E(l.u)}" data-c="${E(l.cp)}" class="lkl">${E(l.t)}</a><div class="w">${E(l.w)}</div></div></div>`).join('')).join('');
 h+=`<p class="lead" style="margin-top:14px">Sources: ${D.county==='Lake'?'Lake County GIS parcel layer':'Cook County Assessor, Treasurer and Recorder open data'} (refreshed on the county\u2019s schedule)${D.isChi?', City of Chicago Data Portal':''}, FEMA NFHL. Looked up ${E(dt(D.when))}.${D.errs.length?' Unavailable right now: '+E(D.errs.join('; '))+'.':''} This is not a title search or legal advice.</p>`;
 return{h,X};
}

function textOf(D){
 const X=analyze(D),a=D.addr,c=X.ch;
 return `PROPERTY DOSSIER ${a.prop_address_full}, ${a.prop_address_city_name||''}\nPIN ${D.dash} · ${D.county} County · ${D.classText||classNote(D.cls)}\nOwner on tax bill: ${X.owner||'—'}\nTax bill mailed to: ${[a.mail_address_full,a.mail_address_city_name,a.mail_address_state].filter(Boolean).join(', ')||'—'}\nBuilt ${X.yrBuilt||'—'} · ${c.char_bldg_sf||c.char_unit_sf||'—'} sq ft · assessed ${money(X.avTot)} (rough value ${money(X.impliedValue)})\nLast sale: ${X.lastSale?dt(X.lastSale.sale_date)+' '+money(X.lastSale.sale_price):'none on record'}\n\nFLAGS\n${X.flags.map(f=>'- '+f.t+': '+f.why).join('\n')}\n\nHOW TO SEE THE INSIDE\n${insidePlan(D,X).map((s,i)=>(i+1)+'. '+s.t+' — '+s.body).join('\n')}\n`;
}

/* ---- page wiring ---- */
let LAST=null;
window.lookUI=()=>`<div class="g"><label style="grid-column:span 2">Address or PIN<input id="lkq" value="${E((S.p.addr||'')+(S.p.pin&&!S.p.addr?S.p.pin:''))}" placeholder="1060 W Addison St, Chicago, IL 60613" onkeydown="if(event.key==='Enter')lookGo()"></label></div>
 <p class="noprint"><button class="btn" onclick="lookGo()">Look up this property</button> <span id="lkmsg0" class="lead"></span></p><div id="lk">${S.dossier?'':'<p class="lead">Cook and Lake County parcels are looked up automatically. For McHenry, Kane, Winnebago and other counties the parcel data is not reachable from here; use the links in the Identify stage and type what you find.</p>'}</div>`;
window.lookBind=()=>{if(S.dossier){LAST=S.dossier;const r=render(LAST);$$('lk').innerHTML=r.h;bindLinks()}};
function bindLinks(){document.querySelectorAll('.lkl').forEach(a=>a.onclick=e=>{e.preventDefault();const cp=a.dataset.c;if(cp)try{navigator.clipboard.writeText(cp).catch(()=>{})}catch(x){}window.open(a.dataset.u,'_blank','noopener')})}
function pick(rows){return`<p class="lead">${rows.length} matching parcels. Choose one (condos and multi-unit buildings have one PIN per unit).</p>`+rows.map((r,i)=>`<div class="chk" style="grid-template-columns:1fr"><div><a href="#" onclick="lookPick(${i});return false">${E(r.prop_address_full)}, ${E(r.prop_address_city_name||'')} ${E(r.prop_address_zipcode_1||'')}</a><div class="w">${r.src==='lake'?'Lake':'Cook'} County · PIN ${E(pinFmt(r.pin))} · ${E(r.mail_address_name||'owner not listed')}</div></div></div>`).join('')}
let CAND=[];
window.lookPick=i=>run(CAND[i]);
async function run(row){const lk=$$('lk'),m=$$('lkmsg0');lk.innerHTML='<p class="lead">Pulling the record: parcel, building, values, sales, taxes, flood, city files…</p>';
 try{const D=await dossier(row);LAST=D;S.dossier=D;save();const r=render(D);lk.innerHTML=r.h;bindLinks();if(m)m.textContent=''}catch(e){lk.innerHTML=`<p class="red">Could not finish: ${E(e.message)}. Try again in a minute.</p>`}}
window.lookGo=async()=>{const lk=$$('lk'),m=$$('lkmsg0'),p=parseInput($$('lkq').value);if(p.err){lk.innerHTML=`<p class="red">${E(p.err)}</p>`;return}
 lk.innerHTML='<p class="lead">Searching Cook and Lake County parcels…</p>';
 try{const rows=await findPins(p);CAND=rows;
  if(!rows.length){lk.innerHTML=`<p class="red">No Cook or Lake County parcel matched that. Check the spelling, try without the street type ("Addison" not "Addison Ave"), or enter the PIN. Other counties are not covered yet: use the links in the Identify stage.</p>`;return}
  if(rows.length===1)run(rows[0]);else lk.innerHTML=pick(rows)}catch(e){lk.innerHTML=`<p class="red">Lookup failed: ${E(e.message)}. The county data portal may be busy; try again.</p>`}};
window.lookUse=()=>{if(!LAST)return;const D=LAST,X=analyze(D),a=D.addr,c=X.ch,sf=num(c.char_bldg_sf||c.char_unit_sf||c.char_building_sf);
 S.p.county=D.county||'Cook';S.p.addr=[a.prop_address_full,a.prop_address_city_name,'IL',a.prop_address_zipcode_1].filter(Boolean).join(', ');S.p.pin=D.dash;if(X.owner)S.p.owner=X.owner;
 if(sf&&!S.v.sqft)S.v.sqft=Math.round(sf);S.a.sit=X.guess;S.a.who=S.a.who||{};
 if(X.absentee)S.a.who.mail=[a.mail_address_full,a.mail_address_city_name,a.mail_address_state].filter(Boolean).join(', ');
 S.a.who.deed=X.owner||S.a.who.deed||'';
 save();nav();$$('lkmsg').textContent='Saved to this deal: address, PIN, owner, square feet, and the Access stage situation ('+X.guess+').'};
window.lookCopy=()=>{if(!LAST)return;navigator.clipboard.writeText(textOf(LAST)).then(()=>{$$('lkmsg').textContent='Copied.'},()=>{$$('lkmsg').textContent='Copy blocked by the browser.'})};
})();
