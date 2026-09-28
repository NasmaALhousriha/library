-- verify.sql
-- Run:  psql -U postgres -d library_db -f sql/verify.sql
-- Every check prints "NOTICE: PASS ...". The first failure stops the file with "FAIL ...".
-- WARNING: deletes all data in the tables.

\set ON_ERROR_STOP on
\pset tuples_only on
SET client_min_messages = notice;


-- clean tables: p_users users + one book with one copy
CREATE OR REPLACE FUNCTION t_reset(p_users INT) RETURNS VOID AS $$
BEGIN
    TRUNCATE queues, borrowings, books, users RESTART IDENTITY CASCADE;
    INSERT INTO users (name, email)
    SELECT 'U' || g, 'u' || g || '@x' FROM generate_series(1, p_users) g;
    INSERT INTO books (title, author, total_copies, available_copies) VALUES ('Book1', 'Auth', 1, 1);
END $$ LANGUAGE plpgsql;

-- common scenario: user1 borrows, user2 + user3 join, user1 returns
-- result: queue 1 (user2) = RESERVED, queue 2 (user3) = WAITING
CREATE OR REPLACE FUNCTION t_scenario() RETURNS VOID AS $$
BEGIN
    PERFORM t_reset(3);
    PERFORM borrow_book(1, 1);
    PERFORM join_queue(2, 1);
    PERFORM join_queue(3, 1);
    PERFORM return_book(1);
END $$ LANGUAGE plpgsql;

-- condition must be true
CREATE OR REPLACE FUNCTION t_check(p_ok BOOLEAN, p_name TEXT) RETURNS VOID AS $$
BEGIN
    IF p_ok THEN RAISE NOTICE 'PASS %', p_name;
    ELSE RAISE EXCEPTION 'FAIL %', p_name;
    END IF;
END $$ LANGUAGE plpgsql;

-- statement must fail with this exact error code
CREATE OR REPLACE FUNCTION t_expect_error(p_sql TEXT, p_code TEXT, p_name TEXT) RETURNS VOID AS $$
BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'FAIL %: expected error %', p_name, p_code;
EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = p_code THEN RAISE NOTICE 'PASS %', p_name;
    ELSE RAISE;
    END IF;
END $$ LANGUAGE plpgsql;


-- #1 receive_book checks the user
SELECT t_scenario();
SELECT t_expect_error('SELECT receive_book(1, 3)', 'P0016', '#1a user3 cannot take user2 reservation');
SELECT receive_book(1, 2);
SELECT t_check((SELECT user_id FROM borrowings WHERE id = 2) = 2, '#1b user2 receives own reservation');

-- #2 FIFO by position, not created_at
SELECT t_reset(4);
SELECT borrow_book(1, 1);
SELECT join_queue(2, 1);
SELECT join_queue(3, 1);
SELECT join_queue(4, 1);
UPDATE queues SET created_at = NOW() - INTERVAL '10 minutes' WHERE user_id IN (3, 4);
SELECT return_book(1);
SELECT t_check((SELECT user_id FROM queues WHERE status = 'RESERVED') = 2, '#2 position 1 gets the copy');

-- #6 get_queue_for_book shows expiry in the same call
SELECT t_scenario();
UPDATE queues SET expires_at = NOW() - INTERVAL '1 hour' WHERE id = 1;
SELECT t_check(
    (SELECT string_agg(e->>'status', ',' ORDER BY (e->>'queueId')::INT)
     FROM json_array_elements(get_queue_for_book(1)->'queues') e) = 'EXPIRED,RESERVED',
    '#6 expired reservation passed on and shown immediately');

-- #7 available_copies <= total_copies
SELECT t_reset(1);
SELECT t_expect_error('UPDATE books SET available_copies = 2 WHERE id = 1', '23514', '#7 available > total rejected');

-- #8 no duplicate active rows
SELECT t_reset(1);
INSERT INTO queues (user_id, book_id, status, position) VALUES (1, 1, 'WAITING', 1);
SELECT t_expect_error($$INSERT INTO queues (user_id, book_id, status, position) VALUES (1, 1, 'RESERVED', 2)$$,
                      '23505', '#8a duplicate active queue entry rejected');
UPDATE queues SET status = 'CANCELLED' WHERE id = 1;
INSERT INTO queues (user_id, book_id, status, position) VALUES (1, 1, 'WAITING', 1);
SELECT t_check(TRUE, '#8b re-join after CANCELLED allowed');
INSERT INTO borrowings (user_id, book_id, due_date) VALUES (1, 1, NOW());
SELECT t_expect_error($$INSERT INTO borrowings (user_id, book_id, due_date) VALUES (1, 1, NOW())$$,
                      '23505', '#8c duplicate active borrowing rejected');

-- #9 release_copy on cancel
SELECT t_scenario();
SELECT cancel_queue_entry(1, 2);
SELECT t_check((SELECT status FROM queues WHERE id = 2) = 'RESERVED', '#9a cancelled reservation passes to next');
SELECT cancel_queue_entry(2, 3);
SELECT t_check((SELECT available_copies FROM books) = 1, '#9b nobody waiting -> copy back on shelf');

-- #10 borrow_book / join_queue share the same rules
SELECT t_reset(2);
SELECT t_check(borrow_book(1, 1)->>'type' = 'borrowing', '#10a free copy -> direct borrow');
SELECT t_check(borrow_book(2, 1)->>'type' = 'queue', '#10b no copy -> queued');
SELECT t_expect_error('SELECT borrow_book(2, 1)', 'P0013', '#10c cannot queue twice');
SELECT t_expect_error('SELECT join_queue(1, 1)', 'P0015', '#10d cannot queue while borrowing');

-- #18 totalInQueue counts active entries only
SELECT t_reset(3);
SELECT borrow_book(1, 1);
SELECT join_queue(2, 1);
SELECT join_queue(3, 1);
SELECT t_check((get_queue_for_book(1)->>'totalInQueue')::INT = 2, '#18a two waiting -> 2');
SELECT cancel_queue_entry(1, 2);
SELECT cancel_queue_entry(2, 3);
SELECT t_check((get_queue_for_book(1)->>'totalInQueue')::INT = 0, '#18b both cancelled -> 0');

TRUNCATE queues, borrowings, books, users RESTART IDENTITY CASCADE;
DROP FUNCTION t_scenario(), t_reset(INT), t_check(BOOLEAN, TEXT), t_expect_error(TEXT, TEXT, TEXT);
