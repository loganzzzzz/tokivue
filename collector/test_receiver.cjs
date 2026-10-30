const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
class Sheet {
  constructor(headers){this.rows=[headers];}
  getLastRow(){return this.rows.length;}
  getMaxRows(){return 1000000;}
  getLastColumn(){return this.rows[0].length;}
  getRange(row,col,height=1,width=1){return {
    getValues:()=>this.rows.slice(row-1,row-1+height).map(r=>r.slice(col-1,col-1+width)),
    setValues:values=>{values.forEach((r,i)=>{this.rows[row-1+i]??=[];r.forEach((v,j)=>this.rows[row-1+i][col-1+j]=v);});}
  };}
}
const account='a'.repeat(64),secret='secret'.repeat(8),device='device-123';
const tables={TokenEvents:new Sheet(Array(12).fill('header')),QuotaSnapshots:new Sheet(Array(6).fill('header')),Prices:new Sheet(Array(7).fill('header'))};
const props={UPLOAD_SECRET:secret,ACCOUNT_KEY:account,SPREADSHEET_ID:'sheet'};
let held=false,failFlush=false;
const context={console,Date,Map,Set,Number,JSON,Math,
  PropertiesService:{getScriptProperties:()=>({getProperty:k=>props[k]})},
  SpreadsheetApp:{openById:()=>({getSheetByName:n=>tables[n]}),flush:()=>{if(failFlush)throw Error('lost response');}},
  ContentService:{MimeType:{JSON:'json'},createTextOutput:s=>({setMimeType:()=>JSON.parse(s)})},
  Utilities:{formatDate:(date)=>new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit'}).format(date)},
  LockService:{getScriptLock:()=>({waitLock:()=>{assert.equal(held,false);held=true;},hasLock:()=>held,releaseLock:()=>held=false})}
};
vm.createContext(context);vm.runInContext(fs.readFileSync(__dirname+'/google-apps-script/Code.gs','utf8'),context);
const event={id:'b'.repeat(64),timestamp:'2026-09-09T01:00:00Z',day:'bad-client-day',model:'test-model',input_tokens:100,cached_input_tokens:40,cache_write_input_tokens:0,output_tokens:10,reasoning_output_tokens:5,total_tokens:110};
const snapshot={id:'snapshot-123',observed_at:'2026-09-09T02:00:00Z',windows:[{limit_id:'codex',window:'primary',duration_minutes:10080,used_percent:3,resets_at:1789475971}],reset_credits:3,account_lifetime_tokens:10000};
const body={version:1,secret,account_key:account,device_id:device,device_name:'Mac',events:[event],snapshots:[snapshot]};
const send=b=>context.doPost({postData:{contents:JSON.stringify(b)}});
assert.equal(send({...body,secret:'wrong'}).ok,false);
assert.equal(tables.TokenEvents.rows.length,1);
assert.equal(send(body).ok,true);assert.equal(send(body).ok,true);
assert.equal(tables.TokenEvents.rows.length,2);assert.equal(tables.QuotaSnapshots.rows.length,2);
assert.equal(tables.TokenEvents.rows[1][4],'2026-09-09');
const duplicate={...body,device_id:'device-456',snapshots:[{...snapshot,id:'snapshot-456',observed_at:'2026-09-09T03:00:00Z',windows:[{...snapshot.windows[0],used_percent:4}]}]};
failFlush=true;assert.equal(send(duplicate).ok,false);failFlush=false;
assert.equal(send(duplicate).ok,true);assert.equal(tables.TokenEvents.rows.length,2);assert.equal(tables.QuotaSnapshots.rows.length,3);
let data=context.getDashboardData();assert.equal(data.recorded_tokens,110);assert.equal(data.quota.used_percent,4);assert.equal(data.total_cost,null);assert.equal(data.devices.length,2);
tables.Prices.rows.push(['test-model',2,0.2,10,'','source','2026-09-09']);
data=context.getDashboardData();assert.ok(Math.abs(data.total_cost-0.000228)<1e-12);
assert.equal(send({...body,events:[{...event,input_tokens:-1}]}).ok,false);
assert.equal(context.text_('=IMPORTXML("evil")',128).startsWith("'="),true);
assert.equal(held,false);
const counts=[tables.TokenEvents.rows.length,tables.QuotaSnapshots.rows.length];
const read=send({...body,events:[],snapshots:[]});
assert.equal(read.ok,true);assert.deepEqual(read.ack_ids,[]);
assert.equal(read.dashboard.quota.used_percent,4);
assert.ok(Math.abs(read.dashboard.total_cost-0.000228)<1e-12);
assert.deepEqual([tables.TokenEvents.rows.length,tables.QuotaSnapshots.rows.length],counts);
assert.equal(send({...body,events:[],snapshots:[],secret:'wrong'}).dashboard,undefined);
assert.equal(context.doGet().dashboard,undefined);
// Astra reference price: cached reads/writes and reasoning must not be charged twice.
tables.Prices.rows.push(['gpt-6-astra',10,1,50,12.5,'reference','2026-09-09']);
const astra={...event,id:'c'.repeat(64),model:'gpt-6-astra',input_tokens:1000000,
  cached_input_tokens:400000,cache_write_input_tokens:100000,output_tokens:100000,
  reasoning_output_tokens:80000,total_tokens:1100000};
assert.equal(send({...body,events:[astra],snapshots:[]}).ok,true);
data=context.getDashboardData();
assert.ok(Math.abs(data.total_cost-(11.65+0.000228))<1e-10);
assert.equal(data.recorded_tokens,1100110);
// The same token mix costs $4.66 with Sol, independently of Astra's $11.65.
tables.Prices.rows.push(['gpt-5.6-sol',4,0.4,20,5,'official','2026-09-10']);
const sol={...astra,id:'d'.repeat(64),model:'gpt-5.6-sol'};
assert.equal(send({...body,device_id:'device-456',events:[sol],snapshots:[]}).ok,true);
data=context.getDashboardData();
assert.ok(Math.abs(data.total_cost-(11.65+4.66+0.000228))<1e-10);
assert.ok(Math.abs(data.window_cost-data.total_cost)<1e-10);
assert.equal(data.recorded_tokens,2200110);
// Device costs preserve first-upload attribution and are independent of weekly totals.
const deviceRead=id=>send({...body,device_id:id,events:[],snapshots:[]}).dashboard;
assert.equal(data.current_device_cost,null);
assert.equal(deviceRead(device).current_device_id,device);
assert.ok(Math.abs(deviceRead(device).current_device_cost-(11.65+0.000228))<1e-10);
assert.ok(Math.abs(deviceRead('device-456').current_device_cost-4.66)<1e-10);
assert.equal(deviceRead('device-new').current_device_cost,0);
assert.equal(send({...body,events:[sol],snapshots:[]}).ok,true);
assert.ok(Math.abs(deviceRead(device).current_device_cost-(11.65+0.000228))<1e-10);
const historical={...astra,id:'f'.repeat(64),timestamp:'2026-09-01T01:00:00Z'};
assert.equal(send({...body,events:[historical],snapshots:[]}).ok,true);
data=deviceRead(device);
assert.ok(Math.abs(data.current_device_cost-(23.30+0.000228))<1e-10);
assert.ok(Math.abs(data.window_cost-(11.65+4.66+0.000228))<1e-10);
assert.ok(Math.abs(data.current_device_window_cost-(11.65+0.000228))<1e-10);
assert.ok(Math.abs(deviceRead('device-456').current_device_window_cost-4.66)<1e-10);
assert.equal(deviceRead('device-new').current_device_window_cost,0);
assert.equal(context.getDashboardData().current_device_window_cost,null);
// Include the window start, exclude its end, and retain both in lifetime cost.
const windowEnd=snapshot.windows[0].resets_at*1000, windowStart=windowEnd-10080*60000;
const beforeBoundaryCost=data.current_device_window_cost;
assert.equal(send({...body,events:[
  {...event,id:'1'.repeat(64),timestamp:new Date(windowStart).toISOString()},
  {...event,id:'2'.repeat(64),timestamp:new Date(windowEnd).toISOString()}
],snapshots:[]}).ok,true);
assert.ok(Math.abs(deviceRead(device).current_device_window_cost-beforeBoundaryCost-0.000228)<1e-10);
// Luna remains in token totals but contributes neither cost nor missing-price errors.
const beforeLuna=deviceRead(device);
const luna={...astra,id:'4'.repeat(64),model:'gpt-5.6-luna'};
assert.equal(send({...body,events:[luna],snapshots:[]}).ok,true);
let afterLuna=deviceRead(device);
for(const key of ['total_cost','window_cost','current_device_cost','current_device_window_cost','missing_prices'])
  assert.equal(afterLuna[key],beforeLuna[key],key);
assert.equal(afterLuna.recorded_tokens,beforeLuna.recorded_tokens+luna.total_tokens);
assert.equal(afterLuna.excluded_cost_events,1);
// Exclusion is explicit even if someone later configures a price for Luna.
tables.Prices.rows.push(['gpt-5.6-luna',100,10,500,125,'unused','2026-09-22']);
assert.equal(send({...body,device_id:'device-luna-only',events:[{...luna,id:'5'.repeat(64)}],snapshots:[]}).ok,true);
afterLuna=deviceRead(device);
assert.equal(afterLuna.total_cost,beforeLuna.total_cost);
assert.equal(afterLuna.excluded_cost_events,2);
assert.equal(deviceRead('device-luna-only').current_device_cost,0);
assert.equal(deviceRead('device-luna-only').current_device_window_cost,0);
// Missing exact model prices remain unknown instead of falling back to Astra.
tables.Prices.rows.push(['unmapped-model','','','','','','']);
assert.equal(send({...body,events:[{...historical,id:'3'.repeat(64),model:'unmapped-model'}],snapshots:[]}).ok,true);
assert.equal(deviceRead(device).current_device_cost,null);
assert.ok(Math.abs(deviceRead(device).current_device_window_cost-beforeBoundaryCost-0.000228)<1e-10);
assert.equal(send({...body,events:[{...sol,id:'e'.repeat(64),model:'unmapped-model'}],snapshots:[]}).ok,true);
data=context.getDashboardData();assert.equal(data.total_cost,null);assert.equal(data.missing_prices,2);
assert.equal(deviceRead(device).current_device_cost,null);
assert.equal(deviceRead(device).current_device_window_cost,null);
assert.ok(Math.abs(deviceRead('device-456').current_device_cost-4.66)<1e-10);
assert.ok(Math.abs(deviceRead('device-456').current_device_window_cost-4.66)<1e-10);
// The next quota window resets device weekly usage without losing its lifetime history.
assert.equal(send({...body,events:[],snapshots:[{...snapshot,id:'snapshot-next-week',observed_at:'2026-09-16T01:00:00Z',windows:[{...snapshot.windows[0],resets_at:snapshot.windows[0].resets_at+10080*60}]}]}).ok,true);
assert.ok(Math.abs(deviceRead(device).current_device_window_cost-0.000228)<1e-10);
assert.equal(deviceRead('device-456').current_device_window_cost,0);
assert.ok(Math.abs(deviceRead('device-456').current_device_cost-4.66)<1e-10);
console.log('Receiver checks passed: authentication, idempotency, partial-write retry, latest quota, price gaps, cost math, device attribution, historical costs, validation.');

// Shared dashboard must stay on its selected device when another device uploads.
const overviewCells={'K23':'device-456'};
tables['用量看板']={getRange:range=>({getValue:()=>overviewCells[range],setValue:value=>{overviewCells[range]=value;},setValues:values=>{overviewCells[range]=values;}})};
const response=send({...body,events:[],snapshots:[]});
assert.equal(response.ok,true);
assert.equal(response.dashboard.current_device_id,device);
assert.ok(Math.abs(response.dashboard.current_device_window_cost-0.000228)<1e-10);
assert.equal(overviewCells['K24:K25'][0][0],0);
assert.ok(Math.abs(overviewCells['K24:K25'][1][0]-4.66)<1e-10);
assert.equal(overviewCells.K23,'device-456');
overviewCells.K23=device;
context.refreshOverview_({getSheetByName:n=>tables[n]},device);
assert.ok(Math.abs(overviewCells['K24:K25'][0][0]-0.000228)<1e-10);
assert.equal(overviewCells['K24:K25'][1][0],'');
console.log('Shared sheet selected-device persistence and price-gap checks passed.');

// September prices: GPT-6 Sol is half the GPT-5.6 Sol price; exclusions retain tokens.
tables.TokenEvents.rows=tables.TokenEvents.rows.slice(0,1);
tables.Prices.rows.push(['gpt-6-sol',2,0.2,10,2.5,'official','2026-09-28']);
const newSol={...astra,id:'6'.repeat(64),model:'gpt-6-sol'};
assert.equal(send({...body,events:[newSol],snapshots:[]}).ok,true);
let current=deviceRead(device);
assert.ok(Math.abs(current.current_device_cost-2.33)<1e-10);
const beforeExcluded=current.recorded_tokens;
assert.equal(send({...body,events:[
  {...astra,id:'7'.repeat(64),model:'gpt-6-luna'},
  {...astra,id:'8'.repeat(64),model:'codex-auto-review'}
],snapshots:[]}).ok,true);
current=deviceRead(device);
assert.ok(Math.abs(current.current_device_cost-2.33)<1e-10);
assert.equal(current.recorded_tokens,beforeExcluded+2*astra.total_tokens);
assert.equal(current.missing_prices,0);
assert.equal(current.excluded_cost_events,2);
console.log('September GPT-6 Sol pricing and Luna/auto-review exclusions passed.');

// Imagegen completions: separate counts, estimated output cost, stable cross-device dedup.
tables.ImageEvents=new Sheet(['event_id','account_key','first_device_id','timestamp','beijing_date','source','status','usage_status','width','height']);
const beforeImages=deviceRead(device);
const imageEvent={id:'image-event-123',timestamp:'2026-09-16T02:00:00Z',source:'imagegen',status:'completed',usage_status:'unavailable',width:1024,height:1024};
const imageBody={...body,events:[],snapshots:[],image_events:[imageEvent]};
let imageResponse=send(imageBody);assert.equal(imageResponse.ok,true);assert.deepEqual(imageResponse.ack_ids,['image-event-123']);
assert.equal(send({...imageBody,device_id:'device-456'}).ok,true);
let afterImages=deviceRead(device);
assert.equal(afterImages.image_stats.total_success,1);
assert.equal(afterImages.image_stats.estimated_output_tokens,439);
assert.ok(Math.abs(afterImages.image_stats.estimated_output_cost-.01317)<1e-12);
assert.equal(afterImages.recorded_tokens,beforeImages.recorded_tokens);
assert.ok(Math.abs(afterImages.current_device_cost-beforeImages.current_device_cost-.01317)<1e-10);
assert.ok(Math.abs(afterImages.current_device_window_cost-beforeImages.current_device_window_cost-.01317)<1e-10);
assert.equal(deviceRead('device-456').current_device_cost,0);
assert.equal(send({...imageBody,image_events:[{...imageEvent,id:'image-unknown-size',width:null,height:null}]}).ok,true);
afterImages=deviceRead(device);assert.equal(afterImages.image_stats.total_success,2);assert.equal(afterImages.image_stats.pending_pricing,1);
assert.equal(afterImages.image_stats.estimated_output_tokens,439);
assert.equal(send({...imageBody,image_events:[{...imageEvent,status:'failed'}]}).ok,false);
assert.equal(send({...imageBody,image_events:[{...imageEvent,width:-1}]}).ok,false);
assert.equal(send({...imageBody,image_events:'bad'}).ok,false);
assert.equal(context.imageOutputEstimate_(3841,1024),null);
assert.equal(context.imageOutputEstimate_(100,100),null);
assert.deepEqual(context.imageOutputEstimate_(1086,1448),context.imageOutputEstimate_(1088,1456));
assert.equal(context.imageOutputEstimate_(2048,2048).tokens,892);
assert.equal(overviewCells.B34,'成功生图：今日 0 次 · 累计 2 次');
assert.match(overviewCells.B35,/1 次待计价/);
console.log('Image counts, output-only estimates, missing sizes, validation and cross-device dedup passed.');
// GPT-6.1 Sol cache reads are $0.10/M, independently of GPT-6 Sol's $0.20/M.
tables.Prices.rows.push(['gpt-6.1-sol',2,0.1,10,2.5,'official','2026-10-09']);
const before61=deviceRead(device).current_device_cost;
assert.equal(send({...body,events:[{...astra,id:'sol61-event-123',model:'gpt-6.1-sol'}],snapshots:[]}).ok,true);
assert.ok(Math.abs(deviceRead(device).current_device_cost-before61-2.29)<1e-10);
console.log('GPT-6.1 Sol independent cached-read price passed.');
