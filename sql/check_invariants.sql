\encoding UTF8
-- check_invariants.sql
-- بيتشغل بعد pgbench، وبيفحص القواعد يلي لازم تضل صحيحة مهما صار تزامن
--   psql -U postgres -d library_db -f sql/check_invariants.sql

\set ON_ERROR_STOP off
SET client_min_messages = notice;

DO $$
DECLARE
    v_total       INT;
    v_avail       INT;
    v_borrowed    INT;
    v_reserved    INT;
    v_waiting     INT;
    v_min_waiting INT;
    v_max_served  INT;
BEGIN
    SELECT total_copies, available_copies INTO v_total, v_avail FROM books WHERE id = 1;
    SELECT COUNT(*) INTO v_borrowed FROM borrowings WHERE book_id = 1 AND returned_at IS NULL;
    SELECT COUNT(*) INTO v_reserved FROM queues WHERE book_id = 1 AND status = 'RESERVED';
    SELECT COUNT(*) INTO v_waiting  FROM queues WHERE book_id = 1 AND status = 'WAITING';

    RAISE NOTICE 'total=% | available=% | borrowed=% | reserved=% | waiting=%',
        v_total, v_avail, v_borrowed, v_reserved, v_waiting;

    -- I1: كل نسخة بمكان واحد بالضبط (متاحة أو مستعارة أو محجوزة)
    IF v_avail + v_borrowed + v_reserved = v_total THEN
        RAISE NOTICE 'PASS I1: available + borrowed + reserved = total';
    ELSE
        RAISE NOTICE 'FAIL I1: % + % + % <> %', v_avail, v_borrowed, v_reserved, v_total;
    END IF;

    -- I2: ما في نسخة وفي حدا عم يستنى
    IF v_avail > 0 AND v_waiting > 0 THEN
        RAISE NOTICE 'FAIL I2: % copies available while % users waiting', v_avail, v_waiting;
    ELSE
        RAISE NOTICE 'PASS I2: no idle copy while someone is waiting';
    END IF;

    -- I3 (FIFO): ما في حدا لسا WAITING وهو أقدم من حدا انحجزلو
    SELECT MIN(id) INTO v_min_waiting FROM queues
    WHERE book_id = 1 AND status = 'WAITING';

    SELECT MAX(id) INTO v_max_served FROM queues
    WHERE book_id = 1 AND status IN ('RESERVED', 'FULFILLED', 'EXPIRED');

    IF v_min_waiting IS NOT NULL AND v_max_served IS NOT NULL
       AND v_min_waiting < v_max_served THEN
        RAISE NOTICE 'FAIL I3: waiting entry % is older than served entry %',
            v_min_waiting, v_max_served;
    ELSE
        RAISE NOTICE 'PASS I3: FIFO respected';
    END IF;
END $$;

\echo '--- outcomes per operation ---'
SELECT op, code, COUNT(*) AS n
FROM stress_log
GROUP BY op, code
ORDER BY op, code;
