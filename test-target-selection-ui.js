/*
 * Execute the production template script against a minimal DOM double.
 * This is a Node regression check, not a browser E2E test.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const TEMPLATE_PATH = path.resolve(
    __dirname,
    'luci-app-outdoor-backup/luasrc/view/outdoor-backup/target-selection.htm'
);
const SELECTOR_ID = 'cbid.outdoor-backup.config._target_selector';
const SELECTED_VALUE = '7:SSD-ONE/mnt/ssd';
const SELECTED_ROOT = '/mnt/ssd/SDMirrors';
const MANUAL_SUMMARY = 'Manual mode: the fields below are saved as entered.';
const SELECTED_SUMMARY = 'Selected target will save backup root: ';
const FIELD_NAMES = [ 'target_mount', 'target_uuid', 'backup_root' ];
const ORIGINAL_FIELD_VALUES = {
    target_mount: 'original mount value',
    target_uuid: 'original UUID value',
    backup_root: 'original backup root value'
};

const sourceTemplate = fs.readFileSync(TEMPLATE_PATH, 'utf8');
const scriptMatch = sourceTemplate.match(/<script\b[^>]*>([\s\S]*?)<\/script>/i);
assert.ok(scriptMatch, `No script element found in ${TEMPLATE_PATH}`);

const productionScript = scriptMatch[1]
    .replace(/<%=pcdata\(cbid\)%>/g, SELECTOR_ID)
    .replace(/<%=pcdata\(section\)%>/g, 'config');
assert.ok(!productionScript.includes('<%'), 'Unexpanded template marker remains in extracted script');

/**
 * Create a fresh minimal DOM double and execute the extracted production script.
 * @param {Object<string, string>} roots Root paths keyed by selector value.
 * @returns {Object} Fixture elements and captured load/change listener invokers.
 */
function createFixture(roots) {
    const elements = new Map();
    const body = { tagName: 'BODY', className: '', parentNode: null };
    const selectorRow = {
        tagName: 'DIV',
        className: 'cbi-value',
        style: { display: '' },
        parentNode: body
    };
    const manualRows = Object.create(null);
    const manualFields = Object.create(null);
    let loadListener = null;
    let changeListener = null;

    function makeElement(tagName, id, parentNode) {
        return {
            tagName,
            id,
            className: '',
            style: { display: '' },
            parentNode,
            addEventListener(eventName, listener) {
                assert.equal(eventName, 'change', 'Only the selector change listener is expected');
                changeListener = listener;
            }
        };
    }

    const usesUiWidget = sourceTemplate.includes('data-ui-widget');
    let selector;
    let actualSelect;
    if (usesUiWidget) {
        selector = makeElement('DIV', SELECTOR_ID, selectorRow);
        actualSelect = makeElement('SELECT', `widget.${SELECTOR_ID}`, selectorRow);
        actualSelect.value = 'manual';
        assert.equal(selector.tagName, 'DIV', 'data-ui-widget control must be represented by a DIV');
        assert.ok(!('value' in selector), 'data-ui-widget DIV must not expose a value property');
        elements.set(SELECTOR_ID, selector);
        elements.set(actualSelect.id, actualSelect);
    } else {
        assert.match(sourceTemplate, /<select\b/i, 'Template without data-ui-widget must contain a native SELECT');
        selector = makeElement('SELECT', SELECTOR_ID, selectorRow);
        selector.value = 'manual';
        actualSelect = selector;
        elements.set(SELECTOR_ID, selector);
    }

    const data = {
        parentNode: body,
        getAttribute(attributeName) {
            assert.equal(attributeName, 'data-roots', 'Production script must read data-roots');
            return JSON.stringify(roots);
        }
    };
    const summary = { textContent: '', parentNode: body };
    Object.defineProperty(summary, 'innerHTML', {
        set() {
            throw new Error('Unexpected HTML injection through summary.innerHTML');
        }
    });
    elements.set(`${SELECTOR_ID}-selection-data`, data);
    elements.set(`${SELECTOR_ID}-selection-summary`, summary);

    for (const fieldName of FIELD_NAMES) {
        const row = {
            tagName: 'DIV',
            className: 'cbi-value',
            style: { display: '' },
            parentNode: body
        };
        const wrapper = { tagName: 'DIV', className: '', parentNode: row };
        const fieldId = `cbid.outdoor-backup.config.${fieldName}`;
        const field = {
            tagName: 'INPUT',
            id: fieldId,
            value: ORIGINAL_FIELD_VALUES[fieldName],
            parentNode: wrapper
        };
        manualRows[fieldName] = row;
        manualFields[fieldName] = field;
        elements.set(fieldId, field);
    }

    const document = {
        body,
        getElementById(elementId) {
            return elements.get(elementId) || null;
        }
    };
    const window = {
        addEventListener(eventName, listener) {
            assert.equal(eventName, 'load', 'Production script must register a load listener');
            loadListener = listener;
        }
    };

    vm.runInNewContext(productionScript, { document, window }, { filename: TEMPLATE_PATH });
    assert.equal(typeof loadListener, 'function', 'Production script did not register its load listener');

    return {
        actualSelect,
        manualFields,
        manualRows,
        summary,
        fireLoad() {
            loadListener();
        },
        fireChange() {
            assert.equal(typeof changeListener, 'function', 'Production script did not register its change listener');
            changeListener();
        }
    };
}

/**
 * Return the displayed state of all manual input rows.
 * @param {Object<string, Object>} rows Manual field rows keyed by field name.
 * @returns {string[]} Each row's current display value.
 */
function rowDisplays(rows) {
    return FIELD_NAMES.map((fieldName) => rows[fieldName].style.display);
}

/**
 * Return the current values of all manual fields.
 * @param {Object<string, Object>} fields Manual fields keyed by field name.
 * @returns {Object<string, string>} Field values keyed by field name.
 */
function fieldValues(fields) {
    return Object.fromEntries(FIELD_NAMES.map((fieldName) => [ fieldName, fields[fieldName].value ]));
}

const cases = [
    {
        name: '1 load Manual',
        run() {
            const fixture = createFixture({ [SELECTED_VALUE]: SELECTED_ROOT });
            fixture.fireLoad();
            assert.deepEqual(rowDisplays(fixture.manualRows), [ '', '', '' ], 'Manual fields must remain visible on load');
            assert.equal(fixture.summary.textContent, MANUAL_SUMMARY, 'Manual mode summary must be shown on load');
        }
    },
    {
        name: '2 change to SSD target',
        run() {
            const fixture = createFixture({ [SELECTED_VALUE]: SELECTED_ROOT });
            fixture.fireLoad();
            fixture.actualSelect.value = SELECTED_VALUE;
            fixture.fireChange();
            assert.equal(fixture.summary.textContent, `${SELECTED_SUMMARY}${SELECTED_ROOT}`, 'Selected target summary must contain its backup root');
            assert.deepEqual(rowDisplays(fixture.manualRows), [ 'none', 'none', 'none' ], 'Manual fields must be hidden for a selected target');
        }
    },
    {
        name: '3 switch back to Manual',
        run() {
            const fixture = createFixture({ [SELECTED_VALUE]: SELECTED_ROOT });
            fixture.fireLoad();
            fixture.actualSelect.value = SELECTED_VALUE;
            fixture.fireChange();
            fixture.actualSelect.value = 'manual';
            fixture.fireChange();
            assert.deepEqual({
                summary: fixture.summary.textContent,
                rowDisplays: rowDisplays(fixture.manualRows),
                fieldValues: fieldValues(fixture.manualFields)
            }, {
                summary: MANUAL_SUMMARY,
                rowDisplays: [ '', '', '' ],
                fieldValues: ORIGINAL_FIELD_VALUES
            }, 'Switching back to Manual must restore visibility, summary, and original field values');
        }
    },
    {
        name: '4 empty roots Manual',
        run() {
            const fixture = createFixture({});
            fixture.fireLoad();
            assert.equal(fixture.summary.textContent, MANUAL_SUMMARY, 'Empty roots must not change the Manual summary');
            assert.deepEqual(rowDisplays(fixture.manualRows), [ '', '', '' ], 'Manual fields must remain visible with empty roots');
        }
    },
    {
        name: '5 textContent preserves hostile root literally',
        run() {
            const hostileRoot = '<img src=x onerror=evil()>&"';
            const fixture = createFixture({ [SELECTED_VALUE]: hostileRoot });
            fixture.fireLoad();
            fixture.actualSelect.value = SELECTED_VALUE;
            fixture.fireChange();
            assert.equal(fixture.summary.textContent, `${SELECTED_SUMMARY}${hostileRoot}`, 'Hostile root must be written as literal summary text');
        }
    }
];

let passed = 0;
let failed = 0;
for (const testCase of cases) {
    try {
        testCase.run();
        passed += 1;
        console.log(`PASS ${testCase.name}`);
    } catch (error) {
        failed += 1;
        const message = error && error.message ? error.message.split('\n')[0] : String(error);
        console.log(`FAIL ${testCase.name}: ${message}`);
    }
}

console.log(`cases=${cases.length} passed=${passed} failed=${failed}`);
if (failed > 0) {
    process.exitCode = 1;
}
