\set ON_ERROR_STOP on

-- Single psql entry point for the complete assignment deliverable.
-- Sample data is intentionally excluded from production setup.
BEGIN;
SET LOCAL tender_platform.install_context = 'complete';

\ir 01_schema.sql
\ir analytics/01_top_companies_previous_month.sql
\ir analytics/02_customer_efficiency.sql

COMMIT;
