'use strict';
// Execute delivered page scripts with a text-aware DOM double. Not browser E2E.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const repo = path.resolve(__dirname, '../..');
let ran = 0, assertions = 0;
function check(value, message) { assertions++; assert(value, message); }
function scenario(name, run) { ran++; run(); console.log('PASS ' + name); }
function escape(value) { return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;'); }
class Element {
    constructor() { this.style = {}; this.value = ''; this.children = []; this.attributes = {}; this._text = ''; this._html = ''; this.checked = false; }
    set textContent(value) { this.children = []; this._text = String(value); this._html = escape(value); }
    get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
    set innerHTML(value) { this.children = []; this._html = value; this._text = ''; }
    get innerHTML() { return this._html; }
    set innerText(value) { this.textContent = value; }
    appendChild(child) { this.children.push(child); }
    getAttribute(name) { return this.attributes[name]; }
    querySelectorAll() {
        return Array.from(this._html.matchAll(/data-history-index="(\d+)"/g), match => {
            const element = new Element(); element.attributes['data-history-index'] = match[1];
            this.children.push(element); return element;
        });
    }
}
const elements = {};
const document = {getElementById(id) { return elements[id] || (elements[id] = new Element()); },
    createElement() { return new Element(); }, addEventListener() {}};
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
    check(html.includes('Excluded: 0') && html.includes('Retained old files (not proof of different content): 0'), 'zero hidden');
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
        value=>value.warnings[0].code='<img>',value=>value.replaced.files_count=-1,value=>value.archive.files_total=1.2]) {
        const bad=JSON.parse(JSON.stringify(task));mutate(bad);
        check(!context.validTask(bad), 'invalid task accepted');
    }
});
scenario('J05 mode and replaced semantics are honest', () => {
    const quick=context.taskSummary(task);
    check(quick.includes('same size/mtime content changes may be missed') && quick.includes('identical old content'), 'quick scope missing');
    task.comparison_mode='checksum';const deep=context.taskSummary(task);
    check(deep.includes('reads current source') && deep.includes('does not audit historical'), 'checksum cost/scope missing');
    check(!deep.includes('<img src=x'), 'replaced path unsafe');
});
scenario('J06 history hostile alias/path cannot create inline JavaScript', () => {
    const history=[{uuid:'\" onclick=evil() <x>',name:'\"<img src=x>\'\n',status:'<img src=x>',task}];
    context.updateHistoryTable(history);
    check(!elements['history-table'].innerHTML.includes('onclick='), 'history still uses mixed HTML/JS context');
    check(!elements['history-table'].innerHTML.includes('<img src=x>'), 'history raw HTML');
    const link=elements['history-table'].children[0];link.onclick();
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
    check(process.argv[2], 'actual installed LuCI source path required');
    await realXHR();
    check(ran===9, 'unexpected case count');
    console.log(`ran=${ran} passed=${ran} failed=0 assertions=${assertions}`);
})().catch(error=>{console.error(error);process.exitCode=1;});
