\encoding UTF8
-- pgbench_helper.sql
-- دوال مساعدة لاختبار التزامن فقط (مو جزء من التطبيق)
-- التشغيل مرة وحدة بعد functions.sql:
--   psql -U postgres -d library_db -f sql/pgbench_helper.sql

-- سجل نتائج كل عملية نفّذها pgbench
CREATE UNLOGGED TABLE IF NOT EXISTS stress_log (
    id   SERIAL PRIMARY KEY,
    op   TEXT NOT NULL,
    code TEXT NOT NULL,
    at   TIMESTAMPTZ DEFAULT clock_timestamp()
);

-- تصفير الداتا: كتاب واحد بـ p_copies نسخ، و p_users مستخدم
CREATE OR REPLACE FUNCTION stress_reset(p_copies INT, p_users INT)
RETURNS VOID AS $$
BEGIN
    TRUNCATE queues, borrowings, books, users, stress_log RESTART IDENTITY CASCADE;

    INSERT INTO users (name, email)
    SELECT 'U' || g, 'u' || g || '@x.com' FROM generate_series(1, p_users) g;

    INSERT INTO books (title, author, total_copies, available_copies)
    VALUES ('Book1', 'Auth', p_copies, p_copies);
END;
$$ LANGUAGE plpgsql;

-- خطوة عشوائية واحدة حسب p_op (1..100):
--   1-40   borrow   | 41-60 return | 61-75 receive
--   76-90  cancel   | 91-100 expire (نحاكي مرور 24 ساعة على حجز)
--
-- الأخطاء المتوقعة (أكواد P00xx تبعنا + 23505 من الـ unique index) بتنسجّل وبيكمل.
-- أي خطأ تاني (deadlock 40P01، check_violation 23514...) بينرمي،
-- فـ pgbench بيوقف الـ client وبيبيّن إنو في مشكلة حقيقية.
CREATE OR REPLACE FUNCTION stress_step(p_user_id INT, p_book_id INT, p_op INT)
RETURNS VOID AS $$
DECLARE
    v_op  TEXT;
    v_id  INT;
    v_uid INT;
BEGIN
    BEGIN
        IF p_op <= 40 THEN
            v_op := 'borrow';
            PERFORM borrow_book(p_user_id, p_book_id);

        ELSIF p_op <= 60 THEN
            v_op := 'return';
            SELECT id INTO v_id FROM borrowings
            WHERE book_id = p_book_id AND returned_at IS NULL
            ORDER BY random() LIMIT 1;

            IF v_id IS NULL THEN v_op := 'return:noop';
            ELSE PERFORM return_book(v_id);
            END IF;

        ELSIF p_op <= 75 THEN
            v_op := 'receive';
            SELECT id, user_id INTO v_id, v_uid FROM queues
            WHERE book_id = p_book_id AND status = 'RESERVED'
            ORDER BY random() LIMIT 1;

            IF v_id IS NULL THEN v_op := 'receive:noop';
            ELSE PERFORM receive_book(v_id, v_uid);
            END IF;

        ELSIF p_op <= 90 THEN
            v_op := 'cancel';
            SELECT id INTO v_id FROM queues
            WHERE book_id = p_book_id AND user_id = p_user_id
              AND status IN ('WAITING', 'RESERVED')
            LIMIT 1;

            IF v_id IS NULL THEN v_op := 'cancel:noop';
            ELSE PERFORM cancel_queue_entry(v_id, p_user_id);
            END IF;

        ELSE
            v_op := 'expire';
            PERFORM 1 FROM books WHERE id = p_book_id FOR NO KEY UPDATE;

            UPDATE queues SET expires_at = NOW() - INTERVAL '1 second'
            WHERE id = (
                SELECT id FROM queues
                WHERE book_id = p_book_id AND status = 'RESERVED'
                ORDER BY random() LIMIT 1
            );

            IF NOT FOUND THEN v_op := 'expire:noop';
            ELSE PERFORM process_expired_reservations(p_book_id);
            END IF;
        END IF;

        INSERT INTO stress_log (op, code) VALUES (v_op, 'OK');

    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE LIKE 'P00%' OR SQLSTATE = '23505' THEN
            INSERT INTO stress_log (op, code) VALUES (v_op, SQLSTATE);
        ELSE
            RAISE;
        END IF;
    END;
END;
$$ LANGUAGE plpgsql;
