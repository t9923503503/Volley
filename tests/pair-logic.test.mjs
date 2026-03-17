/**
 * Unit-тесты для логики pair mode, partnerW, getPartnerW, customRounds/customTours.
 * Запуск: node tests/pair-logic.test.mjs
 * Не требует браузера или фреймворка.
 */

let passed = 0;
let failed = 0;

function assert(label, condition) {
  if (condition) {
    console.log(`  ✅ ${label}`);
    passed++;
  } else {
    console.error(`  ❌ FAIL: ${label}`);
    failed++;
  }
}

function assertEqual(label, actual, expected) {
  const ok = actual === expected;
  if (ok) {
    console.log(`  ✅ ${label}`);
    passed++;
  } else {
    console.error(`  ❌ FAIL: ${label} → got ${actual}, expected ${expected}`);
    failed++;
  }
}

// ── Симуляция глобальных переменных приложения ─────────────
let ppc = 5;
let pairMode = 'rotation';
let fixedPairs = Array.from({length:4}, (_, ci) => Array.from({length:5}, (_, mi) => mi % 5));
let customRounds = ppc;
let customTours = 1;

function partnerW(mi, ri) { return (mi + ri) % ppc; }

function getPartnerW(ci, mi, ri) {
  if (pairMode === 'fixed') {
    return (fixedPairs[ci] && fixedPairs[ci][mi] != null) ? fixedPairs[ci][mi] : mi % ppc;
  }
  return partnerW(mi, ri);
}

function makeBlankScores() {
  const rounds = customRounds || ppc;
  return Array.from({length:4}, () =>
    Array.from({length:ppc}, () => Array(rounds).fill(null))
  );
}

function setCustomRounds(val) {
  val = Math.max(1, Math.min(10, +val || 1));
  customRounds = val;
}

function setCustomTours(val) {
  customTours = Math.max(1, Math.min(5, +val || 1));
}

// ═══════════════════════════════════════════════════════════
console.log('\n── 1. partnerW (KotC rotation) ──');
{
  // ppc=5: в каждом раунде все пары разные
  ppc = 5;
  for (let ri = 0; ri < ppc; ri++) {
    const partners = new Set();
    for (let mi = 0; mi < ppc; mi++) {
      partners.add(partnerW(mi, ri));
    }
    // В ротации все wi должны быть разными (каждая женщина ровно с одним мужчиной)
    assert(`ppc=5 ri=${ri}: все ${ppc} партнёрш уникальны`, partners.size === ppc);
  }

  // ppc=4
  ppc = 4;
  for (let ri = 0; ri < ppc; ri++) {
    const partners = new Set();
    for (let mi = 0; mi < ppc; mi++) {
      partners.add(partnerW(mi, ri));
    }
    assert(`ppc=4 ri=${ri}: все ${ppc} партнёрш уникальны`, partners.size === ppc);
  }
  ppc = 5; // restore
}

// ═══════════════════════════════════════════════════════════
console.log('\n── 2. getPartnerW — режим ротация ──');
{
  pairMode = 'rotation';
  // Должно совпадать с partnerW
  for (let ri = 0; ri < ppc; ri++) {
    for (let mi = 0; mi < ppc; mi++) {
      assertEqual(`ci=0 mi=${mi} ri=${ri}: getPartnerW===partnerW`, getPartnerW(0, mi, ri), partnerW(mi, ri));
    }
  }
}

// ═══════════════════════════════════════════════════════════
console.log('\n── 3. getPartnerW — режим фикс. пара ──');
{
  pairMode = 'fixed';
  // Назначаем пары: mi=0→wi=2, mi=1→wi=3, mi=2→wi=0, mi=3→wi=4, mi=4→wi=1
  const pairs = [2, 3, 0, 4, 1];
  fixedPairs[0] = [...pairs];

  for (let mi = 0; mi < ppc; mi++) {
    for (let ri = 0; ri < ppc; ri++) {
      assertEqual(`fixed ci=0 mi=${mi} ri=${ri}: всегда wi=${pairs[mi]}`, getPartnerW(0, mi, ri), pairs[mi]);
    }
  }

  // Уникальность пар: каждая женщина назначена ровно одному мужчине
  const assigned = new Set(pairs);
  assert('fixed: все 5 женщин назначены уникально', assigned.size === ppc);
}

// ═══════════════════════════════════════════════════════════
console.log('\n── 4. Стабильность mi в режимах ──');
{
  pairMode = 'rotation';
  // В rotation: mi = (i + ri) % ppc — каждый мужчина показывается ровно 1 раз за раунд
  for (let ri = 0; ri < ppc; ri++) {
    const seen = new Set();
    for (let i = 0; i < ppc; i++) {
      const mi = (i + ri) % ppc;
      seen.add(mi);
    }
    assert(`rotation ri=${ri}: все ppc мужчин уникальны`, seen.size === ppc);
  }

  pairMode = 'fixed';
  // В fixed: mi = i — каждый мужчина показывается ровно 1 раз
  for (let ri = 0; ri < ppc; ri++) {
    const seen = new Set();
    for (let i = 0; i < ppc; i++) {
      const mi = i; // pairMode === 'fixed'
      seen.add(mi);
    }
    assert(`fixed ri=${ri}: все ppc мужчин уникальны`, seen.size === ppc);
  }
}

// ═══════════════════════════════════════════════════════════
console.log('\n── 5. customRounds ──');
{
  customRounds = 5;
  ppc = 5;
  setCustomRounds(3);
  assertEqual('setCustomRounds(3) → 3', customRounds, 3);

  setCustomRounds(0);
  assertEqual('setCustomRounds(0) → clamp to 1', customRounds, 1);

  setCustomRounds(15);
  assertEqual('setCustomRounds(15) → clamp to 10', customRounds, 10);

  setCustomRounds(-5);
  assertEqual('setCustomRounds(-5) → clamp to 1', customRounds, 1);

  // makeBlankScores с customRounds=3
  customRounds = 3;
  ppc = 5;
  const sc = makeBlankScores();
  assertEqual('makeBlankScores: 4 courts', sc.length, 4);
  assertEqual('makeBlankScores: 5 men per court', sc[0].length, 5);
  assertEqual('makeBlankScores: 3 rounds per man', sc[0][0].length, 3);
  assert('makeBlankScores: all null', sc[0][0].every(v => v === null));
}

// ═══════════════════════════════════════════════════════════
console.log('\n── 6. customTours ──');
{
  setCustomTours(3);
  assertEqual('setCustomTours(3) → 3', customTours, 3);

  setCustomTours(0);
  assertEqual('setCustomTours(0) → clamp to 1', customTours, 1);

  setCustomTours(10);
  assertEqual('setCustomTours(10) → clamp to 5', customTours, 5);

  setCustomTours(-1);
  assertEqual('setCustomTours(-1) → clamp to 1', customTours, 1);
}

// ═══════════════════════════════════════════════════════════
console.log('\n── 7. fixedPairs default (mi % ppc) ──');
{
  ppc = 5;
  const fp = Array.from({length:4}, (_, ci) => Array.from({length:ppc}, (_, mi) => mi % ppc));
  for (let ci = 0; ci < 4; ci++) {
    for (let mi = 0; mi < ppc; mi++) {
      assertEqual(`default fixedPairs[${ci}][${mi}]`, fp[ci][mi], mi);
    }
  }
  // При ppc=4
  ppc = 4;
  const fp4 = Array.from({length:4}, (_, ci) => Array.from({length:ppc}, (_, mi) => mi % ppc));
  assert('ppc=4: default pair mi===wi для каждого', fp4[0].every((wi, mi) => wi === mi));
  ppc = 5; // restore
}

// ═══════════════════════════════════════════════════════════
console.log('\n── 8. Смена pairMode не меняет scores ──');
{
  pairMode = 'rotation';
  customRounds = 5;
  ppc = 5;
  const sc1 = makeBlankScores();
  sc1[0][0][0] = 7;

  // Смена режима не затрагивает массив scores
  pairMode = 'fixed';
  assertEqual('pairMode change does not reset scores', sc1[0][0][0], 7);

  pairMode = 'rotation'; // restore
}

// ═══════════════════════════════════════════════════════════
console.log('\n── Итого ──');
console.log(`  Пройдено: ${passed}  Провалено: ${failed}`);
if (failed > 0) process.exit(1);
