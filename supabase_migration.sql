-- ============================================================
-- МИГРАЦИЯ: Модуль регистрации на турниры
-- Пляжный волейбол · King of the Court
-- ============================================================
-- Запустить в Supabase SQL Editor одним блоком.
-- Идемпотентно: повторный запуск не сломает данные.
-- ============================================================

-- ── 0. Расширения ────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- trigram fuzzy search

-- ── 1. PLAYERS ───────────────────────────────────────────────
-- Единый реестр игроков. status отделяет проверенных от "полевых".
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS players (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name            TEXT NOT NULL,
  gender          TEXT NOT NULL CHECK (gender IN ('M', 'W')),
  status          TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'temporary')),
  phone           TEXT,                       -- опционально, для связи
  tournaments_played  INT  DEFAULT 0,
  total_pts       INT  DEFAULT 0,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

-- Уникальность: имя + пол (два "Иванов" разного пола — ОК)
CREATE UNIQUE INDEX IF NOT EXISTS idx_players_name_gender
  ON players (lower(trim(name)), gender);

-- Trigram-индекс для нечёткого поиска по имени
CREATE INDEX IF NOT EXISTS idx_players_name_trgm
  ON players USING gin (name gin_trgm_ops);

-- Индекс для фильтрации по статусу
CREATE INDEX IF NOT EXISTS idx_players_status
  ON players (status);

-- Автообновление updated_at
CREATE OR REPLACE FUNCTION trg_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS players_updated_at ON players;
CREATE TRIGGER players_updated_at
  BEFORE UPDATE ON players
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();


-- ── 2. TOURNAMENTS ───────────────────────────────────────────
-- Без этой таблицы FOR UPDATE бессмысленен:
-- клиент мог бы передать любой capacity, и RPC поверила бы.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tournaments (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name        TEXT NOT NULL,
  date        DATE,
  time        TIME,
  location    TEXT,
  format      TEXT DEFAULT 'King of the Court',
  division    TEXT CHECK (division IN ('Мужской', 'Женский', 'Микст')),
  level       TEXT DEFAULT 'medium'
                CHECK (level IN ('hard', 'medium', 'easy')),
  capacity    INT NOT NULL DEFAULT 24 CHECK (capacity >= 4),
  prize       TEXT,
  status      TEXT DEFAULT 'open'
                CHECK (status IN ('open', 'full', 'finished', 'cancelled')),
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tournaments_status
  ON tournaments (status);

CREATE INDEX IF NOT EXISTS idx_tournaments_date
  ON tournaments (date DESC);


-- ── 3. TOURNAMENT_PARTICIPANTS ───────────────────────────────
-- Связь M:N между турнирами и игроками.
-- is_waitlist = true  →  лист ожидания.
-- position  →  порядок внутри основного/waitlist списка.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tournament_participants (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  tournament_id   UUID NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  player_id       UUID NOT NULL REFERENCES players(id)     ON DELETE CASCADE,
  is_waitlist     BOOLEAN DEFAULT false,
  position        INT NOT NULL DEFAULT 0,
  registered_at   TIMESTAMPTZ DEFAULT now(),

  UNIQUE (tournament_id, player_id)
);

-- Быстрый подсчёт участников турнира
CREATE INDEX IF NOT EXISTS idx_tp_tournament
  ON tournament_participants (tournament_id, is_waitlist);

-- Поиск турниров игрока
CREATE INDEX IF NOT EXISTS idx_tp_player
  ON tournament_participants (player_id);


-- ── 4. PLAYER_REQUESTS ───────────────────────────────────────
-- Очередь модерации для новичков.
-- Одобрение → approved_player_id заполняется, status = 'approved'.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS player_requests (
  id                  UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name                TEXT NOT NULL,
  gender              TEXT NOT NULL CHECK (gender IN ('M', 'W')),
  phone               TEXT,
  tournament_id       UUID REFERENCES tournaments(id) ON DELETE SET NULL,
  status              TEXT DEFAULT 'pending'
                        CHECK (status IN ('pending', 'approved', 'rejected')),
  approved_player_id  UUID REFERENCES players(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ DEFAULT now(),
  reviewed_at         TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_pr_status
  ON player_requests (status);


-- ── 5. RPC: safe_register_player ─────────────────────────────
-- Атомарная регистрация с защитой от Race Condition.
--
-- Гарантии:
--   • FOR UPDATE блокирует строку турнира на время транзакции
--   • Два одновременных вызова на последнее место →
--     первый получит место, второй уйдёт в waitlist
--   • Дубликаты невозможны (UNIQUE constraint + проверка)
--   • Статус турнира обновляется атомарно
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION safe_register_player(
  p_tournament_id UUID,
  p_player_id     UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER          -- выполняется с правами владельца
AS $$
DECLARE
  v_trn          tournaments%ROWTYPE;
  v_current      INT;
  v_is_waitlist  BOOLEAN;
  v_position     INT;
  v_player_name  TEXT;
BEGIN
  -- ① Блокируем строку турнира
  SELECT * INTO v_trn
    FROM tournaments
   WHERE id = p_tournament_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'tournament_not_found',
      'message', 'Турнир не найден');
  END IF;

  -- ② Турнир закрыт?
  IF v_trn.status IN ('finished', 'cancelled') THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'tournament_closed',
      'message', 'Турнир завершён или отменён');
  END IF;

  -- ③ Игрок существует?
  SELECT name INTO v_player_name
    FROM players WHERE id = p_player_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'player_not_found',
      'message', 'Игрок не найден в базе');
  END IF;

  -- ④ Уже зарегистрирован?
  IF EXISTS (
    SELECT 1 FROM tournament_participants
     WHERE tournament_id = p_tournament_id
       AND player_id     = p_player_id
  ) THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'already_registered',
      'message', v_player_name || ' уже зарегистрирован(а)');
  END IF;

  -- ⑤ Считаем текущих участников (НЕ waitlist)
  SELECT COUNT(*) INTO v_current
    FROM tournament_participants
   WHERE tournament_id = p_tournament_id
     AND is_waitlist = false;

  -- ⑥ Место есть или waitlist?
  v_is_waitlist := v_current >= v_trn.capacity;

  -- ⑦ Позиция в соответствующем списке
  SELECT COALESCE(MAX(position), 0) + 1 INTO v_position
    FROM tournament_participants
   WHERE tournament_id = p_tournament_id
     AND is_waitlist = v_is_waitlist;

  -- ⑧ Вставляем
  INSERT INTO tournament_participants
    (tournament_id, player_id, is_waitlist, position)
  VALUES
    (p_tournament_id, p_player_id, v_is_waitlist, v_position);

  -- ⑨ Обновляем статус турнира
  IF NOT v_is_waitlist AND (v_current + 1) >= v_trn.capacity THEN
    UPDATE tournaments SET status = 'full'
     WHERE id = p_tournament_id;
  END IF;

  -- ⑩ Инкрементируем счётчик турниров игрока
  IF NOT v_is_waitlist THEN
    UPDATE players
       SET tournaments_played = tournaments_played + 1
     WHERE id = p_player_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',        true,
    'waitlist',  v_is_waitlist,
    'position',  v_position,
    'total',     v_current + CASE WHEN v_is_waitlist THEN 0 ELSE 1 END,
    'capacity',  v_trn.capacity,
    'player',    v_player_name,
    'message',   CASE
      WHEN v_is_waitlist THEN v_player_name || ' → лист ожидания (#' || v_position || ')'
      ELSE v_player_name || ' зарегистрирован(а) (' || (v_current+1) || '/' || v_trn.capacity || ')'
    END
  );
END;
$$;


-- ── 6. RPC: search_players ───────────────────────────────────
-- Нечёткий поиск по имени с ранжированием.
-- Используется фронтендом для дебаунс-инпута.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION search_players(
  p_query   TEXT,
  p_gender  TEXT DEFAULT NULL,    -- фильтр: 'M', 'W' или NULL (все)
  p_limit   INT  DEFAULT 10
)
RETURNS TABLE (
  id          UUID,
  name        TEXT,
  gender      TEXT,
  status      TEXT,
  tournaments_played INT,
  total_pts   INT,
  similarity  REAL
)
LANGUAGE plpgsql
STABLE                            -- read-only, оптимизация планировщика
AS $$
BEGIN
  RETURN QUERY
    SELECT
      p.id, p.name, p.gender, p.status,
      p.tournaments_played, p.total_pts,
      similarity(p.name, p_query) AS similarity
    FROM players p
    WHERE
      (p_gender IS NULL OR p.gender = p_gender)
      AND (
        p.name ILIKE '%' || p_query || '%'
        OR similarity(p.name, p_query) > 0.2
      )
    ORDER BY
      -- Точное начало имени → первым
      (p.name ILIKE p_query || '%') DESC,
      similarity(p.name, p_query) DESC,
      p.tournaments_played DESC
    LIMIT p_limit;
END;
$$;


-- ── 7. RPC: approve_player_request ───────────────────────────
-- Одобрение заявки: создаёт игрока, опционально регистрирует.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION approve_player_request(
  p_request_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_req    player_requests%ROWTYPE;
  v_pid    UUID;
  v_reg    JSONB;
BEGIN
  SELECT * INTO v_req FROM player_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'request_not_found');
  END IF;

  IF v_req.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_processed');
  END IF;

  -- Создаём игрока
  INSERT INTO players (name, gender, phone, status)
  VALUES (v_req.name, v_req.gender, v_req.phone, 'active')
  ON CONFLICT (lower(trim(name)), gender) DO UPDATE SET status = 'active'
  RETURNING id INTO v_pid;

  -- Обновляем заявку
  UPDATE player_requests
     SET status = 'approved',
         approved_player_id = v_pid,
         reviewed_at = now()
   WHERE id = p_request_id;

  -- Если указан турнир — пробуем зарегистрировать
  IF v_req.tournament_id IS NOT NULL THEN
    v_reg := safe_register_player(v_req.tournament_id, v_pid);
    RETURN jsonb_build_object(
      'ok', true,
      'player_id', v_pid,
      'registration', v_reg
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'player_id', v_pid);
END;
$$;


-- ── 8. ROW LEVEL SECURITY ────────────────────────────────────
-- Базовые политики: чтение всем, запись через RPC (SECURITY DEFINER).
-- ──────────────────────────────────────────────────────────────
ALTER TABLE players                ENABLE ROW LEVEL SECURITY;
ALTER TABLE tournaments            ENABLE ROW LEVEL SECURITY;
ALTER TABLE tournament_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE player_requests        ENABLE ROW LEVEL SECURITY;

-- Чтение — всем аутентифицированным и анонимным (приложение без auth)
DO $$ BEGIN
  -- players
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'players_select') THEN
    CREATE POLICY players_select ON players FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'players_insert') THEN
    CREATE POLICY players_insert ON players FOR INSERT WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'players_update') THEN
    CREATE POLICY players_update ON players FOR UPDATE USING (true);
  END IF;

  -- tournaments
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'tournaments_select') THEN
    CREATE POLICY tournaments_select ON tournaments FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'tournaments_insert') THEN
    CREATE POLICY tournaments_insert ON tournaments FOR INSERT WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'tournaments_update') THEN
    CREATE POLICY tournaments_update ON tournaments FOR UPDATE USING (true);
  END IF;

  -- tournament_participants
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'tp_select') THEN
    CREATE POLICY tp_select ON tournament_participants FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'tp_insert') THEN
    CREATE POLICY tp_insert ON tournament_participants FOR INSERT WITH CHECK (true);
  END IF;

  -- player_requests
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'pr_select') THEN
    CREATE POLICY pr_select ON player_requests FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'pr_insert') THEN
    CREATE POLICY pr_insert ON player_requests FOR INSERT WITH CHECK (true);
  END IF;
END $$;


-- ══════════════════════════════════════════════════════════════
-- ГОТОВО. Таблицы: players, tournaments, tournament_participants,
-- player_requests. RPC: safe_register_player, search_players,
-- approve_player_request.
-- ══════════════════════════════════════════════════════════════
