'use strict';
/*
 * Flash v21 item 4 — generate a ~1000-subscriber test .backup file that the app
 * can IMPORT via Settings → Local backup → Import (password below).
 *
 * Replicates LocalBackupService's format exactly:
 *   envelope = { v:1, alg:'sha256-ctr', mac:<hex>, ct:<base64> }
 *   key      = sha256(password)
 *   keystream block_i = sha256(key || ctr32be(i)); ct = plaintext XOR keystream
 *   mac      = sha256(key || plaintext)
 *   payload  = { v:1, app:'flash', generatorName, exportedAt,
 *                tables:{ boards:[...], circuits:[...], subscribers:[...] } }
 *
 * Run:  node tools/gen_test_backup.js   ->  tools/TestData.backup
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PASSWORD = '1234'; // import password
const GENERATOR = 'بيانات تجريبية'; // generator name (Arabic, to exercise sorting)
const N_BOARDS = 20;
const CIRCUITS_PER_BOARD = 3;
const TARGET_SUBSCRIBERS = 1000;
const BRANCH = 'main';
const CATEGORIES = ['standard', 'gold', 'commercial'];

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest();
const ctr32be = (n) => Buffer.from([(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);

function xorKeystream(plain, key) {
  const out = Buffer.alloc(plain.length);
  let produced = 0, counter = 0;
  while (produced < plain.length) {
    const block = sha256(Buffer.concat([key, ctr32be(counter)]));
    for (let i = 0; i < block.length && produced < plain.length; i++, produced++) {
      out[produced] = plain[produced] ^ block[i];
    }
    counter++;
  }
  return out;
}

// Monotonic, increasing created_at so rows sort in creation order (oldest first).
let seq = 0;
const startMs = Date.UTC(2026, 0, 1, 0, 0, 0); // fixed base (no Date.now — reproducible)
const nextCreatedAt = () => new Date(startMs + (seq++) * 1000).toISOString();

const boards = [];
const circuits = [];
const subscribers = [];

for (let b = 1; b <= N_BOARDS; b++) {
  const boardId = `tb-${b}`;
  boards.push({
    id: boardId,
    name: `لوحة ${b}`,
    code: `B${b}`,
    accountant_id: null,
    branch_id: BRANCH,
    created_at: nextCreatedAt(),
  });
  for (let c = 1; c <= CIRCUITS_PER_BOARD; c++) {
    const circuitId = `tc-${b}-${c}`;
    circuits.push({
      id: circuitId,
      board_id: boardId,
      name: `جوزة ${b}-${c}`,
      phase: c === 1 ? 'A' : (c === 2 ? 'B' : 'C'),
      accountant_id: null,
      branch_id: BRANCH,
      created_at: nextCreatedAt(),
    });
  }
}

const allCircuits = circuits.slice();
for (let s = 1; s <= TARGET_SUBSCRIBERS; s++) {
  const circ = allCircuits[(s - 1) % allCircuits.length];
  subscribers.push({
    id: `ts-${s}`,
    name: `مشترك ${s}`,
    phone: `0770${String(1000000 + s).slice(-7)}`,
    amps: (s % 10) + 1, // 1..10 A
    board_id: circ.board_id,
    circuit_id: circ.id,
    status: 'active',
    category: CATEGORIES[s % CATEGORIES.length],
    accountant_id: null,
    branch_id: BRANCH,
    created_at: nextCreatedAt(),
  });
}

const payload = {
  v: 1,
  app: 'flash',
  generatorName: GENERATOR,
  exportedAt: new Date(startMs).toISOString(),
  tables: { boards, circuits, subscribers },
};

const plain = Buffer.from(JSON.stringify(payload), 'utf8');
const key = sha256(Buffer.from(PASSWORD, 'utf8'));
const ct = xorKeystream(plain, key);
const mac = sha256(Buffer.concat([key, plain])).toString('hex');
const envelope = JSON.stringify({ v: 1, alg: 'sha256-ctr', mac, ct: ct.toString('base64') });

const outPath = path.join(__dirname, 'TestData.backup');
fs.writeFileSync(outPath, envelope);

// Self-check: decrypt + verify mac (proves the app will accept it).
const ct2 = Buffer.from(JSON.parse(envelope).ct, 'base64');
const plain2 = xorKeystream(ct2, key);
const mac2 = sha256(Buffer.concat([key, plain2])).toString('hex');
const ok = mac2 === mac && plain2.equals(plain);

console.log(`boards=${boards.length} circuits=${circuits.length} subscribers=${subscribers.length}`);
console.log(`password='${PASSWORD}' generator='${GENERATOR}'`);
console.log(`wrote ${outPath} (${envelope.length} bytes) selfCheck=${ok ? 'OK' : 'FAIL'}`);
