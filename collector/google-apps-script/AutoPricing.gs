/** Optional cloud-only updater. Run enableAutoPricing once after authorization. */
const OFFICIAL_PRICE_URL = 'https://developers.openai.com/api/docs/pricing.md';
const OFFICIAL_PRICE_SOURCE = 'https://developers.openai.com/api/docs/pricing';
const AUTO_PRICE_PREFIX = 'TOKIVUE_AUTO_PRICE_';
const PRICE_LOG_HEADERS = ['checked_at','status','model','old_prices','new_prices','source','message'];

function parseOfficialPrices_(markdown, tier='Standard') {
  if(!['Standard','Fast'].includes(tier))throw new Error('Unsupported pricing tier');
  if (typeof markdown !== 'string' || markdown.length > 2000000) throw new Error('Invalid pricing document');
  const heading = new RegExp('^### '+tier+' pricing data\\s*$','m').exec(markdown);
  if (!heading) throw new Error('Standard pricing section missing');
  const section = markdown.slice(heading.index + heading[0].length).split(/^### /m)[0];
  const lines = section.split(/\r?\n/).filter(l=>l.trim().startsWith('|'));
  const split = l=>l.trim().replace(/^\||\|$/g,'').split('|').map(x=>x.trim());
  const expected = ['Model','Short context input','Short context output','Short context cached input',
    'Short context 30m write','Short context 12h write','Long context input','Long context output',
    'Long context cached input','Long context 30m write','Long context 12h write'];
  if (!lines.length || JSON.stringify(split(lines[0]))!==JSON.stringify(expected)) throw new Error('Pricing columns changed');
  if(!lines[1] || split(lines[1]).length!==11 || !split(lines[1]).every(v=>/^:?-+:?$/.test(v)))throw new Error('Pricing table separator changed');
  const money = text=> {
    if (text==='-') return '';
    if (!/^\$\d+(?:\.\d+)?$/.test(text)) throw new Error('Invalid USD price');
    const n=Number(text.slice(1));
    if (!Number.isFinite(n) || n<0 || n>100000) throw new Error('Price out of range');
    return n;
  };
  const result=[],seen=new Set();
  for (const line of lines.slice(2)) {
    const cells=split(line);
    if (cells[0]==='Model') break; // A different table requires a separate parser.
    if (cells.length!==11) throw new Error('Malformed Standard price row');
    const [model,input,output,cached,write]=cells;
    // Only exact model IDs with this explicitly supported billing schema.
    if (!/^gpt-[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(model)) continue;
    if (seen.has(model)) throw new Error('Duplicate model in official table');
    seen.add(model);
    const values=[money(input),money(cached),money(output),money(write)];
    if (values.slice(0,3).some(v=>v==='')) continue; // Never turn unknown rates into zero.
    if (!excludedCostModel_(model)) result.push([model,...values]);
  }
  if (result.length<2 || result.length>100) throw new Error('Unexpected model count');
  return result;
}

function autoPriceDecision_(current, previous, official) {
  if (!current) return 'add';
  const fingerprint = JSON.stringify(current.slice(1,6));
  const proposed = JSON.stringify(official.slice(1,6));
  if (fingerprint===proposed) return previous===null ? 'adopt':'unchanged';
  if (previous!==null && fingerprint===previous) return 'update';
  // Unrecognized existing values and edits since our last write remain manual.
  return 'manual';
}

function autoPriceLayout_(sheet) {
  const formulas=sheet.getRange('A2:G2').getFormulas()[0];
  if (!formulas.some(Boolean)) return {column:1,rows:Math.max(0,sheet.getLastRow()-1),formulas:null};
  if (formulas[0]!=='=IFERROR(SORT(UNIQUE(FILTER(TokenEvents!F2:F,TokenEvents!F2:F<>""))),"")') throw new Error('Unsupported Prices layout');
  const ends=formulas.slice(1).map(f=> {
    const match=/\$J\$2:\$P\$(\d+)/.exec(f);
    if (!f.startsWith('=ARRAYFORMULA(') || !match) throw new Error('Unsupported price lookup');
    return Number(match[1]);
  });
  if (!ends.every(n=>n===ends[0]) || ends[0]<2 || ends[0]>500) throw new Error('Inconsistent price lookups');
  return {column:10,rows:ends[0]-1,formulas};
}

function autoPriceLog_(ss, rows) {
  let sheet=ss.getSheetByName('PriceUpdateLog');
  if (!sheet) sheet=ss.insertSheet('PriceUpdateLog');
  if (!sheet.getLastRow()) {
    sheet.getRange(1,1,1,7).setValues([PRICE_LOG_HEADERS]);sheet.setFrozenRows(1);
    sheet.getRange('A:A').setNumberFormat('yyyy-mm-dd hh:mm:ss');
    sheet.getRange('B:G').setNumberFormat('@');
  } else if (JSON.stringify(sheet.getRange(1,1,1,7).getValues()[0])!==JSON.stringify(PRICE_LOG_HEADERS)) {
    throw new Error('Unexpected PriceUpdateLog headers');
  }
  const required=sheet.getLastRow()+rows.length;
  if (required>sheet.getMaxRows()) sheet.insertRowsAfter(sheet.getMaxRows(),required-sheet.getMaxRows());
  sheet.getRange(sheet.getLastRow()+1,1,rows.length,7).setValues(rows);
}

function autoUpdateModelPrices() {
  const props=PropertiesService.getScriptProperties();
  if (props.getProperty('TOKIVUE_AUTO_PRICING_ENABLED')!=='true') return;
  const lock=LockService.getScriptLock();
  let locked=false,ss;
  const now=new Date();
  try {
    // No secrets, account IDs, usage data or cookies are sent to the pricing site.
    const response=UrlFetchApp.fetch(OFFICIAL_PRICE_URL,{followRedirects:false,muteHttpExceptions:true});
    if (response.getResponseCode()!==200) throw new Error('Official pricing HTTP '+response.getResponseCode());
    const document=response.getContentText();
    const parsed=parseOfficialPrices_(document);
    const fast=parseOfficialPrices_(document,'Fast');
    lock.waitLock(25000);locked=true;
    if (props.getProperty('TOKIVUE_AUTO_PRICING_ENABLED')!=='true') return;
    ss=SpreadsheetApp.openById(props.getProperty('SPREADSHEET_ID'));
    const sheet=ss.getSheetByName('Prices');
    if (!sheet || JSON.stringify(sheet.getRange(1,1,1,7).getValues()[0])!==JSON.stringify(PRICE_HEADERS)) throw new Error('Unexpected Prices headers');
    const layout=autoPriceLayout_(sheet);
    const rows=layout.rows ? sheet.getRange(2,layout.column,layout.rows,7).getValues():[];
    const formulas=layout.rows ? sheet.getRange(2,layout.column,layout.rows,7).getFormulas():[];
    const existing=new Map();
    rows.forEach((r,i)=> {
      if (!r[0]) return;
      if (existing.has(r[0])) throw new Error('Duplicate model in local Prices');
      existing.set(r[0],{row:i+2,values:r,hasFormula:formulas[i].some(Boolean)});
    });
    // Decide everything before touching the price table.
    const plan=parsed.map(r=> {
      const official=[...r,OFFICIAL_PRICE_SOURCE,now],old=existing.get(r[0]);
      const decision=old && old.hasFormula ? 'manual':autoPriceDecision_(old?.values || null,props.getProperty(AUTO_PRICE_PREFIX+r[0]),official);
      return {official,old,decision};
    });
    const additions=plan.filter(p=>p.decision==='add').length;
    autoPriceLog_(ss,[[now,'CHECK','','','',OFFICIAL_PRICE_SOURCE,'Parsed '+parsed.length+' supported models']]);
    if (additions && layout.formulas) {
      sheet.getRange(layout.rows+2,10,additions,7).insertCells(SpreadsheetApp.Dimension.ROWS);
    } else if (layout.rows+1+additions>sheet.getMaxRows()) {
      sheet.insertRowsAfter(sheet.getMaxRows(),layout.rows+1+additions-sheet.getMaxRows());
    }
    let nextRow=layout.rows+2;
    const log=[],state={};
    for (const item of plan) {
      const {official,old,decision}=item;
      if (decision==='manual') {
        log.push([now,'MANUAL',official[0],JSON.stringify(old.values.slice(1,5)),JSON.stringify(official.slice(1,5)),OFFICIAL_PRICE_SOURCE,'Custom price preserved']);
        continue;
      }
      if (decision==='add' || decision==='update') {
        const row=old ? old.row:nextRow++;
        if (!old && layout.rows) sheet.getRange(2,layout.column,1,7).copyFormatToRange(sheet,layout.column,layout.column+6,row,row);
        sheet.getRange(row,layout.column,1,7).setValues([official]);
        sheet.getRange(row,layout.column+1,1,4).setNumberFormat('0.0000');
        sheet.getRange(row,layout.column+6).setNumberFormat('yyyy-mm-dd');
        log.push([now,decision.toUpperCase(),official[0],old ? JSON.stringify(old.values.slice(1,5)):'',JSON.stringify(official.slice(1,5)),OFFICIAL_PRICE_SOURCE,'Standard / short / 30m write']);
      }
      state[AUTO_PRICE_PREFIX+official[0]]=JSON.stringify(official.slice(1,6));
    }
    if (layout.formulas && additions) {
      sheet.getRange('B2:G2').setFormulas([layout.formulas.slice(1).map(f=>f.replace(/\$J\$2:\$P\$\d+/g,'$J$2:$P$'+(layout.rows+1+additions)))]);
    }
    syncFastPrices_(ss,fast,props,now);
    SpreadsheetApp.flush();
    props.setProperties(state,false);
    if (log.length) autoPriceLog_(ss,log);
    props.setProperty('TOKIVUE_PRICE_LAST_SUCCESS',now.toISOString());
    props.deleteProperty('TOKIVUE_PRICE_LAST_ERROR');
    refreshOverview_(ss);SpreadsheetApp.flush();
  } catch (error) {
    // Never log a response body; failures preserve existing prices when validation fails.
    props.setProperty('TOKIVUE_PRICE_LAST_ERROR',now.toISOString()+' '+String(error.message).slice(0,180));
    if (!locked) {lock.waitLock(25000);locked=true;}
    ss=ss || SpreadsheetApp.openById(props.getProperty('SPREADSHEET_ID'));
    autoPriceLog_(ss,[[now,'ERROR','','','',OFFICIAL_PRICE_SOURCE,String(error.message).slice(0,180)]]);
    throw error;
  } finally {if (locked) lock.releaseLock();}
}

function enableAutoPricing() {
  const props=PropertiesService.getScriptProperties();
  if (!props.getProperty('SPREADSHEET_ID')) throw new Error('Run setup first');
  props.setProperty('TOKIVUE_AUTO_PRICING_ENABLED','true');
  // Register before fetching: transient network errors must not disable future retries.
  const triggers=ScriptApp.getProjectTriggers().filter(t=>t.getHandlerFunction()==='autoUpdateModelPrices');
  if (!triggers.length) ScriptApp.newTrigger('autoUpdateModelPrices').timeBased().everyHours(6).create();
  triggers.slice(1).forEach(t=>ScriptApp.deleteTrigger(t));
  autoUpdateModelPrices();
}

function disableAutoPricing() {
  PropertiesService.getScriptProperties().setProperty('TOKIVUE_AUTO_PRICING_ENABLED','false');
  ScriptApp.getProjectTriggers().filter(t=>t.getHandlerFunction()==='autoUpdateModelPrices').forEach(t=>ScriptApp.deleteTrigger(t));
}


function syncFastPrices_(ss,parsed,props,now) {
  let sheet=ss.getSheetByName('FastPrices');
  if(!sheet){sheet=ss.insertSheet('FastPrices');sheet.getRange(1,1,1,7).setValues([PRICE_HEADERS]);sheet.setFrozenRows(1);}
  if(JSON.stringify(sheet.getRange(1,1,1,7).getValues()[0])!==JSON.stringify(PRICE_HEADERS))throw new Error('Unexpected FastPrices headers');
  const count=Math.max(0,sheet.getLastRow()-1),rows=count?sheet.getRange(2,1,count,7).getValues():[],formulas=count?sheet.getRange(2,1,count,7).getFormulas():[];
  const existing=new Map();rows.forEach((r,i)=>{if(!r[0])return;if(existing.has(r[0]))throw new Error('Duplicate Fast model');existing.set(r[0],{row:i+2,values:r,hasFormula:formulas[i].some(Boolean)});});
  const plan=parsed.map(r=>{const official=[...r,OFFICIAL_PRICE_SOURCE,now],old=existing.get(r[0]);const key=AUTO_PRICE_PREFIX+'FAST_'+r[0];return{official,old,key,decision:old?.hasFormula?'manual':autoPriceDecision_(old?.values||null,props.getProperty(key),official)};});
  let next=sheet.getLastRow()+1;const logs=[],state={};
  const required=next+plan.filter(p=>p.decision==='add').length-1;
  if(required>sheet.getMaxRows())sheet.insertRowsAfter(sheet.getMaxRows(),required-sheet.getMaxRows());
  for(const p of plan){
    const {official,old,decision,key}=p;
    if(['add','update'].includes(decision)){
      const row=old?old.row:next++;sheet.getRange(row,1,1,7).setValues([official]);sheet.getRange(row,2,1,4).setNumberFormat('0.0000');sheet.getRange(row,7).setNumberFormat('yyyy-mm-dd');
    }
    if(decision!=='manual')state[key]=JSON.stringify(official.slice(1,6));
    if(['add','update','manual'].includes(decision))logs.push([now,decision.toUpperCase(),official[0],old?JSON.stringify(old.values.slice(1,5)):'',JSON.stringify(official.slice(1,5)),OFFICIAL_PRICE_SOURCE,'Fast tier']);
  }
  SpreadsheetApp.flush();props.setProperties(state,false);if(logs.length)autoPriceLog_(ss,logs);
}

function enableTokivueAutomation() { enableModelRankings(); enableAutoPricing(); }
