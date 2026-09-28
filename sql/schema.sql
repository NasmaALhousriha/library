SET client_encoding = 'UTF8';

DROP TABLE IF EXISTS queues CASCADE;
DROP TABLE IF EXISTS borrowings CASCADE;
DROP TABLE IF EXISTS books CASCADE;
DROP TABLE IF EXISTS users CASCADE;

DROP TYPE IF EXISTS queue_status CASCADE;

CREATE TYPE queue_status AS ENUM ('WAITING', 'RESERVED', 'FULFILLED', 'EXPIRED', 'CANCELLED');

-- 1. users table
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(150) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- 2. books table
CREATE TABLE books (
    id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    author VARCHAR(150) NOT NULL,
    total_copies INT NOT NULL DEFAULT 1 CHECK (total_copies >= 0),
    available_copies INT NOT NULL DEFAULT 1 CHECK (available_copies >= 0),
    created_at TIMESTAMP DEFAULT NOW(),
    CONSTRAINT chk_available_le_total CHECK (available_copies <= total_copies)
);

-- 3. borrowings table
CREATE TABLE borrowings (
    id SERIAL PRIMARY KEY,
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    book_id INT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    borrowed_at TIMESTAMP DEFAULT NOW(),
    due_date TIMESTAMP NOT NULL,
    returned_at TIMESTAMP DEFAULT NULL
);

-- 4. queue table
CREATE TABLE queues (
    id SERIAL PRIMARY KEY,
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    book_id INT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    status queue_status NOT NULL DEFAULT 'WAITING',
    position INT NOT NULL,
    reserved_at TIMESTAMP DEFAULT NULL,
    expires_at TIMESTAMP DEFAULT NULL,
    received_at TIMESTAMP DEFAULT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_queues_book_status ON queues(book_id, status);
CREATE INDEX idx_borrowings_user ON borrowings(user_id);

-- نفس المستخدم ما بيكون عندو أكتر من دور نشط لنفس الكتاب
CREATE UNIQUE INDEX uq_queues_active_user_book
    ON queues (user_id, book_id)
    WHERE status IN ('WAITING', 'RESERVED');

-- نفس المستخدم ما بيكون عندو أكتر من استعارة نشطة لنفس الكتاب
CREATE UNIQUE INDEX uq_borrowings_active_user_book
    ON borrowings (user_id, book_id)
    WHERE returned_at IS NULL;

-- ما في شخصين عم يستنوا بنفس الـ position لنفس الكتاب
CREATE UNIQUE INDEX uq_queues_waiting_position
    ON queues (book_id, position)
    WHERE status = 'WAITING';
