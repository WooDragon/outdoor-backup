#!/usr/bin/env node
/*
 * BDD checks for the live-progress rendering contract. The page script is
 * loaded directly from status.htm; the DOM double only supplies browser APIs
 * needed to observe #current-backup and is not a LuCI/browser E2E harness.
 */
'use strict';

var fs = require('fs');
var path = require('path');
var vm = require('vm');
var cases = 0;
var assertions = 0;
var failures = 0;
var pagePath = path.join(__dirname, 'luci-app-outdoor-backup/luasrc/view/outdoor-backup/status.htm');

function fail(message) {
    failures += 1;
    console.error('FAIL: ' + message);
}

function assertIncludes(html, text, message) {
    assertions += 1;
    if (html.indexOf(text) === -1) fail(message + ' (missing: ' + text + ')');
}

function assertExcludes(html, text, message) {
    assertions += 1;
    if (html.indexOf(text) !== -1) fail(message + ' (unexpected: ' + text + ')');
}

function beginCase(id, description) {
    cases += 1;
    console.log('CASE ' + id + ': ' + description);
}

function escapeForHtml(value) {
    return String(value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function createPage() {
    var source = fs.readFileSync(pagePath, 'utf8');
    var scriptMatch = source.match(/<script type="text\/javascript">([\s\S]*?)<\/script>/);
    var elements = {};

    if (!scriptMatch) throw new Error('status.htm has no executable page script');

    function element() {
        var text = '';
        return {
            innerHTML: '',
            innerText: '',
            style: {},
            classList: { contains: function() { return false; } },
            get textContent() { return text; },
            set textContent(value) {
                text = value;
                this.innerHTML = escapeForHtml(value);
            }
        };
    }

    var document = {
        addEventListener: function() {},
        createElement: element,
        getElementById: function(id) {
            if (!elements[id]) elements[id] = element();
            return elements[id];
        }
    };
    var sandbox = {
        console: console,
        Date: Date,
        Math: Math,
        document: document,
        window: {},
        XHR: { get: function() {}, post: function() {}, poll: function() {} },
        alert: function() {},
        confirm: function() { return true; },
        setTimeout: function() {},
        encodeURIComponent: encodeURIComponent
    };

    sandbox.window = sandbox;
    vm.runInNewContext(scriptMatch[1], sandbox, { filename: pagePath });
    return { update: sandbox.updateCurrentBackup, container: document.getElementById('current-backup') };
}

function liveBackup(overrides) {
    var backup = {
        active: true,
        name: 'Camera card',
        uuid: '11111111-1111-1111-1111-111111111111',
        device: 'sda1',
        started_at: 100,
        progress_percent: 11,
        files_done: 4,
        files_total: 0,
        bytes_done: 0,
        bytes_total: 0,
        speed_bytes_per_sec: 0,
        live_progress: {
            basis: 'file_list_entries',
            entries_done: null,
            entries_total: null,
            sampled_at: null,
            files_known: false
        }
    };
    var key;

    for (key in overrides) backup[key] = overrides[key];
    return backup;
}

function caseUnknownProgress() {
    var page = createPage();
    beginCase('P01', 'a suffix-free sample shows bytes and speed without fabricating a file count');
    page.update(liveBackup({
        files_done: 0,
        bytes_done: 1024,
        speed_bytes_per_sec: 512,
        live_progress: {
            basis: 'file_list_entries',
            entries_done: null,
            entries_total: null,
            sampled_at: 1000,
            files_known: false
        }
    }));
    assertIncludes(page.container.innerHTML, 'Last observed file-list entries checked (including directories)',
        'new live progress identifies its entry-list basis');
    assertIncludes(page.container.innerHTML, 'Scanning / waiting for progress',
        'unknown entries display an explicit waiting state');
    assertIncludes(page.container.innerHTML, 'Waiting for file count',
        'a compatible outer zero is not rendered as an observed file count');
    assertIncludes(page.container.innerHTML, '<strong>Bytes transferred:</strong> <span>1.00 KB</span>',
        'a suffix-free sample still exposes observed transferred bytes');
    assertIncludes(page.container.innerHTML, '512.00 B/s',
        'a suffix-free sample still exposes observed transfer speed');
    assertExcludes(page.container.innerHTML, '<strong>Files transferred:</strong> <span>0</span>',
        'unobserved file count is not rendered as a measurement');
}

function caseObservedProgressUsesBackendPercent() {
    var page = createPage();
    var firstHtml;
    beginCase('P02', 'observed entries and backend percent update the running output');
    page.update(liveBackup({
        progress_percent: 11,
        files_done: 7,
        bytes_done: 2048,
        speed_bytes_per_sec: 1024,
        live_progress: {
            basis: 'file_list_entries',
            entries_done: 22,
            entries_total: 200,
            sampled_at: 1000,
            files_known: true
        }
    }));
    firstHtml = page.container.innerHTML;
    assertIncludes(firstHtml, '22 / 200', 'known entry counts are rendered from live_progress');
    assertIncludes(firstHtml, '11.0%', 'the progress bar uses backend progress_percent, not entry arithmetic');
    assertIncludes(firstHtml, '<strong>Files transferred:</strong> <span>7</span>', 'files_done is labelled as transferred files');
    assertIncludes(firstHtml, '<strong>Bytes transferred:</strong> <span>2.00 KB</span>', 'bytes_done is labelled as transferred bytes');
    assertIncludes(firstHtml, '1.00 KB/s', 'observed transfer speed is displayed');
    assertIncludes(firstHtml, 'Unavailable for incremental backups', 'live incremental backups do not fabricate ETA');

    page.update(liveBackup({
        progress_percent: 12,
        files_done: 8,
        bytes_done: 3072,
        speed_bytes_per_sec: 1536,
        live_progress: {
            basis: 'file_list_entries',
            entries_done: 23,
            entries_total: 200,
            sampled_at: 1010,
            files_known: true
        }
    }));
    assertExcludes(page.container.innerHTML, firstHtml,
        'a later running snapshot changes the actual rendered output');
    assertIncludes(page.container.innerHTML, '12.0%', 'later backend progress_percent replaces the prior value');
}

function caseObservedZeroAndEscaping() {
    var page = createPage();
    beginCase('P03', 'a sampled zero is real data and card names remain escaped');
    page.update(liveBackup({
        name: '<img src=x onerror=alert(1)>',
        files_done: 0,
        bytes_done: 0,
        speed_bytes_per_sec: 0,
        live_progress: {
            basis: 'file_list_entries',
            entries_done: 0,
            entries_total: 20,
            sampled_at: 1000,
            files_known: true
        }
    }));
    assertIncludes(page.container.innerHTML, '<strong>Files transferred:</strong> <span>0</span>', 'sampled zero files remain visible');
    assertIncludes(page.container.innerHTML, '<strong>Bytes transferred:</strong> <span>0 B</span>', 'sampled zero bytes remain visible');
    assertIncludes(page.container.innerHTML, '0 B/s', 'sampled zero speed remains visible');
    assertIncludes(page.container.innerHTML, '&lt;img src=x onerror=alert(1)&gt;',
        'card name is HTML-escaped');
    assertExcludes(page.container.innerHTML, '<img src=x onerror=alert(1)>',
        'raw card markup is not inserted');
}

function caseLegacyAndIdle() {
    var page = createPage();
    beginCase('P04', 'legacy snapshots retain the old section while idle clears it');
    page.update({
        active: true,
        name: 'Legacy card',
        uuid: '22222222-2222-2222-2222-222222222222',
        device: 'sdb1',
        progress_percent: 25,
        files_done: 7,
        files_total: 0,
        bytes_done: 0,
        bytes_total: 0,
        speed_bytes_per_sec: 0
    });
    assertIncludes(page.container.innerHTML, '<strong>Files:</strong> <span>7 / 0</span>',
        'old snapshots keep their former display path');
    page.update(null);
    assertIncludes(page.container.innerHTML, 'No backup in progress', 'null current_backup clears the running section');
}

caseUnknownProgress();
caseObservedProgressUsesBackendPercent();
caseObservedZeroAndEscaping();
caseLegacyAndIdle();

console.log('RESULT cases=' + cases + ' assertions=' + assertions + ' failed=' + failures);
if (cases !== 4) {
    console.error('FAIL: expected 4 cases, ran ' + cases);
    process.exitCode = 1;
}
if (assertions !== 21) {
    console.error('FAIL: expected 21 assertions, ran ' + assertions);
    process.exitCode = 1;
}
if (failures !== 0) process.exitCode = 1;
