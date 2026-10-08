#!/usr/bin/env node
/*
 * BDD checks for status-page modal isolation and interactions. This test reads
 * and runs the delivered status.htm script with a DOM double; it does not claim
 * visual validation against a real LuCI theme or browser.
 */
'use strict';

var fs = require('fs');
var path = require('path');
var vm = require('vm');
var cases = 0;
var assertions = 0;
var failures = 0;
var pagePath = path.join(__dirname, 'luci-app-outdoor-backup/luasrc/view/outdoor-backup/status.htm');
var pageSource = fs.readFileSync(pagePath, 'utf8');
var stylesMatch = pageSource.match(/<style>([\s\S]*?)<\/style>/);
var scriptMatch = pageSource.match(/<script type="text\/javascript">([\s\S]*?)<\/script>/);
var modalIds = [
    'alias-modal',
    'cleanup-preview-modal',
    'cleanup-confirm-modal',
    'cleanup-progress-modal'
];
var htmlIds = Object.create(null);
var htmlSource;
var htmlIdPattern = /\bid="([^"]+)"/g;
var htmlIdMatch;

if (!stylesMatch) throw new Error('status.htm has no style block');
if (!scriptMatch) throw new Error('status.htm has no executable page script');

htmlSource = pageSource.slice(scriptMatch.index + scriptMatch[0].length);
while ((htmlIdMatch = htmlIdPattern.exec(htmlSource)) !== null) {
    htmlIds[htmlIdMatch[1]] = true;
}

function fail(message) {
    failures += 1;
    console.error('FAIL: ' + message);
}

function assert(condition, message) {
    assertions += 1;
    if (!condition) fail(message);
}

function assertIncludes(value, expected, message) {
    assert(value.indexOf(expected) !== -1, message + ' (missing: ' + expected + ')');
}

function assertExcludes(value, unexpected, message) {
    assert(value.indexOf(unexpected) === -1, message + ' (unexpected: ' + unexpected + ')');
}

function beginCase(id, description) {
    cases += 1;
    console.log('CASE ' + id + ': ' + description);
}

function hasClass(markup, className) {
    var classAttribute = /\bclass="([^"]*)"/g;
    var match;

    while ((match = classAttribute.exec(markup)) !== null) {
        if (match[1].split(/\s+/).indexOf(className) !== -1) return true;
    }
    return false;
}

function hasGenericModalClass(markup) {
    var classAttribute = /\bclass="([^"]*)"/g;
    var match;

    while ((match = classAttribute.exec(markup)) !== null) {
        if (match[1].split(/\s+/).some(function(className) {
            return /^modal(?:$|-)/.test(className);
        })) return true;
    }
    return false;
}

function extractModalMarkup(modalId) {
    var opening = '<div id="' + modalId + '"';
    var start = pageSource.indexOf(opening);
    var nextComment;
    var footer;
    var end;

    if (start === -1) return '';
    nextComment = pageSource.indexOf('<!--', start + opening.length);
    footer = pageSource.indexOf('<%+footer%>', start + opening.length);
    end = nextComment === -1 ? footer : (footer === -1 ? nextComment : Math.min(nextComment, footer));
    return pageSource.slice(start, end === -1 ? pageSource.length : end);
}

function createElement(classNames) {
    var tokens = (classNames || '').split(/\s+/).filter(Boolean);
    var text = '';

    return {
        innerHTML: '',
        innerText: '',
        style: {},
        value: '',
        checked: false,
        disabled: false,
        classList: {
            contains: function(className) {
                return tokens.indexOf(className) !== -1;
            }
        },
        get textContent() {
            return text;
        },
        set textContent(value) {
            text = value;
            this.innerHTML = String(value)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#39;');
        }
    };
}

function modalClass(modalId) {
    var match = pageSource.match(new RegExp('<div id="' + modalId + '" class="([^"]*)">'));
    return match ? match[1] : '';
}

function createPage() {
    var elements = {};
    var postCalls = [];
    var document = {
        addEventListener: function() {},
        createElement: function() {
            return createElement('');
        },
        getElementById: function(id) {
            if (!htmlIds[id]) return null;
            if (!elements[id]) elements[id] = createElement(modalClass(id));
            return elements[id];
        }
    };
    var sandbox = {
        console: console,
        Date: Date,
        Math: Math,
        document: document,
        window: {},
        XHR: {
            get: function(url, data, callback) {
                if (url.indexOf('/cleanup/preview') !== -1) {
                    callback(null, {
                        cards: [{display_name: 'Camera Card', uuid: '11111111-1111-1111-1111-111111111111', size_bytes: 10}],
                        total_size_bytes: 10
                    });
                }
            },
            post: function(url, data) {
                postCalls.push({url: url, data: data});
            },
            poll: function() {}
        },
        alert: function() {},
        confirm: function() { return true; },
        setTimeout: function() {},
        encodeURIComponent: encodeURIComponent
    };

    sandbox.window = sandbox;
    vm.runInNewContext(scriptMatch[1], sandbox, {filename: pagePath});
    return {context: sandbox, document: document, postCalls: postCalls};
}

function caseModalCssAndMarkupAreIsolated() {
    var styles = stylesMatch[1];
    var mediaStart = styles.indexOf('@media (max-width: 768px)');
    var baseStyles = styles.slice(0, mediaStart);
    var mediaStyles = styles.slice(mediaStart);
    var requiredClasses = [
        'outdoor-backup-modal',
        'outdoor-backup-modal-content',
        'outdoor-backup-modal-header',
        'outdoor-backup-modal-close',
        'outdoor-backup-modal-body',
        'outdoor-backup-modal-footer'
    ];
    var index;
    var id;
    var markup;
    var opening;
    var closeAndFooterIds = ['alias-modal', 'cleanup-preview-modal', 'cleanup-confirm-modal'];

    beginCase('M01', 'status modal selectors and all four dialog templates avoid generic modal classes');
    assert(mediaStart !== -1, 'the 768px responsive breakpoint remains present');
    assert(!/\.modal[\w-]*/.test(styles), 'status-page CSS defines no generic modal* selector');
    for (index = 0; index < requiredClasses.length; index += 1) {
        assertIncludes(baseStyles, '.' + requiredClasses[index], 'base CSS uses ' + requiredClasses[index]);
    }
    assertIncludes(baseStyles, '.outdoor-backup-modal-close:hover', 'close hover uses the dedicated class');
    assertIncludes(mediaStyles, '.outdoor-backup-modal-content', '768px media query uses the dedicated content class');
    assertExcludes(mediaStyles, '.modal-content', '768px media query has no generic content selector');
    assertIncludes(scriptMatch[1], "classList.contains('outdoor-backup-modal')", 'backdrop handler checks the dedicated class');
    assertExcludes(scriptMatch[1], "classList.contains('modal')", 'backdrop handler no longer checks the generic class');

    for (index = 0; index < modalIds.length; index += 1) {
        id = modalIds[index];
        markup = extractModalMarkup(id);
        opening = markup.match(new RegExp('<div id="' + id + '" class="([^"]*)">'));
        assert(!!opening && opening[1] === 'outdoor-backup-modal', id + ' retains its ID and dedicated overlay class');
        assert(hasClass(markup, 'outdoor-backup-modal-content'), id + ' uses the dedicated content class');
        assert(hasClass(markup, 'outdoor-backup-modal-header'), id + ' uses the dedicated header class');
        assert(hasClass(markup, 'outdoor-backup-modal-body'), id + ' uses the dedicated body class');
        assert(!hasGenericModalClass(markup), id + ' has no generic modal* class');
    }
    for (index = 0; index < closeAndFooterIds.length; index += 1) {
        id = closeAndFooterIds[index];
        markup = extractModalMarkup(id);
        assert(hasClass(markup, 'outdoor-backup-modal-close'), id + ' retains its dedicated close class');
        assert(hasClass(markup, 'outdoor-backup-modal-footer'), id + ' retains its dedicated footer class');
    }
    markup = extractModalMarkup('cleanup-progress-modal');
    assert(!hasClass(markup, 'outdoor-backup-modal-close') &&
        !hasClass(markup, 'outdoor-backup-modal-footer'),
        'progress dialog does not gain close or footer controls');
}

function caseHistoryEditOpensAliasModal() {
    var page = createPage();
    var history = page.document.getElementById('history-table');
    var action;
    var overlay;

    beginCase('M02', 'clicking a rendered history Edit action fills the alias fields and opens its modal');
    assert(page.document.getElementById('missing-template-id') === null,
        'DOM double returns null for IDs absent from status.htm HTML');
    page.context.updateHistoryTable([{
        uuid: '11111111-1111-1111-1111-111111111111',
        name: 'Edited Card',
        last_backup_at: 0,
        bytes_total: 0,
        status: 'completed'
    }]);
    action = history.innerHTML.match(/onclick="([^"]+)"/);
    assert(!!action, 'history table renders an Edit action');
    if (action) vm.runInNewContext(action[1], page.context, {filename: pagePath});

    assert(page.document.getElementById('alias-input').value === 'Edited Card', 'Edit preserves the alias input value');
    assert(page.document.getElementById('alias-notes').value === '', 'Edit initializes the notes input');
    assert(page.document.getElementById('alias-uuid-hidden').value === '11111111-1111-1111-1111-111111111111',
        'Edit preserves the hidden UUID value');
    assert(page.document.getElementById('alias-modal').style.display === 'block',
        "showModal('alias-modal') still opens the alias dialog");

    overlay = page.document.getElementById('alias-modal');
    page.context.window.onclick({target: createElement('outdoor-backup-modal-content')});
    assert(overlay.style.display === 'block', 'clicking inside the alias dialog does not close it');
    page.context.window.onclick({target: overlay});
    assert(overlay.style.display === 'none', 'clicking the alias backdrop closes it');
}

function caseCleanupFlowAndBackdropBehaviorRemain() {
    var page = createPage();
    var preview = page.document.getElementById('cleanup-preview-modal');
    var confirm = page.document.getElementById('cleanup-confirm-modal');
    var progress = page.document.getElementById('cleanup-progress-modal');
    var confirmationInput = page.document.getElementById('confirm-text-input');
    var confirmationCheckbox = page.document.getElementById('confirm-checkbox');
    var executeButton = page.document.getElementById('execute-cleanup-btn');
    var index;
    var overlay;

    beginCase('M03', 'cleanup confirmation transitions and all four backdrop click boundaries remain intact');
    page.context.showCleanupPreview();
    assert(preview.style.display === 'block', 'cleanup preview opens under its original ID');
    page.context.showCleanupConfirm();
    assert(preview.style.display === 'none' && confirm.style.display === 'block',
        'cleanup confirmation replaces the preview dialog');
    assert(confirmationInput.value === '' && confirmationCheckbox.checked === false && executeButton.disabled === true,
        'opening confirmation resets both requirements and keeps the action disabled');

    confirmationInput.value = '清空备份数据';
    confirmationCheckbox.checked = true;
    page.context.validateCleanupConfirm();
    assert(executeButton.disabled === false, 'correct text and checked confirmation enable cleanup');
    confirmationCheckbox.checked = false;
    page.context.validateCleanupConfirm();
    assert(executeButton.disabled === true, 'unchecking confirmation disables cleanup again');
    confirmationCheckbox.checked = true;
    page.context.validateCleanupConfirm();
    page.context.executeCleanup();
    assert(confirm.style.display === 'none' && progress.style.display === 'block',
        'confirmed cleanup advances to the progress dialog under its original ID');
    assert(page.postCalls.length === 1, 'correct confirmation sends exactly one cleanup request');
    assert(page.postCalls.length === 1 && page.postCalls[0].url.indexOf('/api/cleanup/execute') !== -1,
        'cleanup request targets the execute endpoint');
    var requestBody = page.postCalls.length === 1 ? JSON.parse(page.postCalls[0].data) : {};
    assert(requestBody.confirm_text === '清空备份数据', 'cleanup request carries the exact confirmation text');

    confirmationInput.value = 'incorrect confirmation';
    page.context.executeCleanup();
    assert(page.postCalls.length === 1, 'incorrect confirmation does not send another cleanup request');

    for (index = 0; index < modalIds.length; index += 1) {
        overlay = page.document.getElementById(modalIds[index]);
        page.context.showModal(modalIds[index]);
        page.context.window.onclick({target: createElement('outdoor-backup-modal-content')});
        assert(overlay.style.display === 'block', modalIds[index] + ' stays open after an inner click');
        page.context.window.onclick({target: overlay});
        assert(overlay.style.display === 'none', modalIds[index] + ' closes after a backdrop click');
    }
}

function runCase(id, description, testCase) {
    try {
        testCase();
    } catch (error) {
        fail('CASE ' + id + ' threw: ' + error.stack);
    }
}

runCase('M01', 'CSS and markup isolation', caseModalCssAndMarkupAreIsolated);
runCase('M02', 'history Edit behavior', caseHistoryEditOpensAliasModal);
runCase('M03', 'cleanup flow and backdrop behavior', caseCleanupFlowAndBackdropBehaviorRemain);

console.log('RESULT cases=' + cases + ' assertions=' + assertions + ' failed=' + failures);
if (cases !== 3) {
    console.error('FAIL: expected 3 cases, ran ' + cases);
    process.exitCode = 1;
}
if (assertions !== 66) {
    console.error('FAIL: expected 66 assertions, ran ' + assertions);
    process.exitCode = 1;
}
if (failures !== 0) process.exitCode = 1;
