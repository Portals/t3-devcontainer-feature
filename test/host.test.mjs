import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseJSONC } from '../scripts/jsonc.mjs';

test('migration parser preserves URLs, escaped strings, and literal comment text', () => {
    const source = String.raw`{
        // before the object
        "url": "https://example.test/a//b",
        "literal": "/* not a comment */ ,}",
        "quote": "a\"//b", /* real comment */
        "values": ["a", "b",],
    }`;
    assert.deepEqual(parseJSONC(source), {
        url:'https://example.test/a//b', literal:'/* not a comment */ ,}',quote:'a"//b',values:['a','b']
    });
});
test('migration parser rejects malformed configuration', () => {
    assert.throws(() => parseJSONC('{ /* never closed'));
    assert.throws(() => parseJSONC('{"a": "never closed}'));
});
