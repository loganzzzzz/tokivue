/** Bound Google Sheets receiver. Store secrets in Script Properties, never in cells. */
const EVENT_HEADERS = ['event_id','account_key','first_device_id','timestamp','beijing_date','model',
  'input_tokens','cached_input_tokens','cache_write_input_tokens','output_tokens','reasoning_output_tokens','total_tokens'];
const SNAP_HEADERS = ['snapshot_id','account_key','device_id','device_name','observed_at','snapshot_json'];
const PRICE_HEADERS = ['model','input_usd_per_million','cached_input_usd_per_million',
  'output_usd_per_million','cache_write_usd_per_million','source_url','verified_on'];
// User-requested valuation exclusion; token records and official quota remain intact.
const EXCLUDED_COST_MODELS = new Set(['gpt-5.6-luna', 'gpt-6-luna', 'codex-auto-review']);
const IMAGE_HEADERS = ['event_id','account_key','first_device_id','timestamp','beijing_date',
  'source','status','usage_status','width','height'];

// User-selected assumption; this is output-only API-equivalent cost, not measured usage.
function imageOutputEstimate_(width, height) {
  if (![width,height].every(v=>Number.isSafeInteger(v) && v>0 && v<=20000)) return null;
  const w=Math.ceil(width/16)*16, h=Math.ceil(height/16)*16;
  if (Math.max(w,h)>3840 || Math.max(w,h)/Math.min(w,h)>3 || w*h<655360 || w*h>8294400) return null;
  const shortSide=24*Math.min(w,h)/Math.max(w,h), floor=Math.floor(shortSide);
  const grid=shortSide-floor===0.5 ? floor+floor%2 : Math.round(shortSide);
  const tokens=Math.ceil(24*grid*(2000000+w*h)/4000000);
  return {tokens,cost:tokens*30/1000000};
}

function enableImageGenerationStats() {
  const lock=LockService.getScriptLock();lock.waitLock(25000);
  try {
    const ss=SpreadsheetApp.openById(PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID'));
    let images=ss.getSheetByName('ImageEvents');
    if (!images) images=ss.insertSheet('ImageEvents');
    if (images.getLastRow()===0) {
      images.getRange(1,1,1,IMAGE_HEADERS.length).setValues([IMAGE_HEADERS])
        .setBackground('#e8eef8').setFontWeight('bold');
      images.setFrozenRows(1);images.getRange('A:H').setNumberFormat('@');
      images.getRange('I:J').setNumberFormat('0');
    } else if(JSON.stringify(images.getRange(1,1,1,IMAGE_HEADERS.length).getValues()[0])!==JSON.stringify(IMAGE_HEADERS)) {
      throw new Error('Unexpected ImageEvents schema');
    }
    const s=ss.getSheetByName('用量看板');
    s.getRange('B34:G34').merge().setBackground('#ffffff').setFontColor('#007aff').setFontSize(10).setHorizontalAlignment('center');
    s.getRange('B35:G36').merge().setBackground('#f2f2f7').setFontColor('#6e6e73').setFontSize(9).setWrap(true).setHorizontalAlignment('center');
    s.getRange('B32').setValue('API 等价估值 · 未含 Luna 与自动审核');
    refreshOverview_(ss);SpreadsheetApp.flush();
  } finally { lock.releaseLock(); }
}

function updateSol61Pricing() {
  const lock=LockService.getScriptLock();lock.waitLock(25000);
  try {
    const ss=SpreadsheetApp.openById(PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID'));
    const p=ss.getSheetByName('Prices');
    if(p.getRange('J5').getValue()!=='gpt-6.1-sol') {
      if(p.getRange('J5').getValue()!=='估值口径') throw new Error('Unexpected price-table layout');
      p.getRange('J5:P5').insertCells(SpreadsheetApp.Dimension.ROWS);
    }
    p.getRange('J5:P5').setValues([['gpt-6.1-sol',2,0.1,10,2.5,
      'https://developers.openai.com/api/docs/pricing',new Date('2026-10-09T00:00:00+08:00')]]);
    p.getRange('K5:N5').setNumberFormat('0.0000');p.getRange('P5').setNumberFormat('yyyy-mm-dd');
    p.getRange('B2:G2').setFormulas([Array.from({length:6},(_,i)=> {
      const lookup=`VLOOKUP(A2:A,$J$2:$P$5,${i+2},FALSE)`;
      return `=ARRAYFORMULA(IF(A2:A="","",IFNA(${i===5 ? `TEXT(${lookup},"yyyy-mm-dd")` : lookup},"")))`;
    })]);
    p.getRange('K8').setValue('排除 Luna 与自动审核；生图按 Image 2.5 medium 估算输出；未含长上下文、Fast、区域附加费');
    SpreadsheetApp.flush();refreshOverview_(ss);SpreadsheetApp.flush();
  } finally {lock.releaseLock();}
}

// Idempotent price-table migration; retain raw events, formulas and card layout.
function updatePricingRulesSeptember2026() {
  const lock = LockService.getScriptLock(); lock.waitLock(25000);
  try {
    const ss = SpreadsheetApp.openById(PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID'));
    const prices = ss.getSheetByName('Prices');
    if (prices.getRange('J4').getValue() !== 'gpt-6-sol') {
      if (prices.getRange('J4').getValue() !== '估值口径') throw new Error('Unexpected price-table layout');
      prices.getRange('J4:P4').insertCells(SpreadsheetApp.Dimension.ROWS);
    }
    const source = 'https://developers.openai.com/api/docs/pricing';
    const checked = new Date('2026-09-28T00:00:00+08:00');
    prices.getRange('J2:P4').setValues([
      ['gpt-6-astra',10,1,50,12.5,source,checked],
      ['gpt-5.6-sol',4,0.4,20,5,source,checked],
      ['gpt-6-sol',2,0.2,10,2.5,source,checked]
    ]);
    prices.getRange('K2:N4').setNumberFormat('0.0000');
    prices.getRange('P2:P4').setNumberFormat('yyyy-mm-dd');
    prices.getRange('B2:G2').setFormulas([Array.from({length:6},(_,i)=> {
      const lookup = `VLOOKUP(A2:A,$J$2:$P$4,${i+2},FALSE)`;
      return `=ARRAYFORMULA(IF(A2:A="","",IFNA(${i===5 ? `TEXT(${lookup},"yyyy-mm-dd")` : lookup},"")))`;
    })]);
    prices.getRange('K6').setValue('GPT-5.6 Sol 优惠价至少持续至 2026-11-21；GPT-6 Sol 单独计价；非订阅余额');
    prices.getRange('K7').setValue('排除两代 Luna、自动审核与独立生图；未建模长上下文、Fast 和区域附加费');
    ss.getSheetByName('用量看板').getRange('B32').setValue('API 等价估值 · 未含 Luna、自动审核、独立生图');
    SpreadsheetApp.flush();
    refreshOverview_(ss);
    SpreadsheetApp.flush();
  } finally { lock.releaseLock(); }
}


function setup() {
  const p = PropertiesService.getScriptProperties();
  if (!p.getProperty('UPLOAD_SECRET') || p.getProperty('UPLOAD_SECRET').length < 32 ||
      !/^[a-f0-9]{64}$/.test(p.getProperty('ACCOUNT_KEY') || '')) {
    throw new Error('先设置脚本属性 UPLOAD_SECRET（至少32字符）与 ACCOUNT_KEY。');
  }
  const ss = p.getProperty('SPREADSHEET_ID') ? SpreadsheetApp.openById(p.getProperty('SPREADSHEET_ID')) : SpreadsheetApp.getActiveSpreadsheet();
  p.setProperty('SPREADSHEET_ID', ss.getId());
  [['TokenEvents',EVENT_HEADERS],['QuotaSnapshots',SNAP_HEADERS],['Prices',PRICE_HEADERS]].forEach(([name,headers]) => {
    let sheet = ss.getSheetByName(name);
    if (!sheet) sheet = ss.insertSheet(name);
    if (sheet.getLastRow() === 0) {
      sheet.getRange(1,1,1,headers.length).setValues([headers]).setBackground('#162637').setFontColor('#ffffff').setFontWeight('bold');
      sheet.setFrozenRows(1);
      sheet.autoResizeColumns(1,headers.length);
    } else if (JSON.stringify(sheet.getRange(1,1,1,headers.length).getValues()[0]) !== JSON.stringify(headers)) {
      throw new Error('已有同名工作表但列结构不同：'+name);
    }
  });
  ss.getSheetByName('TokenEvents').getRange('G:L').setNumberFormat('#,##0');
  ss.getSheetByName('TokenEvents').getRange('A:F').setNumberFormat('@');
  ss.getSheetByName('QuotaSnapshots').getRange('A:F').setNumberFormat('@');
  ss.getSheetByName('Prices').getRange('B:E').setNumberFormat('0.0000');
  ss.setSpreadsheetTimeZone('Asia/Shanghai');
  initOverview_(ss);
  refreshOverview_(ss);
}

function json_(data) {
  return ContentService.createTextOutput(JSON.stringify(data)).setMimeType(ContentService.MimeType.JSON);
}
function doGet() { return json_({service:'codex-usage-monitor',version:1}); }
function text_(value, maxLength) {
  if (typeof value !== 'string' || value.length > maxLength) throw new Error('invalid text');
  return /^[=+@\-\t\r]/.test(value) ? "'"+value : value;
}
function id_(value) {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{8,80}$/.test(value)) throw new Error('invalid id');
  return value;
}
function number_(value) {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error('invalid token count');
  return value;
}
function timestamp_(value) {
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) throw new Error('invalid timestamp');
  return new Date(value).toISOString();
}
function readRows_(sheet) {
  return sheet.getLastRow() < 2 ? [] : sheet.getRange(2,1,sheet.getLastRow()-1,sheet.getLastColumn()).getValues();
}
function uniqueRows_(sheet, rows) {
  const seen = new Set(sheet.getLastRow() < 2 ? [] : sheet.getRange(2,1,sheet.getLastRow()-1,1).getValues().flat());
  const fresh = rows.filter(row => { if (seen.has(row[0])) return false; seen.add(row[0]); return true; });
  if (fresh.length) {
    const required = sheet.getLastRow() + fresh.length;
    if (required > sheet.getMaxRows()) sheet.insertRowsAfter(sheet.getMaxRows(), required-sheet.getMaxRows());
    sheet.getRange(sheet.getLastRow()+1,1,fresh.length,fresh[0].length).setValues(fresh);
  }
}

function doPost(e) {
  let lock;
  try {
    if (!e || !e.postData || e.postData.contents.length > 1000000) throw new Error('invalid payload');
    const input = JSON.parse(e.postData.contents);
    const props = PropertiesService.getScriptProperties();
    const secret = props.getProperty('UPLOAD_SECRET');
    if (!secret || input.secret !== secret || input.account_key !== props.getProperty('ACCOUNT_KEY')) {
      return json_({ok:false,error:'unauthorized'});
    }
    if (input.version !== 1 || !Array.isArray(input.events) || !Array.isArray(input.snapshots) ||
        input.events.length > 300 || input.snapshots.length > 10 ||
        (input.image_events !== undefined && (!Array.isArray(input.image_events) || input.image_events.length>100))) throw new Error('invalid batch');
    const device = id_(input.device_id), account = id_(input.account_key), name = text_(input.device_name,128);
    const eventRows = input.events.map(row => {
      const timestamp = timestamp_(row.timestamp);
      const day = Utilities.formatDate(new Date(timestamp),'Asia/Shanghai','yyyy-MM-dd');
      return [id_(row.id),account,device,timestamp,day,text_(row.model,128),
        ...['input_tokens','cached_input_tokens','cache_write_input_tokens','output_tokens','reasoning_output_tokens','total_tokens'].map(k=>number_(row[k]))];
    });
    const snapshotRows = input.snapshots.map(row => {
      const observed = timestamp_(row.observed_at);
      if (!Array.isArray(row.windows) || row.windows.length > 30) throw new Error('invalid windows');
      const windows = row.windows.map(w => {
        if (w.used_percent !== null && (typeof w.used_percent !== 'number' || !Number.isFinite(w.used_percent) || w.used_percent < 0)) throw new Error('invalid quota');
        return {limit_id:text_(w.limit_id,128), window:text_(w.window,32), used_percent:w.used_percent,
          duration_minutes:w.duration_minutes === null ? null : number_(w.duration_minutes),
          resets_at:w.resets_at === null ? null : number_(w.resets_at)};
      });
      const clean = {observed_at:observed, windows, reset_credits:row.reset_credits === null ? null : number_(row.reset_credits),
        account_lifetime_tokens:row.account_lifetime_tokens === null ? null : number_(row.account_lifetime_tokens)};
      return [id_(row.id),account,device,name,observed,JSON.stringify(clean)];
    });
    const imageRows=(input.image_events || []).map(row=> {
      if (row.source!=='imagegen' || row.status!=='completed' || row.usage_status!=='unavailable') throw new Error('invalid image event');
      const timestamp=timestamp_(row.timestamp);
      const dimension=v=>v==null ? '' : number_(v);
      const width=dimension(row.width),height=dimension(row.height);
      if(width>20000 || height>20000) throw new Error('invalid dimensions');
      return [id_(row.id),account,device,timestamp,Utilities.formatDate(new Date(timestamp),'Asia/Shanghai','yyyy-MM-dd'),
        'imagegen','completed','unavailable',width,height];
    });
    lock = LockService.getScriptLock(); lock.waitLock(25000);
    const ss = SpreadsheetApp.openById(props.getProperty('SPREADSHEET_ID'));
    // Both tables use persistent IDs: partial writes and lost HTTP responses are safe to retry.
    uniqueRows_(ss.getSheetByName('TokenEvents'),eventRows);
    uniqueRows_(ss.getSheetByName('QuotaSnapshots'),snapshotRows);
    if(imageRows.length) uniqueRows_(ss.getSheetByName('ImageEvents'),imageRows);
    const dashboard = refreshOverview_(ss, device) || getDashboardData(device);
    SpreadsheetApp.flush();
    // Only the authenticated account's upload clients receive this aggregate; GET stays non-sensitive.
    return json_({ok:true,ack_ids:[...eventRows,...snapshotRows,...imageRows].map(row=>row[0]),dashboard});
  } catch (_) {
    return json_({ok:false,error:'ingest_failed'});
  } finally { if (lock && lock.hasLock()) lock.releaseLock(); }
}


function getDashboardData(currentDeviceId = null) {
  const ss = SpreadsheetApp.openById(PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID'));
  const rows = readRows_(ss.getSheetByName('QuotaSnapshots'));
  if (!rows.length) return {empty:true};
  rows.sort((a,b)=>Date.parse(b[4])-Date.parse(a[4]));
  const newest = JSON.parse(rows[0][5]);
  const devices = new Map();
  rows.forEach(r=> { if (!devices.has(r[2])) devices.set(r[2],{name:r[3],observed_at:r[4]}); });
  const quota = newest.windows.filter(w=>w.limit_id==='codex' && w.duration_minutes===10080)[0] || null;
  const today = Utilities.formatDate(new Date(),'Asia/Shanghai','yyyy-MM-dd');
  const events = readRows_(ss.getSheetByName('TokenEvents'));
  const prices = new Map(readRows_(ss.getSheetByName('Prices')).map(r=>[r[0],r]));
  let totalCost=0, windowCost=0, totalMissing=0, windowMissing=0;
  let deviceCost=0, deviceMissing=0, deviceWindowCost=0, deviceWindowMissing=0;
  const start = quota && quota.resets_at ? quota.resets_at*1000 - quota.duration_minutes*60000 : null;
  const end = quota && quota.resets_at ? quota.resets_at*1000 : null;
  const imageSheet=ss.getSheetByName('ImageEvents');
  const imageRows=imageSheet ? readRows_(imageSheet) : [];
  const imageStats={today_success:0,total_success:imageRows.length,weekly_success:0,
    pending_pricing:0,estimated_output_tokens:0,estimated_output_cost:0,
    assumed_model:'gpt-image-2.5',assumed_quality:'medium',output_usd_per_million:30};
  imageRows.forEach(r=> {
    if(r[4]===today) imageStats.today_success++;
    const inWindow=start!==null && Date.parse(r[3])>=start && Date.parse(r[3])<end;
    if(inWindow) imageStats.weekly_success++;
    const estimate=imageOutputEstimate_(r[8],r[9]);
    if(!estimate) {imageStats.pending_pricing++;return;}
    imageStats.estimated_output_tokens+=estimate.tokens;imageStats.estimated_output_cost+=estimate.cost;
    totalCost+=estimate.cost;if(inWindow)windowCost+=estimate.cost;
    if(r[2]===currentDeviceId) {deviceCost+=estimate.cost;if(inWindow)deviceWindowCost+=estimate.cost;}
  });
  events.forEach(r=> {
    if (EXCLUDED_COST_MODELS.has(r[5])) return;
    const p=prices.get(r[5]);
    const inWindow = start !== null && Date.parse(r[3]) >= start && Date.parse(r[3]) < end;
    // Deduplicated events retain their first uploading device's attribution.
    const onDevice = currentDeviceId !== null && r[2] === currentDeviceId;
    const valid = p && p.slice(1,4).every(v=>typeof v==='number' && Number.isFinite(v) && v>=0) &&
      (r[8]===0 || (typeof p[4]==='number' && Number.isFinite(p[4]) && p[4]>=0)) && r[6]>=r[7]+r[8];
    if (!valid) { totalMissing++; if(inWindow)windowMissing++; if(onDevice)deviceMissing++; if(onDevice && inWindow)deviceWindowMissing++; return; }
    const cost=((r[6]-r[7]-r[8])*p[1] + r[7]*p[2] + r[9]*p[3] + r[8]*(p[4]||0))/1e6;
    totalCost+=cost; if(inWindow)windowCost+=cost;
    if(onDevice)deviceCost+=cost;
    if(onDevice && inWindow)deviceWindowCost+=cost;
  });
  return {empty:false, observed_at:newest.observed_at, quota,
    reset_credits:newest.reset_credits, windows:newest.windows,
    today_tokens:events.filter(r=>r[4]===today).reduce((n,r)=>n+r[11],0),
    recorded_tokens:events.reduce((n,r)=>n+r[11],0),
    since:events.length ? events.map(r=>r[4]).sort()[0] : null,
    account_lifetime_tokens:newest.account_lifetime_tokens,
    total_cost:(!events.length && !imageRows.length) || totalMissing ? null : totalCost,
    image_stats:imageStats,
    current_device_id:currentDeviceId,
    current_device_cost:currentDeviceId === null || deviceMissing ? null : deviceCost,
    current_device_window_cost:currentDeviceId === null || start === null || deviceWindowMissing ? null : deviceWindowCost,
    window_cost:start===null || windowMissing || (!events.length && !imageRows.length) ? null : windowCost,
    missing_prices:totalMissing,
    excluded_cost_models:[...EXCLUDED_COST_MODELS],
    excluded_cost_events:events.filter(r=>EXCLUDED_COST_MODELS.has(r[5])).length,
    devices:[...devices.values()]};
}

function initOverview_(ss) {
  let s = ss.getSheetByName('用量看板');
  if (!s) {
    const blank = ss.getSheetByName('工作表1');
    s = blank && blank.getLastRow()===0 ? blank.setName('用量看板') : ss.insertSheet('用量看板',0);
  }
  s.setHiddenGridlines(true);
  s.getRange('A1:H32').setBackground('#030d14').setFontColor('#dfebff').setFontFamily('Arial').setVerticalAlignment('middle');
  s.setColumnWidth(1,24);s.setColumnWidths(2,6,80);s.setColumnWidth(8,24);
  s.setRowHeights(1,32,28);
  s.getRange('B2:G3').merge().setValue('Codex 用量').setFontSize(27).setFontWeight('bold');
  s.getRange('B16:G17').merge().setFormula('=IF(K2="","额度未上报",IF(K3<NOW(),"等待最新额度",MAX(0,MIN(100,100-K2))/100))').setNumberFormat('0%').setFontSize(48).setHorizontalAlignment('center');
  s.getRange('B18:G18').merge().setValue('本周剩余').setFontSize(18).setHorizontalAlignment('center');
  s.getRange('B20:D20').merge().setValue('今日 Tokens');s.getRange('E20:G20').merge().setValue('重置卡');
  s.getRange('B21:D22').merge().setFormula('=SUMIFS(\'TokenEvents\'!L2:L,\'TokenEvents\'!E2:E,TEXT(TODAY(),"yyyy-mm-dd"))').setNumberFormat('#,##0').setFontSize(23).setFontWeight('bold').setHorizontalAlignment('left');
  s.getRange('E21:G22').merge().setFormula('=IF(K4="","未知",K4)').setNumberFormat('0" 张"').setFontSize(23).setFontWeight('bold').setHorizontalAlignment('left');
  s.getRange('B24:D24').merge().setValue('下次重置（北京时间）');
  s.getRange('E24:G24').merge().setFormula('=IF(K3="","未知",K3)').setNumberFormat('mm/dd hh:mm');
  s.getRange('B26:D26').merge().setValue('本窗口采集估值');s.getRange('E26:G26').merge().setFormula('=IF(K5="","未配置价格",K5)').setNumberFormat('"$"#,##0.00').setFontColor('#448eff');
  s.getRange('B27:D27').merge().setValue('累计采集估值');s.getRange('E27:G27').merge().setFormula('=IF(K6="","未配置价格",K6)').setNumberFormat('"$"#,##0.00').setFontColor('#448eff');
  s.getRange('B29:G29').merge().setValue('API 等价估算 · 非订阅余额').setFontColor('#99aabb').setHorizontalAlignment('center');
  s.getRange('B30:G30').merge().setValue('工作日 09–18 时每 10 分钟，其余每小时采集').setFontSize(10).setFontColor('#99aabb').setHorizontalAlignment('center');
  s.getRange('B31:G31').merge().setFormula('=IF(K1="","等待首次上传","最近采集 "&TEXT(K1,"mm/dd hh:mm"))').setHorizontalAlignment('center');
  s.getRange('J1:K8').setValues([['最近采集（北京时间）',''],['周额度已用百分比',''],['重置时间（北京时间）',''],['可用重置卡',''],['本窗口采集估值（USD）',''],['累计采集估值（USD）',''],['采集起始日期',''],['上报设备数','']]);
  s.getRange('J10:K12').setValues([['额度','百分比'],['剩余',''],['已用','']]);
  s.getRange('K11').setFormula('=IF(K2="",0,MAX(0,MIN(100,100-K2)))');
  s.getRange('K12').setFormula('=IF(K2="",0,100-K11)');
  s.getRange('J15:K18').setValues([['统计来源','说明'],['TokenEvents','按原始记录指纹去重；云端任务可能未覆盖'],['QuotaSnapshots','采用最新账号快照，各设备额度不相加'],['Prices','美元/百万 token，空白价格表示未知']]);
  s.getRange('J20:K21').setValues([['额度接口文档','https://learn.chatgpt.com/docs/app-server'],['上传接收端文档','https://developers.google.com/apps-script/guides/web']]);
  s.setColumnWidth(10,210);s.setColumnWidth(11,440);
  s.getRange('J1:K21').setVerticalAlignment('middle');s.getRange('K1').setNumberFormat('yyyy-mm-dd hh:mm:ss');s.getRange('K3').setNumberFormat('yyyy-mm-dd hh:mm');
  s.getCharts().forEach(c=>s.removeChart(c));
  const chart=s.newChart().setChartType(Charts.ChartType.PIE).addRange(s.getRange('J11:K12')).setNumHeaders(0)
    .setPosition(4,2,0,0).setOption('width',480).setOption('height',336).setOption('pieHole',0.84)
    .setOption('legend','none').setOption('pieSliceText','none').setOption('backgroundColor','#030d14')
    .setOption('colors',['#448eff','#203147']).build();
  s.insertChart(chart);
}

function refreshOverview_(ss, currentDeviceId = null) {
  const s=ss.getSheetByName('用量看板');
  if (!s) return;
  const d=getDashboardData(currentDeviceId);
  if (d.empty) return;
  if(ss.getSheetByName('ImageEvents')) {
    s.getRange('B34').setValue(`成功生图：今日 ${d.image_stats.today_success} 次 · 累计 ${d.image_stats.total_success} 次`);
    s.getRange('B35').setValue(`生图输出估值 $${d.image_stats.estimated_output_cost.toFixed(2)} 已计入金额 · ${d.image_stats.pending_pricing} 次待计价\n假设 Image 2.5 medium，尺寸向上对齐 16px；实际生图 Tokens 未知，未含输入成本`);
  }
  s.getRange('K1:K8').setValues([[new Date(d.observed_at)],[d.quota ? d.quota.used_percent : ''],
    [d.quota && d.quota.resets_at ? new Date(d.quota.resets_at*1000) : ''],
    [d.reset_credits === null ? '' : d.reset_credits],[d.window_cost === null ? '' : d.window_cost],
    [d.total_cost === null ? '' : d.total_cost],[d.since || ''],[d.devices.length]]);
  // A shared sheet has no local device identity: persist its explicit selection.
  const selectedDevice = s.getRange('K23').getValue();
  if (typeof selectedDevice === 'string' && selectedDevice) {
    const selected = selectedDevice === currentDeviceId ? d : getDashboardData(selectedDevice);
    s.getRange('K24:K25').setValues([
      [selected.current_device_window_cost == null ? '' : selected.current_device_window_cost],
      [selected.current_device_cost == null ? '' : selected.current_device_cost]
    ]);
  }
  return d;
}

// One-time presentation migration; does not recreate or change source/price tabs.
function syncLightOverview() {
  const ss = SpreadsheetApp.openById(PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID'));
  const s = ss.getSheetByName('用量看板');
  const selectedDevice = s.getRange('K23').getValue();
  const deviceRows = readRows_(ss.getSheetByName('QuotaSnapshots')).filter(r=>r[2]===selectedDevice);
  if (!deviceRows.length) throw new Error('请先在看板 K23 选择已接入的设备 ID。');
  deviceRows.sort((a,b)=>Date.parse(b[4])-Date.parse(a[4]));
  s.getRange('J23').setValue('看板所选设备 ID');
  s.getRange('J24:J26').setValues([['所选设备本周消耗（USD）'],['所选设备累计消耗（USD）'],['看板所选设备名称']]);
  s.getRange('K26').setValue(deviceRows[0][3]);
  s.getRange('K24:K25').setNumberFormat('"$"#,##0.00');
  s.getRange('A1:H34').breakApart().clearContent().setBackground('#f2f2f7').setFontColor('#1d1d1f')
    .setFontFamily('Arial').setFontSize(11).setFontWeight('normal').setVerticalAlignment('middle');
  s.setHiddenGridlines(true);
  s.setColumnWidth(1,24);s.setColumnWidths(2,6,80);s.setColumnWidth(8,24);s.setRowHeights(1,34,20);
  const text = (range,value,size=11,color='#6e6e73') => s.getRange(range).merge().setValue(value).setFontSize(size).setFontColor(color);
  const formula = (range,value,size=20,format='"$"#,##0.00') => s.getRange(range).merge().setFormula(value).setNumberFormat(format).setFontSize(size).setFontWeight('bold');
  text('B2:G3','Codex 用量',24,'#1d1d1f').setFontWeight('bold');
  ['B4:G15','B17:D20','E17:G20','B22:G28'].forEach(r=>s.getRange(r).setBackground('#ffffff'));
  text('E5:G5','本周剩余',12);
  formula('E6:G8','=IF(K2="","额度未上报",IF(OR(K3="",K3<=NOW()),"等待最新额度",MAX(0,MIN(100,100-K2))/100))',36,'0%');
  text('E10:G10','下次重置 · 北京时间',10);
  formula('E11:G12','=IF(K3="","未知",K3)',14,'mm/dd hh:mm');
  text('B17:D17','今日 Tokens');text('E17:G17','重置卡');
  formula('B18:D20','=SUMIFS(TokenEvents!L2:L,TokenEvents!E2:E,TEXT(TODAY(),"yyyy-mm-dd"))',22,'#,##0');
  formula('E18:G20','=IF(K4="","未知",K4)',22,'0" 张"');
  text('B22:E23','当前周额度本设备消耗估值',12);
  text('B24:E25','当前周额度账号总估值',12);
  text('B26:E27','当前设备累计使用估值',12);
  formula('F22:G23','=IF(OR(K24="",K3="",K3<=NOW()),"暂无估值",K24)',20).setFontColor('#007aff').setHorizontalAlignment('right');
  formula('F24:G25','=IF(OR(K5="",K5<=0,K2="",K2<=0,K2>100,K3="",K3<=NOW(),K1="",NOW()-K1>75/1440),"暂不可估",K5/(K2/100))',20).setFontColor('#007aff').setHorizontalAlignment('right');
  formula('F26:G27','=IF(K25="","暂无估值",K25)',20).setFontColor('#007aff').setHorizontalAlignment('right');
  text('B28:G28','账号总估值按已用比例推算整周额度',9).setHorizontalAlignment('center');
  s.getRange('B30:G30').merge().setFormula('="本设备："&K26&" · "&K8&" 台设备已接入"').setFontSize(10).setFontColor('#6e6e73').setHorizontalAlignment('center');
  s.getRange('B31:G31').merge().setFormula('=IF(K1="","等待首次上传","最近采集 "&TEXT(K1,"mm/dd hh:mm")&" · 北京时间")').setFontSize(10).setFontColor('#6e6e73').setHorizontalAlignment('center');
  text('B32:G32','API 等价估值 · 未含 Luna、自动审核、独立生图',9).setHorizontalAlignment('center');
  text('B33:G33','工作日 09–18 时每 10 分钟，其余每小时采集',9).setHorizontalAlignment('center');
  s.getRange('K11').setFormula('=IF(OR(K2="",K3="",K3<=NOW()),0,MAX(0,MIN(100,100-K2)))');
  s.getRange('K12').setFormula('=100-K11');
  s.getCharts().forEach(c=>s.removeChart(c));
  s.insertChart(s.newChart().setChartType(Charts.ChartType.PIE).addRange(s.getRange('J11:K12')).setNumHeaders(0)
    .setPosition(4,2,0,0).setOption('width',240).setOption('height',240).setOption('pieHole',0.84)
    .setOption('legend','none').setOption('pieSliceText','none').setOption('backgroundColor','#ffffff')
    .setOption('colors',['#007aff','#e2e8f3']).build());
  refreshOverview_(ss,selectedDevice);
  SpreadsheetApp.flush();
}
