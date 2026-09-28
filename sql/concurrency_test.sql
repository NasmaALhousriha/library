-- concurrency_test.sql  (pgbench script - keep it ASCII only)
--
-- Setup (once before each run):
--   psql -U postgres -d library_db -c "SELECT stress_reset(2, 10);"
--
-- Run:
-- pgbench -n -c 5 -j 2 -t 50 -P 5 -f sql/concurrency_test.sql -U postgres library_db
-- Check:
--   psql -U postgres -d library_db -f sql/check_invariants.sql

\set uid random(1, 10)
\set op  random(1, 100)
SELECT stress_step(:uid, 1, :op);
