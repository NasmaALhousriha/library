SET client_encoding = 'UTF8';

DROP FUNCTION IF EXISTS receive_book(INT);

CREATE OR REPLACE FUNCTION release_copy(p_book_id INT)
RETURNS VOID AS $$
DECLARE
    v_next_queue_id INT;
BEGIN
    SELECT id INTO v_next_queue_id
    FROM queues
    WHERE book_id = p_book_id AND status = 'WAITING'
    ORDER BY position ASC, id ASC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
        UPDATE queues
        SET status = 'RESERVED', reserved_at = NOW(), expires_at = NOW() + INTERVAL '24 hours'
        WHERE id = v_next_queue_id;
    ELSE
        UPDATE books SET available_copies = available_copies + 1 WHERE id = p_book_id;
    END IF;
END;
$$ LANGUAGE plpgsql;


-- process_expired_reservations: كل حجز منتهي بيصير EXPIRED ونسختو بتتحرر
CREATE OR REPLACE FUNCTION process_expired_reservations(p_book_id INT)
RETURNS VOID AS $$
DECLARE
    v_expired_queue_id INT;
BEGIN
    PERFORM 1 FROM books WHERE id = p_book_id FOR NO KEY UPDATE;

    LOOP
        SELECT id INTO v_expired_queue_id
        FROM queues
        WHERE book_id = p_book_id AND status = 'RESERVED' AND expires_at < NOW()
        ORDER BY reserved_at ASC
        LIMIT 1
        FOR UPDATE;

        EXIT WHEN NOT FOUND;

        UPDATE queues SET status = 'EXPIRED' WHERE id = v_expired_queue_id;
        PERFORM release_copy(p_book_id);
    END LOOP;
END;
$$ LANGUAGE plpgsql;


-- process_all_expired_reservations:
CREATE OR REPLACE FUNCTION process_all_expired_reservations()
RETURNS VOID AS $$
DECLARE
    v_book_id INT;
BEGIN
    FOR v_book_id IN
        SELECT DISTINCT book_id
        FROM queues
        WHERE status = 'RESERVED' AND expires_at < NOW()
    LOOP
        PERFORM process_expired_reservations(v_book_id);
    END LOOP;
END;
$$ LANGUAGE plpgsql;


-- check_can_request : الفحوصات المشتركة قبل الاستعارة أو الدخول للطابور
-- بتقفل الكتاب، وبترجع عدد النسخ المتاحة بعد معالجة الحجوزات المنتهية
CREATE OR REPLACE FUNCTION check_can_request(p_user_id INT, p_book_id INT)
RETURNS INT AS $$
DECLARE
    v_available INT;
BEGIN
    PERFORM 1 FROM books WHERE id = p_book_id FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Book not found' USING ERRCODE = 'P0010';
    END IF;

    IF EXISTS (
        SELECT 1 FROM borrowings
        WHERE user_id = p_user_id AND book_id = p_book_id AND returned_at IS NULL
    ) THEN
        RAISE EXCEPTION 'You already borrowed this book and have not returned it' USING ERRCODE = 'P0015';
    END IF;

    PERFORM process_expired_reservations(p_book_id);

    SELECT available_copies INTO v_available FROM books WHERE id = p_book_id;
    RETURN v_available;
END;
$$ LANGUAGE plpgsql;


-- enqueue_user : إضافة المستخدم لآخر الطابور
CREATE OR REPLACE FUNCTION enqueue_user(p_user_id INT, p_book_id INT)
RETURNS INT AS $$
DECLARE
    v_next_position INT;
    v_queue_id INT;
BEGIN
    IF EXISTS (
        SELECT 1 FROM queues
        WHERE user_id = p_user_id AND book_id = p_book_id AND status IN ('WAITING', 'RESERVED')
    ) THEN
        RAISE EXCEPTION 'You are already in the queue for this book' USING ERRCODE = 'P0013';
    END IF;

    SELECT COALESCE(MAX(position), 0) + 1 INTO v_next_position
    FROM queues WHERE book_id = p_book_id AND status = 'WAITING';

    INSERT INTO queues (user_id, book_id, status, position)
    VALUES (p_user_id, p_book_id, 'WAITING', v_next_position)
    RETURNING id INTO v_queue_id;

    RETURN v_queue_id;
END;
$$ LANGUAGE plpgsql;

-- fulfill_reservation: تحويل الحجز لاستعارة
CREATE OR REPLACE FUNCTION fulfill_reservation(p_queue_id INT)
RETURNS INT AS $$
DECLARE
    v_user_id INT;
    v_book_id INT;
    v_borrow_id INT;
BEGIN
    SELECT user_id, book_id INTO v_user_id, v_book_id FROM queues WHERE id = p_queue_id;

    UPDATE queues SET status = 'FULFILLED', received_at = NOW() WHERE id = p_queue_id;

    INSERT INTO borrowings (user_id, book_id, borrowed_at, due_date)
    VALUES (v_user_id, v_book_id, NOW(), NOW() + INTERVAL '14 days')
    RETURNING id INTO v_borrow_id;

    RETURN v_borrow_id;
END;
$$ LANGUAGE plpgsql;


-- borrow_book: عندك حجز؟ استلمو  في نسخة؟ استعير  غير هيك ادخل الطابور
CREATE OR REPLACE FUNCTION borrow_book(p_user_id INT, p_book_id INT)
RETURNS JSON AS $$
DECLARE
    v_available INT;
    v_reservation_id INT;
    v_borrow_id INT;
BEGIN
    v_available := check_can_request(p_user_id, p_book_id);

    -- 1) عندك حجز صالح؟ استلمو
    SELECT id INTO v_reservation_id
    FROM queues
    WHERE user_id = p_user_id AND book_id = p_book_id
      AND status = 'RESERVED' AND expires_at >= NOW()
    FOR UPDATE;

    IF FOUND THEN
        v_borrow_id := fulfill_reservation(v_reservation_id);
        RETURN json_build_object('type', 'borrowing', 'borrowingId', v_borrow_id);
    END IF;

    -- 2) في نسخة متاحة وما حدا عم يستنى؟ استعير مباشرة
    IF v_available > 0 AND NOT EXISTS (
        SELECT 1 FROM queues WHERE book_id = p_book_id AND status = 'WAITING'
    ) THEN
        UPDATE books SET available_copies = available_copies - 1 WHERE id = p_book_id;

        INSERT INTO borrowings (user_id, book_id, borrowed_at, due_date)
        VALUES (p_user_id, p_book_id, NOW(), NOW() + INTERVAL '14 days')
        RETURNING id INTO v_borrow_id;

        RETURN json_build_object('type', 'borrowing', 'borrowingId', v_borrow_id);
    END IF;

    -- 3) غير هيك، ادخل الطابور
    RETURN json_build_object('type', 'queue', 'queueId', enqueue_user(p_user_id, p_book_id));
END;
$$ LANGUAGE plpgsql;


-- join_queue: الدخول للطابور بس إذا ما في نسخ متاحة
CREATE OR REPLACE FUNCTION join_queue(p_user_id INT, p_book_id INT)
RETURNS INT AS $$
BEGIN
    IF check_can_request(p_user_id, p_book_id) > 0 THEN
        RAISE EXCEPTION 'Copies available, borrow directly' USING ERRCODE = 'P0012';
    END IF;

    RETURN enqueue_user(p_user_id, p_book_id);
END;
$$ LANGUAGE plpgsql;


-- receive_book: صاحب الحجز بيستلم الكتاب
CREATE OR REPLACE FUNCTION receive_book(p_queue_id INT, p_user_id INT)
RETURNS INT AS $$
DECLARE
    v_queue_id INT;
    v_book_id  INT;
BEGIN
    -- 1) نجيب الكتاب بدون قفل
    SELECT book_id INTO v_book_id
    FROM queues
    WHERE id = p_queue_id AND user_id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Reservation not found or expired' USING ERRCODE = 'P0016';
    END IF;

    -- 2) قفل الكتاب 
    PERFORM 1 FROM books WHERE id = v_book_id FOR NO KEY UPDATE;

    -- 3) قفل الحجز والتحقق من حالتو
    SELECT id INTO v_queue_id
    FROM queues
    WHERE id = p_queue_id AND status = 'RESERVED' AND expires_at >= NOW()
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Reservation not found or expired' USING ERRCODE = 'P0016';
    END IF;

    RETURN fulfill_reservation(v_queue_id);
END;
$$ LANGUAGE plpgsql;


-- return_book: إرجاع الكتاب، والنسخة بتروح لأول واحد بالطابور
CREATE OR REPLACE FUNCTION return_book(p_borrowing_id INT)
RETURNS VOID AS $$
DECLARE
    v_book_id INT;
BEGIN
    UPDATE borrowings
    SET returned_at = NOW()
    WHERE id = p_borrowing_id AND returned_at IS NULL
    RETURNING book_id INTO v_book_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Borrowing record not found or already returned' USING ERRCODE = 'P0014';
    END IF;

    PERFORM 1 FROM books WHERE id = v_book_id FOR NO KEY UPDATE;
    PERFORM process_expired_reservations(v_book_id);
    PERFORM release_copy(v_book_id);
END;
$$ LANGUAGE plpgsql;


-- cancel_queue_entry: إلغاء الدور، وإذا كان محجوزلو النسخة بتروح للي بعدو
CREATE OR REPLACE FUNCTION cancel_queue_entry(p_queue_id INT, p_user_id INT)
RETURNS VOID AS $$
DECLARE
    v_status queue_status;
    v_book_id INT;
BEGIN
    -- 1) نجيب book_id بدون قفل
    SELECT book_id INTO v_book_id
    FROM queues
    WHERE id = p_queue_id AND user_id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Queue entry not found' USING ERRCODE = 'P0017';
    END IF;

    -- 2)قفل الكتاب 
    PERFORM 1 FROM books WHERE id = v_book_id FOR NO KEY UPDATE;

    -- 3) قفل صف الطابور وقراءة حالتو)
    SELECT status INTO v_status
    FROM queues
    WHERE id = p_queue_id
    FOR UPDATE;

    IF v_status NOT IN ('WAITING', 'RESERVED') THEN
        RAISE EXCEPTION 'This queue entry can no longer be cancelled' USING ERRCODE = 'P0018';
    END IF;

    UPDATE queues SET status = 'CANCELLED' WHERE id = p_queue_id;

    IF v_status = 'RESERVED' THEN
        PERFORM release_copy(v_book_id);
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_queue_for_book(p_book_id INT)
RETURNS JSON AS $$
DECLARE
    v_book JSON;
    v_queues JSON;
    v_active INT;
BEGIN
    PERFORM process_expired_reservations(p_book_id);

    SELECT json_build_object(
        'id', id, 'title', title, 'author', author,
        'totalCopies', total_copies, 'availableCopies', available_copies
    ) INTO v_book
    FROM books WHERE id = p_book_id;

    IF v_book IS NULL THEN
        RAISE EXCEPTION 'Book not found' USING ERRCODE = 'P0010';
    END IF;

    SELECT COALESCE(json_agg(
        json_build_object(
            'queueId', q.id, 'userId', q.user_id, 'userName', u.name, 'email', u.email,
            'status', q.status,
            'position', wp.rn,
            'reservedAt', q.reserved_at, 'expiresAt', q.expires_at,
            'receivedAt', q.received_at, 'createdAt', q.created_at
        ) ORDER BY
            CASE q.status WHEN 'RESERVED' THEN 0 WHEN 'WAITING' THEN 1 ELSE 2 END,
            q.position ASC, q.id ASC
    ), '[]') INTO v_queues
    FROM queues q
    JOIN users u ON u.id = q.user_id
    LEFT JOIN (
        SELECT id, ROW_NUMBER() OVER (ORDER BY position ASC, id ASC) AS rn
        FROM queues
        WHERE book_id = p_book_id AND status = 'WAITING'
    ) wp ON wp.id = q.id
    WHERE q.book_id = p_book_id;
-- بس منعد النشطين
    SELECT COUNT(*) INTO v_active
    FROM queues
    WHERE book_id = p_book_id AND status IN ('WAITING', 'RESERVED');

    RETURN json_build_object(
        'book', v_book,
        'totalInQueue', v_active,
        'nextPersonToReceive', (
            SELECT elem FROM json_array_elements(v_queues) elem
            WHERE elem->>'status' IN ('WAITING', 'RESERVED')
            LIMIT 1
        ),
        'queues', v_queues
    );
END;
$$ LANGUAGE plpgsql;
