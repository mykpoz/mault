-- Measures what the HNSW vector index costs in accuracy and buys in speed,
-- across several hnsw.ef_search settings.
--
--   docker compose exec -T postgres psql -U mault -d mault \
--     -f - < scripts/measure-hnsw-recall.sql
--
-- One exact pass establishes ground truth (index scans disabled, slow). Then
-- each ef_search value gets its own approximate pass, timed per query. The
-- final table lines accuracy up against latency so the tradeoff is visible.
--
-- The per-game indexes (cards_embedding_hnsw_<game_key>, built by
-- lib/game-vector-index.ts) are PARTIAL - WHERE game_key = '<key>' - and
-- Postgres only uses a partial index when it can see that predicate as a
-- literal at plan time. So every query below is built with format('%L')
-- rather than reading the game key from a setting at run time; a
-- current_setting() comparison would silently skip the index, and the
-- "approximate" pass would quietly be another exact scan reporting perfect
-- recall. The plan check before the approximate passes catches that case.
--
-- The self-match is excluded (c.id <> q.id): querying with a vector already
-- in the table would return it at distance 0, which both methods find
-- trivially and which inflates the score.

\set SAMPLE 300
\set GAME 'mtg'
\set LANG 'en'
\set K 5
\set EF_LIST '{40,100,200}'

\timing off
\set ON_ERROR_STOP on

SELECT set_config('mault.efs',  :'EF_LIST', false) AS e,
       set_config('mault.game', :'GAME',    false) AS g,
       set_config('mault.lang', :'LANG',    false) AS l,
       set_config('mault.k',    :'K',       false) AS k \gset cfg_

CREATE TEMP TABLE q AS
SELECT id, embedding FROM cards
WHERE game_key = :'GAME' AND lang = :'LANG'
ORDER BY random() LIMIT :SAMPLE;

CREATE TEMP TABLE exact_hits (qid int, ids text[], ms numeric);
CREATE TEMP TABLE approx_hits (ef int, qid int, ids text[], ms numeric);

-- One nearest-neighbour query per sample row, with the game, language and k
-- baked in as literals (see header). $1 = the query row's id, $2 = its vector.
CREATE FUNCTION pg_temp.knn_sql() RETURNS text LANGUAGE sql AS $fn$
  SELECT format(
    'SELECT ARRAY(SELECT c.card_id FROM cards c
                  WHERE c.game_key = %L AND c.lang = %L AND c.id <> $1
                  ORDER BY c.embedding <=> $2
                  LIMIT %s)',
    current_setting('mault.game'),
    current_setting('mault.lang'),
    current_setting('mault.k')::int
  )
$fn$;

-- ── ground truth ─────────────────────────────────────────────────────────
-- HNSW surfaces as an Index Scan, so disabling index scans forces the
-- sequential path and therefore exact distances.
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SET enable_bitmapscan = off;
SET enable_seqscan = on;

\echo ''
\echo '>> exact pass - sequential scan, roughly 0.4-1s per query'

DO $$
DECLARE
  r record; n int := 0; total int; ids text[];
  t0 timestamptz; started timestamptz := clock_timestamp(); avg_ms numeric;
  knn text := pg_temp.knn_sql();
BEGIN
  SELECT count(*) INTO total FROM q;
  FOR r IN SELECT id, embedding FROM q LOOP
    t0 := clock_timestamp();
    EXECUTE knn INTO ids USING r.id, r.embedding;
    INSERT INTO exact_hits
    VALUES (r.id, ids, round(extract(epoch FROM clock_timestamp() - t0) * 1000, 3));
    n := n + 1;
    IF n % 25 = 0 OR n = total THEN
      avg_ms := round(extract(epoch FROM clock_timestamp() - started) * 1000 / n);
      RAISE NOTICE 'exact  %/%  (avg % ms/query, ~% s left)',
        n, total, avg_ms, round(avg_ms * (total - n) / 1000);
    END IF;
  END LOOP;
END $$;

-- ── approximate, one pass per ef_search ──────────────────────────────────
SET enable_indexscan = on;
SET enable_indexonlyscan = on;
SET enable_bitmapscan = on;
SET enable_seqscan = off;

-- Refuse to report numbers if the index isn't actually in the plan: without
-- it the "approximate" pass is exact, and perfect recall would be a lie.
DO $$
DECLARE
  sample_vec text;
  line text;
  uses_index boolean := false;
BEGIN
  SELECT embedding::text INTO sample_vec FROM q LIMIT 1;
  FOR line IN EXECUTE format(
    'EXPLAIN SELECT card_id FROM cards
     WHERE game_key = %L AND lang = %L
     ORDER BY embedding <=> %L::vector LIMIT %s',
    current_setting('mault.game'), current_setting('mault.lang'),
    sample_vec, current_setting('mault.k')::int)
  LOOP
    IF line LIKE '%Index Scan using cards_embedding_hnsw%' THEN
      uses_index := true;
    END IF;
  END LOOP;

  IF NOT uses_index THEN
    RAISE EXCEPTION
      'No HNSW index in the query plan for game_key=%. Build cards_embedding_hnsw_% first (see lib/game-vector-index.ts) - otherwise the approximate pass is just another exact scan.',
      current_setting('mault.game'), current_setting('mault.game');
  END IF;

  RAISE NOTICE 'plan check: approximate passes use the HNSW index';
END $$;

\echo ''
\echo '>> approximate passes - hnsw'

DO $$
DECLARE
  efs int[] := current_setting('mault.efs')::int[];
  ef int; r record; n int; total int; ids text[];
  t0 timestamptz; started timestamptz;
  knn text := pg_temp.knn_sql();
BEGIN
  SELECT count(*) INTO total FROM q;
  FOREACH ef IN ARRAY efs LOOP
    PERFORM set_config('hnsw.ef_search', ef::text, false);
    n := 0;
    started := clock_timestamp();
    FOR r IN SELECT id, embedding FROM q LOOP
      t0 := clock_timestamp();
      EXECUTE knn INTO ids USING r.id, r.embedding;
      INSERT INTO approx_hits
      VALUES (ef, r.id, ids, round(extract(epoch FROM clock_timestamp() - t0) * 1000, 3));
      n := n + 1;
    END LOOP;
    RAISE NOTICE 'ef_search=%  %/% queries in % ms',
      ef, n, total, round(extract(epoch FROM clock_timestamp() - started) * 1000);
  END LOOP;
END $$;

RESET enable_indexscan;
RESET enable_indexonlyscan;
RESET enable_bitmapscan;
RESET enable_seqscan;
RESET hnsw.ef_search;

-- ── report ───────────────────────────────────────────────────────────────
\echo ''
\echo '=== accuracy vs latency ==='

WITH per_query AS (
  SELECT a.ef, a.qid, a.ms,
         cardinality(ARRAY(SELECT unnest(e.ids)
                           INTERSECT
                           SELECT unnest(a.ids))) AS hits,
         (e.ids[1] = a.ids[1]) AS top1_same
  FROM approx_hits a JOIN exact_hits e USING (qid)
),
exact_ms AS (SELECT avg(ms) AS ms FROM exact_hits)
SELECT
  p.ef                                                                    AS ef_search,
  round(avg(p.hits)::numeric / current_setting('mault.k')::int, 4)        AS "recall@k",
  round(100.0 * count(*) FILTER (WHERE p.top1_same) / count(*), 2)        AS top1_pct,
  count(*) FILTER (WHERE NOT p.top1_same)                                 AS top1_misses,
  round(avg(p.ms), 2)                                                     AS avg_ms,
  round(percentile_cont(0.95) WITHIN GROUP (ORDER BY p.ms)::numeric, 2)   AS p95_ms,
  round((SELECT ms FROM exact_ms) / avg(p.ms))                            AS speedup_vs_exact
FROM per_query p
GROUP BY p.ef
ORDER BY p.ef;

\echo ''
\echo '=== exact baseline ==='
SELECT count(*) AS queries,
       round(avg(ms), 2) AS avg_ms,
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY ms)::numeric, 2) AS p95_ms
FROM exact_hits;

\echo ''
\echo '=== rank-1 disagreements at the highest ef_search ==='
\echo '(same name in both columns = a different printing, usually harmless)'
SELECT c.name AS queried, c.set_code,
       (SELECT name FROM cards x WHERE x.card_id = e.ids[1] LIMIT 1) AS exact_top1,
       (SELECT name FROM cards x WHERE x.card_id = a.ids[1] LIMIT 1) AS hnsw_top1
FROM exact_hits e
JOIN approx_hits a USING (qid)
JOIN cards c ON c.id = e.qid
WHERE a.ef = (SELECT max(ef) FROM approx_hits)
  AND e.ids[1] <> a.ids[1]
LIMIT 25;
