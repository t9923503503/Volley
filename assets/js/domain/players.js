'use strict';

// Player store and roster sync helpers.

function loadPlayerDB() {
  try { return JSON.parse(localStorage.getItem('kotc3_playerdb') || '[]'); } catch(e){ return []; }
}
function savePlayerDB(db) {
  localStorage.setItem('kotc3_playerdb', JSON.stringify(db));
}
function remapPlayerIdInTournaments(oldId, newId) {
  if (oldId === newId) return;
  const arr = getTournaments();
  let changed = false;
  const mapIds = ids => {
    if (!Array.isArray(ids)) return ids;
    let localChanged = false;
    const next = ids.map(id => {
      if (id === oldId) { localChanged = true; return newId; }
      return id;
    });
    changed = changed || localChanged;
    return next;
  };
  arr.forEach(t => {
    t.participants = mapIds(t.participants);
    t.waitlist     = mapIds(t.waitlist);
    if (Array.isArray(t.winners)) {
      t.winners = t.winners.map(w => {
        if (!w || typeof w !== 'object' || !Array.isArray(w.playerIds)) return w;
        return { ...w, playerIds: mapIds(w.playerIds) };
      });
    }
    if (Array.isArray(t.history)) {
      t.history = t.history.map(entry => {
        if (!entry || typeof entry !== 'object') return entry;
        if (!Array.isArray(entry.winnersSnapshot)) return entry;
        return {
          ...entry,
          winnersSnapshot: entry.winnersSnapshot.map(w => {
            if (!w || typeof w !== 'object' || !Array.isArray(w.playerIds)) return w;
            return { ...w, playerIds: mapIds(w.playerIds) };
          })
        };
      });
    }
  });
  if (changed) saveTournaments(arr);
}
function upsertPlayerInDB(player) {
  const name   = (player?.name || '').trim();
  const gender = player?.gender || 'M';
  if (!name) return null;

  const db = loadPlayerDB();
  let existing = player.id != null ? db.find(p => String(p.id) === String(player.id)) : null;
  if (!existing) {
    existing = db.find(p => p.name.toLowerCase() === name.toLowerCase() && p.gender === gender);
  }

  if (existing) {
    const oldId = existing.id;
    if (player.id != null) existing.id = player.id;
    existing.name   = name;
    existing.gender = gender;
    if (player.status) existing.status = player.status;
    if (player.addedAt) existing.addedAt = player.addedAt;
    if (player.tournaments != null) existing.tournaments = player.tournaments;
    if (player.tournaments_played != null) existing.tournaments = player.tournaments_played;
    if (player.totalPts != null) existing.totalPts = player.totalPts;
    if (player.total_pts != null) existing.totalPts = player.total_pts;
    if (player.wins != null) existing.wins = player.wins;
    if (player.lastSeen != null) existing.lastSeen = player.lastSeen;
    ['ratingM','ratingW','ratingMix','tournamentsM','tournamentsW','tournamentsMix']
      .forEach(key => {
        if (player[key] != null) existing[key] = player[key];
        else if (existing[key] == null) existing[key] = 0;
      });
    if (existing.addedAt == null) existing.addedAt = new Date().toISOString().split('T')[0];
    if (existing.tournaments == null) existing.tournaments = 0;
    if (existing.totalPts == null) existing.totalPts = 0;
    if (existing.wins == null) existing.wins = 0;

    savePlayerDB(db);
    if (oldId !== existing.id) remapPlayerIdInTournaments(oldId, existing.id);
    return existing;
  }

  const created = {
    id: player.id ?? (Date.now() + Math.random()),
    name,
    gender,
    status: player.status || 'active',
    addedAt: player.addedAt || new Date().toISOString().split('T')[0],
    tournaments: player.tournaments ?? player.tournaments_played ?? 0,
    totalPts: player.totalPts ?? player.total_pts ?? 0,
    wins: player.wins ?? 0,
    ratingM: player.ratingM ?? 0,
    ratingW: player.ratingW ?? 0,
    ratingMix: player.ratingMix ?? 0,
    tournamentsM: player.tournamentsM ?? 0,
    tournamentsW: player.tournamentsW ?? 0,
    tournamentsMix: player.tournamentsMix ?? 0,
    lastSeen: player.lastSeen || '',
  };
  db.push(created);
  savePlayerDB(db);
  return created;
}
function addPlayerToDB(name, gender) {
  name = name.trim();
  if (!name) return false;
  const db = loadPlayerDB();
  if (db.find(p => p.name.toLowerCase() === name.toLowerCase() && p.gender === gender)) return false;
  db.push({ id: Date.now() + Math.random(), name, gender,
            addedAt: new Date().toISOString().split('T')[0],
            tournaments: 0, totalPts: 0, wins: 0,
            ratingM: 0, ratingW: 0, ratingMix: 0,
            tournamentsM: 0, tournamentsW: 0, tournamentsMix: 0,
            lastSeen: '' });
  savePlayerDB(db);
  return true;
}
function removePlayerFromDB(id) {
  const db = loadPlayerDB().filter(p => p.id !== id);
  savePlayerDB(db);
}
// Called on finishTournament — upserts all players with their results
function syncPlayersFromTournament(players, date) {
  const db = loadPlayerDB();
  players.forEach(p => {
    const existing = db.find(d => d.name.toLowerCase() === p.name.toLowerCase() && d.gender === p.gender);
    if (existing) {
      existing.tournaments = (existing.tournaments || 0) + 1;
      existing.totalPts    = (existing.totalPts    || 0) + (p.totalPts || 0);
      existing.lastSeen    = date;
    } else {
      db.push({ id: Date.now() + Math.random(), name: p.name, gender: p.gender,
                addedAt: date, tournaments: 1, totalPts: p.totalPts || 0, lastSeen: date });
    }
  });
  savePlayerDB(db);
}
// Import names currently in the roster inputs (without score data)
function syncPlayersFromRoster() {
  const date = new Date().toISOString().split('T')[0];
  let added = 0;
  for (let ci = 0; ci < nc; ci++) {
    ALL_COURTS[ci].men.forEach(n => { if (n.trim() && addPlayerToDB(n.trim(), 'M')) added++; });
    ALL_COURTS[ci].women.forEach(n => { if (n.trim() && addPlayerToDB(n.trim(), 'W')) added++; });
  }
  return added;
}
