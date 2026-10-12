'use strict';
// Execute delivered page scripts with a text-aware DOM double. Not browser E2E.
const fs = require('fs');
const vm = require('vm');
// Assertions are counted without stopping at the first failure, so RED exposes all cases.
const path = require('path');
const repo = path.resolve(__dirname, '../..');
let ran = 0, assertions = 0, failures = 0, failedCases = 0;
function check(value, message) {
    assertions++;
    if (!value) { failures++; console.error('FAIL ' + message); }
}
function scenario(name, run) {
    ran++;
    const before = failures;
    try { run(); } catch (error) { failures++; console.error(error.stack); }
    if (failures !== before) failedCases++;
    console.log((failures === before ? 'PASS ' : 'FAIL ') + name);
}
function escape(value) { return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;'); }
// Small structural DOM double. Only legacy innerHTML is parsed; new date nodes
// must be constructed with textContent. It has no layout engine or script execution.
function decode(value) {
    return value.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
        .replace(/&#39;/g, "'").replace(/&amp;/g, '&');
}
class Element {
    constructor(tag = 'div') {
        this.tagName = tag.toUpperCase(); this.style = {}; this.value = '';
        this.children = []; this.attributes = {}; this._text = ''; this.checked = false;
    }
    set className(value) { this.attributes.class = value; }
    get className() { return this.attributes.class || ''; }
    set textContent(value) { this.children = []; this._text = String(value); }
    get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
    set innerHTML(value) {
        this.children = []; this._text = '';
        const stack = [this];
        for (const token of String(value).match(/<[^>]*>|[^<]+/g) || []) {
            if (token.startsWith('</')) { stack.pop(); continue; }
            if (token.startsWith('<')) {
                const match = token.match(/^<([\w-]+)/);
                if (!match) throw new Error('Unsupported DOM markup: ' + token);
                const child = new Element(match[1]);
                for (const attr of token.matchAll(/([\w-]+)="([^"]*)"/g)) child.attributes[attr[1]] = decode(attr[2]);
                stack[stack.length - 1].appendChild(child);
                if (!['BR','INPUT','IMG'].includes(child.tagName)) stack.push(child);
            } else {
                const child = new Element('#text'); child.textContent = decode(token);
                stack[stack.length - 1].appendChild(child);
            }
        }
    }
    get innerHTML() { return escape(this._text) + this.children.map(child => child.outerHTML).join(''); }
    get outerHTML() {
        if (this.tagName === '#TEXT') return escape(this._text);
        const attrs = Object.entries(this.attributes).map(([key,value]) => ` ${key}="${escape(value)}"`).join('');
        return `<${this.tagName.toLowerCase()}${attrs}>${this.innerHTML}</${this.tagName.toLowerCase()}>`;
    }
    set innerText(value) { this.textContent = value; }
    appendChild(child) { this.children.push(child); return child; }
    setAttribute(name, value) { this.attributes[name] = String(value); }
    getAttribute(name) { return this.attributes[name]; }
    querySelectorAll(selector) {
        const match = selector.match(/^\[([\w-]+)\]$/);
        if (!match) throw new Error('Unsupported DOM selector: ' + selector);
        return descendants(this).filter(child => child.getAttribute(match[1]) !== undefined);
    }
}
function descendants(node) {
    if (!node || !node.children) return [];
    return node.children.flatMap(child => [child, ...descendants(child)]);
}
function tagged(node, tag) { return descendants(node).filter(child => child.tagName === tag.toUpperCase()); }
function section(node, title) {
    return tagged(node, 'fieldset').find(child => tagged(child, 'legend').some(legend => legend.textContent === title));
}
function content(node) { return typeof node === 'string' ? node : node ? node.textContent : ''; }
const elements = {};
const document = {getElementById(id) { return elements[id] || (elements[id] = new Element()); },
    createElement(tag) { return new Element(tag); }, addEventListener() {}};
const calls = [];
const context = {document, window: {addEventListener() {}}, console, alert() {}, confirm() {return true;},
    XHR: {post(url, body, callback) {calls.push({url, body, callback});}, get() {}, poll() {}}, setTimeout() {}};
vm.createContext(context);
const statusPath = path.join(repo, 'luci-app-outdoor-backup/luasrc/view/outdoor-backup/status.htm');
const statusSource = fs.readFileSync(statusPath, 'utf8');
vm.runInContext(statusSource.match(/<script type="text\/javascript">([\s\S]*?)<\/script>/)[1].replace(/<%=[\s\S]*?%>/g, '/api'), context);
const task = {version:1, layout:'date', phase:'planning', comparison_mode:'quick',
    archive:{files_total:null, routes_total:null, excluded_total:0, undated_total:null},
    warnings:[{code:'no_capture_date', count:0}], replaced:{files_count:0, path:'</span><img src=x onerror=evil()> "\n'}};
const backup = {active:true, name:'<script>card()</script>', task, progress_percent:85, files_done:0,
    bytes_done:0, speed_bytes_per_sec:0,
    live_progress:{basis:'file_list_entries', entries_done:null, entries_total:null, sampled_at:null, files_known:false}};
scenario('J01 planning has no percentage or ETA estimate', () => {
    context.updateCurrentBackup(backup);
    const html=elements['current-backup'].innerHTML;
    check(html.includes('正在分析素材') && html.includes('Unknown'), 'planning unknown state missing');
    check(!html.includes('85.0%') && !html.includes('width:'), 'planning invented progress');
    check(!html.includes('<script>card()') && !html.includes('<img src=x'), 'path/name interpreted as markup');
    check(content(elements['current-backup']).includes('Excluded0') && content(elements['current-backup']).includes('未保留旧文件（0）'), 'zero hidden');
});
scenario('J02 finalizing explicit no transfer projection', () => {
    task.phase='finalizing';context.updateCurrentBackup(backup);
    check(elements['current-backup'].innerHTML.includes('正在完成同步'), 'finalizing missing');
    check(!elements['current-backup'].innerHTML.includes('85.0%'), 'stale progress during finalize');
});
scenario('J03 transfer unknown versus observed zero', () => {
    task.phase='transferring';context.updateCurrentBackup(backup);
    check(elements['current-backup'].innerHTML.includes('Waiting for file count'), 'unknown count called zero');
    backup.live_progress.files_known=true;backup.live_progress.sampled_at=100;
    backup.live_progress.entries_done=0;backup.live_progress.entries_total=10;
    context.updateCurrentBackup(backup);
    check(elements['current-backup'].innerHTML.includes('Files transferred:</strong> <span>0'), 'observed zero hidden');
    check(elements['current-backup'].innerHTML.includes('Unavailable for incremental backups'), 'ETA invented');
});
scenario('J04 exact task version/schema and whitelist rejection', () => {
    check(context.validTask(task), 'valid schema rejected');
    for (const mutate of [value=>value.version=2, value=>value.GPS='private',value=>value.archive.rawUMID='private',
        value=>value.warnings[0].code=5,value=>value.replaced.files_count=-1,value=>value.archive.files_total=1.2]) {
        const bad=JSON.parse(JSON.stringify(task));mutate(bad);
        check(!context.validTask(bad), 'invalid task accepted');
    }
});
scenario('J05 mode and replaced semantics are honest', () => {
    const quick=content(context.taskSummary(task));
    check(quick.includes('same size/mtime content changes may be missed') && quick.includes('identical old content'), 'quick scope missing');
    task.comparison_mode='checksum';const deep=content(context.taskSummary(task));
    check(deep.includes('reads current source') && deep.includes('does not audit historical'), 'checksum cost/scope missing');
    check(tagged(context.taskSummary(task), 'img').length===0, 'replaced path unsafe');
});
scenario('J06 history hostile alias/path cannot create inline JavaScript', () => {
    const history=[{uuid:'\" onclick=evil() <x>',name:'\"<img src=x>\'\n',status:'<img src=x>',task}];
    context.updateHistoryTable(history);
    check(!elements['history-table'].innerHTML.includes('onclick='), 'history still uses mixed HTML/JS context');
    check(!elements['history-table'].innerHTML.includes('<img src=x>'), 'history raw HTML');
    const link=elements['history-table'].querySelectorAll('[data-history-index]')[0];link.onclick();
    check(elements['alias-input'].value===history[0].name, 'alias data damaged by encoding');
});
scenario('J07 writes use form objects with CSRF, never stringified XHR data', () => {
    elements['outdoor-backup-token']=new Element();elements['outdoor-backup-token'].value='synthetic-token';
    document.getElementById('alias-uuid-hidden').value='11111111-2222-3333-4444-555555555555';
    document.getElementById('alias-input').value=' <alias> ';
    document.getElementById('alias-notes').value=' notes ';
    context.saveAlias();context.deleteAlias();
    document.getElementById('confirm-text-input').value='清空备份数据';context.executeCleanup();
    check(calls.length===3, 'missing write request');
    for (const call of calls) check(typeof call.body==='object' && call.body.token==='synthetic-token', 'XHR body not form/token');
    check(calls[0].body.alias==='<alias>' && calls[2].body.confirm_text==='清空备份数据', 'form fields damaged');
});
scenario('J08 log highlights fixed spans holding text nodes', () => {
    document.getElementById('log-content').textContent='[WARN] </pre><script>evil()</script> \' "\n[INFO] safe';
    const source=fs.readFileSync(path.join(repo, 'luci-app-outdoor-backup/luasrc/view/outdoor-backup/log.htm'),'utf8');
    check(!source.includes('href="/opt/outdoor-backup/log/backup.log"'), 'raw log URL bypasses authorized read');
    vm.runInContext(source.match(/<script type="text\/javascript">([\s\S]*?)<\/script>/)[1],context);
    context.highlightLog();
    check(elements['log-content'].children[0].textContent.includes('<script>evil()'), 'log text changed');
    check(elements['log-content'].children[0].className==='log-warn', 'safe highlight missing');
    document.getElementById('log-level-filter').value='all';context.filterLogLevel();
    check(elements['log-content'].children[0].textContent.includes('<script>evil()'), 'filter parsed HTML');
});
function dateTask() {
    return {version:1, layout:'date', phase:'transferring', comparison_mode:'quick',
        archive:{files_total:57, routes_total:57, excluded_total:4, undated_total:57},
        warnings:[{code:'metadata_parse_warning', count:57}], replaced:{files_count:null, path:'/mnt/ssd/replaced/' + 'x'.repeat(300)}};
}
scenario('J10 date archive has bounded sections, labels and all four statistics', () => {
    const view=context.taskSummary(dateTask());
    check(typeof view==='object', 'date summary must be DOM, not concatenated HTML');
    const archive=section(view, '日期归档信息');
    check(!!archive, 'archive fieldset/legend missing');
    check(content(archive).includes('日期归档 · date') && content(archive).includes('快速比较 · quick'), 'concise mode labels missing');
    const rows=tagged(archive, 'tr').map(row => row.textContent);
    check(rows.join('|')==='Accepted files57|Retained routes57|Excluded4|Undated57', 'four archive statistics missing or mislabeled');
    check(content(view).includes('有文件待确认') && content(view).includes('不是 rsync 失败'), 'Undated semantics missing');
    check(content(view).includes('路由数不是已复制完成数'), 'route count misrepresented as completion');
});
scenario('J11 metadata warnings are friendly counted notices, not task failure', () => {
    const view=context.taskSummary(dateTask()), notice=section(view, '元数据提示');
    check(!!notice, 'independent metadata notice missing');
    check(content(notice).includes('元数据读取提示') && content(notice).includes('57 次'), 'friendly parse warning/count missing');
    check(content(notice).includes('不等于备份任务失败'), 'nonfatal semantics missing');
    const details=tagged(notice, 'details');
    check(details.length===1 && content(details[0]).includes('metadata_parse_warning'), 'code belongs in technical details');
    check(!descendants(notice).some(node => node.className.includes('alert-danger')), 'nonfatal warning styled as failure');
});
scenario('J12 no warnings is explicit and zero counts remain visible', () => {
    const value=dateTask(); value.warnings=[];
    Object.keys(value.archive).forEach(key => value.archive[key]=0);
    const view=context.taskSummary(value);
    check(content(section(view, '元数据提示')).includes('无元数据提示'), 'empty warnings missing');
    check(tagged(section(view, '日期归档信息'), 'tr').every(row => row.textContent.endsWith('0')), 'archive zero hidden');
    check(!content(view).includes('有文件待确认'), 'zero Undated raises false notice');
    value.warnings=[{code:'no_capture_date', count:0}];
    check(content(section(context.taskSummary(value), '元数据提示')).includes('0 次'), 'warning zero hidden');
});
scenario('J13 unknown and hostile codes safely preserve the rest of the task', () => {
    for (const code of ['future_metadata_notice', '<img src=x onerror=evil()> "\n']) {
        const value=dateTask(); value.warnings=[{code,count:2}];
        check(context.validTask(value), 'unknown code rejected entire valid task');
        const view=context.taskSummary(value), notice=section(view, '元数据提示');
        check(content(notice).includes('未识别的元数据提示') && content(notice).includes('2 次'), 'generic warning/count missing');
        check(tagged(notice, 'details').some(node => content(node).includes(code)), 'unknown code must be literal technical text');
        check(tagged(view, 'img').length===0 && tagged(view, 'script').length===0, 'hostile code becomes markup');
        check(!!section(view, '日期归档信息'), 'unknown code erased archive information');
    }
});
scenario('J14 old versions distinguish unknown, zero and positive counts', () => {
    const value=dateTask();
    for (const [count, expected] of [[null,'未知（未提供计数）'],[0,'未保留旧文件（0）'],[3,'已保留旧文件：3']]) {
        value.replaced.files_count=count;
        const retained=section(context.taskSummary(value), '旧版本保留');
        check(content(retained).includes(expected), 'retained count semantics: ' + count);
        check(content(retained).includes('目录存在不代表已保留文件'), 'backup-dir mistaken for retained files');
        check(!descendants(retained).some(node => node.className.includes('alert-danger')), 'unknown retention is not an error');
    }
});
scenario('J15 long hostile path is literal, wrapping and collapsed in details', () => {
    const value=dateTask(); value.replaced.path='</code><img src=x onerror=evil()> "\n' + 'x'.repeat(300);
    const retained=section(context.taskSummary(value), '旧版本保留'), details=tagged(retained, 'details');
    check(details.length===1 && !details[0].getAttribute('open'), 'path details must default collapsed');
    check(tagged(details[0], 'code').some(node => node.textContent===value.replaced.path), 'path literal damaged or absent');
    check(tagged(retained, 'img').length===0, 'path injected markup');
    check(tagged(details[0], 'code').some(node => node.className==='outdoor-task-path'), 'path wrap class missing');
    check(/\.outdoor-task-path\s*\{[^}]*overflow-wrap:\s*anywhere;[^}]*white-space:\s*pre-wrap;/s.test(statusSource), 'long path wrapping contract missing');
    value.replaced.path=null;
    check(tagged(section(context.taskSummary(value), '旧版本保留'), 'code').length===0, 'unknown path rendered as a fake path');
});
scenario('J16 comparison limits and CLI operations are collapsed help only', () => {
    for (const mode of ['quick','checksum']) {
        const value=dateTask();value.comparison_mode=mode;
        const view=context.taskSummary(value), help=tagged(view, 'details').find(node => tagged(node,'summary').some(child => child.textContent==='比较方式与操作边界'));
        check(!!help && !help.getAttribute('open'), 'comparison help missing/cannot collapse');
        check(content(help).includes(mode==='quick' ? 'same size/mtime content changes may be missed' : 'does not audit historical'), 'comparison limit missing');
        check(content(help).includes('CLI') && content(help).includes('不得手工改名'), 'CLI/path constraints missing');
        check(tagged(view,'button').length===0 && tagged(view,'input').length===0, 'date UI gained mutation controls');
    }
    check(!/<p>Automatic date tasks/.test(statusSource.replace(/<details\b[^>]*>[\s\S]*?<\/details>/g, '')), 'large top-level audit paragraph still present');
    check(/<details[^>]*>\s*<summary>[^<]*日期归档帮助/.test(statusSource), 'page-wide date help not collapsible');
});
scenario('J17 mirror, missing and old refreshed states leave no date boxes', () => {
    const value=dateTask();const running=Object.assign({},backup,{task:value});
    context.updateCurrentBackup(running);
    check(!!section(elements['current-backup'],'日期归档信息'), 'current date summary missing');
    for (const replacement of [undefined,null,Object.assign({},value,{layout:'mirror'})]) {
        context.updateCurrentBackup(Object.assign({},running,{task:replacement}));
        check(tagged(elements['current-backup'],'fieldset').length===0, 'date sections linger on mirror/legacy refresh');
    }
    context.updateCurrentBackup(running);context.updateCurrentBackup(null);
    check(tagged(elements['current-backup'],'fieldset').length===0, 'date sections linger on inactive refresh');
});
scenario('J18 current identity, progress and ETA contract remain unchanged', () => {
    const value=dateTask(), running=Object.assign({},backup,{name:'Card',uuid:'card-uuid',device:'sda1',started_at:100,task:value});
    context.updateCurrentBackup(running);
    const current=elements['current-backup'];
    check(content(current).includes('Card Name: Card') && content(current).includes('UUID: card-uuid') && content(current).includes('Device: /dev/sda1'), 'identity region changed');
    check(content(current).includes('Started:') && content(current).includes('Files transferred: 0') && content(current).includes('ETA: Unavailable for incremental backups'), 'main task counts/ETA changed');
    for (const phase of ['planning','finalizing']) {
        value.phase=phase;context.updateCurrentBackup(running);
        check(content(current).includes('UUID: card-uuid') && content(current).includes('Device: /dev/sda1') && content(current).includes('Started:'), 'phase erased task identity');
        check(!current.innerHTML.includes('85.0%') && !current.innerHTML.includes('progress-bar-fill'), 'non-transfer phase invents progress');
        check(content(current).includes('no ETA'), 'non-transfer phase invents ETA');
    }
    check(!statusSource.includes('!important'), 'CSS important forbidden');
    check(/\.outdoor-task-info legend\s*\{[^}]*line-height:\s*1\.4;/s.test(statusSource), 'CJK legend line-height contract missing');
});
scenario('J19 history preserves genuine failures and removes old task details', () => {
    const value=dateTask();
    context.updateHistoryTable([{uuid:'one',name:'Card',status:'failed',task:value},{uuid:'two',name:'Old',status:'completed'}]);
    const history=elements['history-table'];
    check(history.innerHTML.includes('status-error') && content(history).includes('Failed'), 'real failed status lost');
    check(tagged(history,'fieldset').length===3, 'history date sections missing or applied to old entry');
    check(history.querySelectorAll('[data-history-index]').length===2, 'history edit contract changed');
    context.updateHistoryTable([{uuid:'one',status:'completed'}]);
    check(tagged(history,'fieldset').length===0, 'history date sections retained after refresh');
});
function visibleContent(node) {
    if (!node || node.tagName==='DETAILS') return '';
    return node._text + node.children.map(visibleContent).join('');
}
scenario('J20 every known warning has friendly text; raw codes stay in details', () => {
    const codes=['xml_too_large','metadata_parse_failed','metadata_parse_warning','metadata_candidate_limit',
        'ambiguous_date_semantics','ambiguous_recording_identity','unverified_time_profile','ambiguous_pairing',
        'primary_not_present','no_capture_date','conflicting_capture_date'];
    for (const code of codes) {
        const value=dateTask();value.warnings=[{code,count:1}];
        const notice=section(context.taskSummary(value),'元数据提示');
        check(visibleContent(notice).includes('1 次'), 'friendly count missing: ' + code);
        check(!visibleContent(notice).includes(code) && !visibleContent(notice).includes('未识别'), 'known code not mapped: ' + code);
        check(content(tagged(notice,'details')[0]).includes(code), 'technical code lost: ' + code);
    }
    const helpers=statusSource.slice(statusSource.indexOf('function taskNode('),statusSource.indexOf('function backupIdentity('));
    check(!helpers.includes('innerHTML'), 'date renderer may not build dynamic HTML strings');
});
scenario('J21 malformed task preserves identity without inventing phase progress', () => {
    for (const mutate of [value=>value.version=2,value=>value.warnings[0].count=-1,
        value=>value.warnings[0].code='',value=>value.warnings[0].code='   ',
        value=>value.warnings[0].payload='private',value=>value.archive.files_total=-1,
        value=>value.replaced.path={},value=>value.archive.files_total=NaN]) {
        const value=dateTask();mutate(value);
        check(!context.validTask(value), 'malformed schema accepted');
        context.updateCurrentBackup(Object.assign({},backup,{uuid:'legacy-uuid',task:value}));
        check(content(elements['current-backup']).includes('unsupported schema') && content(elements['current-backup']).includes('UUID: legacy-uuid'), 'malformed schema must explain unavailability and keep identity');
        check(!content(elements['current-backup']).includes('ETA:') && !elements['current-backup'].innerHTML.includes('progress-bar-fill'), 'unsupported phase invents projection');
        check(tagged(elements['current-backup'],'fieldset').length===0, 'malformed schema shows empty date sections');
    }
});
// Optional argument is a copy of the actually installed guest framework, not a mock.
async function realXHR() {
    const framework=fs.readFileSync(process.argv[2], 'utf8');
    const poll=framework.slice(framework.indexOf('poll(interval,url,args,cb,post){'),framework.indexOf('},hasViewPermission(){'));
    const request=framework.slice(framework.indexOf('request(target,options){'),framework.indexOf('},handleReadyStateChange('));
    check(poll.startsWith('poll(') && request.startsWith('request('), 'unrecognized actual LuCI version');
    const sent=[];
    class RealTransport {
        open(method,url) {this.method=method;this.url=url;}
        setRequestHeader(name,value) {this[name]=value;}
        send(body) {sent.push({method:this.method,body,type:this['Content-Type']});}
    }
    const actual={Request:{expandURL:url=>url,handleReadyStateChange(){}},env:{token:'framework-token'},
        XMLHttpRequest:RealTransport,isQueueableRequest:()=>false,Date,Promise,console,
        location:{protocol:'http:',host:'synthetic'},classes:{},requestQueue:[]};
    vm.createContext(actual);
    vm.runInContext("String.prototype.format=function(){var args=arguments,i=0;return this.replace(/%s/g,function(){return args[i++];});};",actual);
    vm.runInContext('Request.request=({' + request + '}}).request; var realPoll=({' + poll + '}}).poll;',actual);
    for (const call of calls) actual.realPoll(null,'/api',call.body,()=>{},true);
    await new Promise(resolve=>setImmediate(resolve));
    scenario('J09 actual LuCI XHR POST and form encoding', () => {
        check(sent.length===3, 'actual XHR did not execute all requests');
        for (const wire of sent) {
            check(wire.method==='POST' && wire.type==='application/x-www-form-urlencoded', 'wrong actual wire contract');
            check(new URLSearchParams(wire.body).get('token')==='synthetic-token', 'token lost on wire');
        }
        check(new URLSearchParams(sent[2].body).get('confirm_text')==='清空备份数据', 'confirmation damaged on actual wire');
    });
}
(async()=>{
    const domOnly=process.argv[2]==='--dom-only';
    check(process.argv[2], 'actual installed LuCI source path or explicit --dom-only required');
    if (!domOnly && process.argv[2]) await realXHR();
    check(ran===(domOnly ? 20 : 21), 'unexpected case count');
    check(assertions===(domOnly ? 168 : 177), 'unexpected assertion count before final hard-count guard');
    console.log(`ran=${ran} passed=${ran-failedCases} failed=${failedCases} assertions=${assertions} assertion_failures=${failures}`);
    console.log(domOnly ? 'Boundary: production renderer + Node DOM double; no browser/E2E or actual LuCI XHR run.' : 'Boundary: Node DOM double + installed LuCI XHR source; not browser/E2E.');
    if (failures) process.exitCode=1;
})().catch(error=>{console.error(error);process.exitCode=1;});
