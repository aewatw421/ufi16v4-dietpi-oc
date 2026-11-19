#!/usr/bin/env node
// Verify that the built device tree really contains the overclock tiers.
//
// dtc renders 64-bit /bits/ 64 <...> cells in its own notation, so matching a
// literal "1996800000" in the decompiled text does not work. Parse the values
// out instead and compare numbers.
//
// Usage: check-opp.js <decompiled.dts> [expected-hz ...]
'use strict';

const fs = require('fs');

const file = process.argv[2];
const expected = process.argv.slice(3).map(Number).filter(n => n > 0);

const DEFAULTS = [1401600000, 1612800000, 1804800000, 1996800000];
const want = expected.length ? expected : DEFAULTS;

if (!file || !fs.existsSync(file)) {
	console.error(`check-opp: no such file: ${file}`);
	process.exit(2);
}

const text = fs.readFileSync(file, 'utf8');

// Collect every "opp-hz = /bits/ 64 <cells...>" and rebuild the 64-bit value.
const values = [];
// dtc drops the /bits/ 64 annotation when emitting DTS, so match the property
// whether or not it is present.
const re = /opp-hz\s*=\s*(?:\/bits\/\s*64\s*)?<([^>]*)>/g;
let m;
while ((m = re.exec(text)) !== null) {
	// dtc renders the 64-bit value either as one cell, two 32-bit cells, or a
	// run of byte-sized cells (0x77 0x04 0xc0 0x00). Handle each shape.
	const cells = m[1].trim().split(/\s+/).filter(Boolean).map(s => BigInt(s));
	let v;
	if (cells.length === 1) {
		v = cells[0];
	} else if (cells.length === 2) {
		v = (cells[0] << 32n) | cells[1];
	} else {
		// byte-wise, most significant first, padded to 8 bytes on the left
		v = 0n;
		for (const c of cells) v = (v << 8n) | c;
	}
	values.push(Number(v));
}

const unique = [...new Set(values)].sort((a, b) => a - b);
console.log(`check-opp: ${unique.length} distinct opp-hz values`);
console.log(`  ${unique.map(v => `${(v / 1e6).toFixed(1)}MHz`).join(' ')}`);

const missing = want.filter(w => !values.includes(w));
if (missing.length) {
	console.error(`check-opp: MISSING tiers: ${missing.map(v => `${(v / 1e6).toFixed(1)}MHz`).join(' ')}`);
	process.exit(1);
}

console.log(`check-opp: OK, all requested tiers present`);
