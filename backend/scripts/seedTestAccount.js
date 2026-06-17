'use strict';

/*
 * Seed a fully-populated TEST ACCOUNT for manual testing of the v7 features.
 *
 * Talks to a RUNNING backend over HTTP (so it works with USE_MEMORY_DB too, and
 * can target any deployment), exactly the way the app would: register/login the
 * owner, create accountant sub-accounts, then push a full dataset into the
 * account's sync mirror. Log in on the app as the test account and pull.
 *
 *   # backend running on :4000 (npm run dev), then:
 *   npm run seed:demo
 *   # or against another host / creds:
 *   BASE_URL=https://your-host node scripts/seedTestAccount.js
 *
 * Test account ........ 07701234567 / 1234   (owner, active multi-branch plan)
 * Accountants ......... 07700000001 / 1234   (branch: Main, all permissions)
 *                       07700000002 / 1234   (branch: Karkh, receipts+expenses)
 *
 * Data: 3 branches, 9 boards, 27 circuits, 100 subscribers across the three
 * categories (gold / standard / commercial), per-category monthly prices for
 * the current AND previous month, ~half the current month collected (so
 * paid/unpaid is mixed), and a dozen expenses.
 *
 * Re-runnable: every row has a deterministic id, and push upserts by
 * (account, entity, localId), so running it again refreshes rather than dupes.
 */

const BASE_URL = process.env.BASE_URL || 'http://localhost:4000';
const ADMIN_USERNAME = process.env.ADMIN_USERNAME || 'admin';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'admin123';

const OWNER = { username: '07701234567', password: '1234', name: 'حساب تجريبي', generatorName: 'مولدة الاختبار' };
const ACCOUNTANTS = [
  { localId: 'acct-1', username: '07700000001', password: '1234', name: 'محاسب الكرخ', branchId: 'main', permissions: ['subscribers', 'boards', 'expenses', 'prices'] },
  { localId: 'acct-2', username: '07700000002', password: '1234', name: 'محاسب الرصافة', branchId: 'br-karkh', permissions: ['subscribers', 'expenses'] },
];

const CATEGORIES = ['gold', 'standard', 'commercial'];
const PRICE = { gold: 2000, standard: 1000, commercial: 1500 };

const BRANCHES = [
  { id: 'main', name: 'الفرع الرئيسي', code: 'MAIN', is_main: 1 },
  { id: 'br-karkh', name: 'فرع الكرخ', code: 'KRH', is_main: 0 },
  { id: 'br-rusafa', name: 'فرع الرصافة', code: 'RSF', is_main: 0 },
];

function ym(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}
const now = new Date();
const CUR_MONTH = ym(now);
const PREV_MONTH = ym(new Date(now.getFullYear(), now.getMonth() - 1, 1));

async function api(method, path, { token, body } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const res = await fetch(`${BASE_URL}${path}`, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  let data = null;
  try { data = await res.json(); } catch { /* no body */ }
  return { status: res.status, data };
}

async function main() {
  console.log(`[seed] target ${BASE_URL}`);

  // 1. Admin: ensure a 'demo' plan with ALL features incl. multiBranch.
  const adminLogin = await api('POST', '/api/auth/login', {
    body: { username: ADMIN_USERNAME, password: ADMIN_PASSWORD, device: { deviceId: 'seed-admin' } },
  });
  if (adminLogin.status !== 200) throw new Error(`admin login failed: ${adminLogin.status} ${JSON.stringify(adminLogin.data)}`);
  const adminToken = adminLogin.data.token;

  const plan = await api('PUT', '/api/admin/plans', {
    token: adminToken,
    body: {
      code: 'demo', name: 'Demo (all features)', price: 0, durationDays: 3650,
      maxDevices: 5, syncEnabled: true, backupEnabled: true, ownerPanelEnabled: true, multiBranchEnabled: true,
    },
  });
  console.log(`[seed] demo plan upsert -> ${plan.status}`);

  // 2. Owner: register (or login if it already exists).
  let ownerToken; let ownerId;
  const reg = await api('POST', '/api/auth/register', {
    body: { name: OWNER.name, generatorName: OWNER.generatorName, phone: OWNER.username, username: OWNER.username, password: OWNER.password, device: { deviceId: 'seed-owner' } },
  });
  if (reg.status === 201) {
    ownerToken = reg.data.token; ownerId = reg.data.account.id;
    console.log('[seed] owner registered');
  } else {
    const login = await api('POST', '/api/auth/login', {
      body: { username: OWNER.username, password: OWNER.password, device: { deviceId: 'seed-owner' } },
    });
    if (login.status !== 200) throw new Error(`owner register/login failed: reg ${reg.status} ${JSON.stringify(reg.data)}; login ${login.status} ${JSON.stringify(login.data)}`);
    ownerToken = login.data.token; ownerId = login.data.account.id;
    console.log('[seed] owner already existed -> logged in');
  }

  // 3. Activate the demo plan on the owner (active multi-branch subscription).
  const setPlan = await api('PUT', `/api/admin/users/${ownerId}/plan`, {
    token: adminToken, body: { planCode: 'demo', status: 'active' },
  });
  console.log(`[seed] owner plan=demo active -> ${setPlan.status}`);

  // 4. Accountant sub-accounts (idempotent: ignore 409 USERNAME_TAKEN).
  for (const a of ACCOUNTANTS) {
    const r = await api('POST', '/api/account/accountants', {
      token: ownerToken,
      body: { name: a.name, username: a.username, password: a.password, branchId: a.branchId, permissions: a.permissions, localId: a.localId },
    });
    console.log(`[seed] accountant ${a.username} -> ${r.status}${r.status === 409 ? ' (exists)' : ''}`);
  }

  // 5. Build the mirror dataset.
  const records = [];
  const push = (entity, localId, data) => records.push({ entity, localId, deleted: false, updatedAt: new Date().toISOString(), data });

  // branches
  for (const b of BRANCHES) push('branches', b.id, { id: b.id, name: b.name, code: b.code, is_main: b.is_main, active: 1 });

  // accountant identity rows (so they appear in the app's accountants list)
  for (const a of ACCOUNTANTS) push('accountants', a.localId, { id: a.localId, username: a.username, name: a.name, active: 1, permissions: a.permissions.join(',') });

  // boards + circuits per branch
  const circuitsByBranch = {}; // branchId -> [{boardId, circuitId}]
  for (const b of BRANCHES) {
    circuitsByBranch[b.id] = [];
    for (let bd = 1; bd <= 3; bd++) {
      const boardId = `${b.id}-bd${bd}`;
      push('boards', boardId, { id: boardId, name: `لوحة ${bd} - ${b.name}`, code: `${b.code}-${bd}`, branch_id: b.id });
      for (let c = 1; c <= 3; c++) {
        const circuitId = `${boardId}-c${c}`;
        push('circuits', circuitId, { id: circuitId, board_id: boardId, name: `جوزة ${c}`, phase: `${c}`, branch_id: b.id });
        circuitsByBranch[b.id].push({ boardId, circuitId });
      }
    }
  }

  // monthly prices: current + previous month, per branch, per category
  for (const month of [CUR_MONTH, PREV_MONTH]) {
    for (const b of BRANCHES) {
      for (const cat of CATEGORIES) {
        const id = `${month}|${b.id}|${cat}`;
        push('monthly_prices', id, { id, month, price_per_amp: PRICE[cat], locked: 0, branch_id: b.id, category: cat });
      }
    }
  }

  // 100 subscribers spread across branches/boards/circuits + categories
  const branchIds = BRANCHES.map((b) => b.id);
  const subs = [];
  for (let i = 1; i <= 100; i++) {
    const branchId = branchIds[i % branchIds.length];
    const slot = circuitsByBranch[branchId][i % circuitsByBranch[branchId].length];
    const category = CATEGORIES[i % CATEGORIES.length];
    const amps = 5 + (i % 26); // 5..30
    const id = `sub-${String(i).padStart(4, '0')}`;
    push('subscribers', id, {
      id, name: `مشترك ${i}`, phone: `0770${String(1000000 + i)}`, amps,
      board_id: slot.boardId, circuit_id: slot.circuitId, status: 'active',
      category, branch_id: branchId,
    });
    subs.push({ id, amps, category, branchId });
  }

  // receipts: collect the CURRENT month for ~half the subscribers (even index)
  // -> mixed paid/unpaid; attribute some to accountants.
  const receiptNoByBranch = {};
  let n = 0;
  for (const s of subs) {
    n++;
    if (n % 2 !== 0) continue; // only half are paid
    receiptNoByBranch[s.branchId] = (receiptNoByBranch[s.branchId] || 0) + 1;
    const price = PRICE[s.category];
    const paid = s.amps * price;
    const uuid = `rcpt-${s.id}-${CUR_MONTH}`;
    const acctId = s.branchId === 'main' ? 'acct-1' : (s.branchId === 'br-karkh' ? 'acct-2' : null);
    push('receipts', uuid, {
      uuid, receipt_no: receiptNoByBranch[s.branchId], subscriber_id: s.id, month: CUR_MONTH,
      amps_snapshot: s.amps, price_snapshot: price, paid_amount: paid, remaining_after: 0,
      accountant_id: acctId, branch_id: s.branchId, category_snapshot: s.category,
      issued_at: `${CUR_MONTH}-05T08:00:00.000Z`, status: 'valid',
    });
  }

  // expenses: a dozen across branches + both months
  const EXP_CATS = ['fuel', 'maintenance', 'salaries', 'misc'];
  for (let i = 1; i <= 12; i++) {
    const branchId = branchIds[i % branchIds.length];
    const month = i % 3 === 0 ? PREV_MONTH : CUR_MONTH;
    const id = `exp-${String(i).padStart(2, '0')}`;
    push('expenses', id, {
      id, category: EXP_CATS[i % EXP_CATS.length], amount: 50000 + i * 1000,
      note: `مصروف ${i}`, date: `${month}-1${i % 9}T10:00:00.000Z`, branch_id: branchId,
      accountant_id: branchId === 'main' ? 'acct-1' : null,
    });
  }

  // 6. Push in chunks of 100.
  console.log(`[seed] pushing ${records.length} mirror records...`);
  for (let i = 0; i < records.length; i += 100) {
    const chunk = records.slice(i, i + 100);
    const r = await api('POST', '/api/sync/push', { token: ownerToken, body: { records: chunk } });
    if (r.status !== 200) throw new Error(`push failed at ${i}: ${r.status} ${JSON.stringify(r.data)}`);
  }

  console.log('\n[seed] DONE ✅');
  console.log(`  owner   : ${OWNER.username} / ${OWNER.password}`);
  console.log(`  accts   : ${ACCOUNTANTS.map((a) => a.username).join(', ')} / ${OWNER.password}`);
  console.log(`  data    : ${BRANCHES.length} branches, 9 boards, 27 circuits, 100 subscribers (gold/standard/commercial),`);
  console.log(`            prices ${PREV_MONTH} + ${CUR_MONTH} (3 categories/branch), ~50 paid receipts (${CUR_MONTH}), 12 expenses.`);
  console.log('  Log in on the app as the owner and PULL (dashboard update button) to load it.');
}

main().catch((e) => { console.error('[seed] FAILED:', e.message); process.exit(1); });
