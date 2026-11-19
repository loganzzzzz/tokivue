const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const headers=['model','input_usd_per_million','cached_input_usd_per_million','output_usd_per_million','cache_write_usd_per_million','source_url','verified_on'];
const official='https://developers.openai.com/api/docs/pricing';
const fixture=fs.readFileSync(__dirname+'/tests/fixtures/official-standard-pricing.md','utf8');
class Sheet {
 constructor(){this.cells=new Map();this.formulas=new Map();this.maxRows=1000;}
 getLastRow(){return Math.max(0,...[...this.cells.keys(),...this.formulas.keys()].map(k=>Number(k.split(',')[0])));}
 getMaxRows(){return this.maxRows;}
 insertRowsAfter(_,n){this.maxRows+=n;}
 setFrozenRows(){}
 getRange(r,c,h=1,w=1){
  if(typeof r==='string') {
   const named={'A2:G2':[2,1,1,7],'B2:G2':[2,2,1,6],'A:A':[1,1,1000,1],'B:G':[1,2,1000,6]};
   assert.ok(named[r],r);[r,c,h,w]=named[r];
  }
  const sheet=this;return {
   getValues(){return Array.from({length:h},(_,i)=>Array.from({length:w},(_,j)=>sheet.cells.get([r+i,c+j].join(','))??''));},
   getFormulas(){return Array.from({length:h},(_,i)=>Array.from({length:w},(_,j)=>sheet.formulas.get([r+i,c+j].join(','))??''));},
   setValues(v){assert.equal(v.length,h);v.forEach((row,i)=>{assert.equal(row.length,w);row.forEach((x,j)=>sheet.cells.set([r+i,c+j].join(','),x));});return this;},
   setFormulas(v){v.forEach((row,i)=>row.forEach((x,j)=>sheet.formulas.set([r+i,c+j].join(','),x)));return this;},
   setNumberFormat(){return this;},copyFormatToRange(){},
   insertCells(){for(const map of [sheet.cells,sheet.formulas]){for(const [k,v] of [...map].sort((a,b)=>Number(b[0].split(',')[0])-Number(a[0].split(',')[0]))){const [row,col]=k.split(',').map(Number);if(row>=r&&col>=c&&col<c+w){map.delete(k);map.set([row+h,col].join(','),v);}}}}
  };
 }
}
let props={},sheets={},triggers=[],fetches=0,status=200,document=fixture,refreshes=0,held=false;
const ctx={console,Date,Map,Set,Number,JSON,Math,Utilities:{sleep(){}},
 PropertiesService:{getScriptProperties:()=>({getProperty:k=>props[k]??null,setProperty:(k,v)=>props[k]=v,setProperties:o=>Object.assign(props,o),deleteProperty:k=>delete props[k]})},
 SpreadsheetApp:{Dimension:{ROWS:'ROWS'},openById:()=>({getSheetByName:n=>sheets[n],insertSheet:n=>(sheets[n]=new Sheet())}),flush(){}},
 UrlFetchApp:{fetch:(url,options)=>{assert.equal(url,official+'.md');assert.equal(options.followRedirects,false);fetches++;return{getResponseCode:()=>status,getContentText:()=>document};}},
 LockService:{getScriptLock:()=>({waitLock:()=>{assert.equal(held,false);held=true;},releaseLock:()=>held=false})},
 ScriptApp:{getProjectTriggers:()=>triggers,newTrigger:name=>({timeBased:()=>({everyHours:h=>{assert.equal(h,6);return{create:()=>triggers.push({getHandlerFunction:()=>name})};}})}),deleteTrigger:t=>triggers.splice(triggers.indexOf(t),1)}
};
vm.createContext(ctx);vm.runInContext(fs.readFileSync(__dirname+'/google-apps-script/Code.gs','utf8'),ctx);
vm.runInContext(fs.readFileSync(__dirname+'/google-apps-script/AutoPricing.gs','utf8'),ctx);ctx.refreshOverview_=()=>refreshes++;
const plain=x=>JSON.parse(JSON.stringify(x));
const parsed=plain(ctx.parseOfficialPrices_(fixture));
assert.deepEqual(parsed.find(x=>x[0]==='gpt-6.2-astra'),['gpt-6.2-astra',8,.4,40,10]);
assert.deepEqual(parsed.find(x=>x[0]==='gpt-6.2-sol'),['gpt-6.2-sol',2,.1,10,2.5]);
assert.ok(!parsed.some(r=>r[0].includes('luna')));
assert.deepEqual(plain(ctx.parseOfficialPrices_(fixture,'Fast')).find(r=>r[0]==='gpt-6.2-astra'),['gpt-6.2-astra',16,.8,80,20]);
assert.ok(!ctx.parseOfficialPrices_(fixture.replaceAll('gpt-6-luna','gpt-6.2-luna')).some(r=>r[0]==='gpt-6.2-luna'));
assert.throws(()=>ctx.parseOfficialPrices_(fixture.replace('### Fast pricing data','### Changed pricing data'),'Fast'));
for(const bad of [fixture.replace('### Standard pricing data','### Fast pricing data'),fixture.replace('Short context 30m write','Short context 12h write'),fixture.replace('$8.00','€8.00'),fixture.replace('$8.00','$-8.00'),fixture.replace('| gpt-6.2-sol |', '| gpt-6.2-astra |')]) assert.throws(()=>ctx.parseOfficialPrices_(bad));
assert.ok(!ctx.parseOfficialPrices_(fixture.replace('$0.40','-')).some(r=>r[0]==='gpt-6.2-astra'));
function reset(formula=false){props={SPREADSHEET_ID:'test-sheet'};sheets={Prices:new Sheet()};triggers=[];fetches=0;status=200;document=fixture;refreshes=0;held=false;const s=sheets.Prices;s.getRange(1,1,1,7).setValues([headers]);
 if(formula){s.getRange('A2:G2').setFormulas([['=IFERROR(SORT(UNIQUE(FILTER(TokenEvents!F2:F,TokenEvents!F2:F<>""))),"")',...Array.from({length:6},(_,i)=>'=ARRAYFORMULA(IF(A2:A="","",IFNA(VLOOKUP(A2:A,$J$2:$P$2,'+(i+2)+',FALSE),"")))')]]);s.getRange(2,10,1,7).setValues([['gpt-6.2-astra',8,.4,40,10,official,'2026-11-18']]);s.getRange(3,10,1,2).setValues([['Notes','retain this note']]);}
}
reset();ctx.enableAutoPricing();assert.equal(triggers.length,1);assert.equal(refreshes,1);let s=sheets.Prices;
assert.equal(s.getLastRow(),parsed.length+1);const count=s.getLastRow();ctx.enableAutoPricing();assert.equal(triggers.length,1);assert.equal(s.getLastRow(),count);
let astraRow=2;s.getRange(astraRow,2).setValues([[7]]);document=fixture.replace('$8.00','$9.00');ctx.autoUpdateModelPrices();assert.equal(s.getRange(astraRow,2).getValues()[0][0],7,'manual change preserved');
// Restore the last automatically managed value to opt in again.
s.getRange(astraRow,2).setValues([[8]]);ctx.autoUpdateModelPrices();assert.equal(s.getRange(astraRow,2).getValues()[0][0],9);
assert.ok([...sheets.PriceUpdateLog.cells.values()].includes('UPDATE'));assert.ok([...sheets.PriceUpdateLog.cells.values()].includes('MANUAL'));
const stable=JSON.stringify([...s.cells]);status=503;assert.throws(()=>ctx.autoUpdateModelPrices());assert.equal(JSON.stringify([...s.cells]),stable);assert.match(props.TOKIVUE_PRICE_LAST_ERROR,/503/);status=200;document='broken';assert.throws(()=>ctx.autoUpdateModelPrices());assert.equal(JSON.stringify([...s.cells]),stable);
document=fixture.replace('### Fast pricing data','### Invalid Fast data');assert.throws(()=>ctx.autoUpdateModelPrices());assert.equal(JSON.stringify([...s.cells]),stable);
ctx.disableAutoPricing();const f=fetches;ctx.autoUpdateModelPrices();assert.equal(fetches,f);assert.equal(triggers.length,0);
reset(true);ctx.enableAutoPricing();s=sheets.Prices;const end=parsed.length+1;assert.equal(s.getRange(end+1,10,1,2).getValues()[0][1],'retain this note');assert.ok(s.getRange('B2:G2').getFormulas()[0].every(x=>x.includes('$J$2:$P$'+end)));ctx.enableAutoPricing();assert.equal(s.getRange(end+1,10,1,2).getValues()[0][1],'retain this note');
reset();s=sheets.Prices;s.getRange(2,1,1,7).setValues([['gpt-6.2-astra',99,1,99,1,'https://example.com/custom','']]);ctx.enableAutoPricing();assert.equal(s.getRange(2,2).getValues()[0][0],99);
reset();status=503;assert.throws(()=>ctx.enableAutoPricing());assert.equal(triggers.length,1,'transient first-fetch failure keeps retry trigger');
console.log('Auto pricing checks passed: strict tier/column parsing, real fixture, exclusions, new models, updates, manual overrides, failures, disable/re-enable, idempotency, formula expansion and note preservation.');

reset();let failures=0;const originalOpen=ctx.SpreadsheetApp.openById;
ctx.SpreadsheetApp.openById=(...args)=>{if(failures++===0)throw new Error('Spreadsheet service timed out');return originalOpen(...args);};
ctx.enableAutoPricing();assert.ok(props.TOKIVUE_PRICE_LAST_SUCCESS);assert.equal(triggers.length,1);assert.equal(props.TOKIVUE_PRICE_LAST_ERROR,undefined);
ctx.SpreadsheetApp.openById=originalOpen;
reset();status=503;assert.throws(()=>ctx.enableAutoPricing());assert.equal(fetches,3,'transient failures are bounded to three attempts');
reset();document='changed format';assert.throws(()=>ctx.enableAutoPricing());assert.equal(fetches,1,'schema failures are not retried');
console.log('Bounded transient retries and non-retryable schema failures passed.');

reset();sheets.FastPrices=new Sheet();ctx.enableAutoPricing();assert.deepEqual(plain(sheets.FastPrices.getRange(1,1,1,7).getValues()[0]),headers);assert.ok(sheets.FastPrices.getLastRow()>1);
console.log("Partially created empty price tabs recover on retry.");
