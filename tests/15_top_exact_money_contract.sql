\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO tender_platform, public;

WITH report_bounds AS (
    SELECT (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    ) AT TIME ZONE 'Europe/Moscow' AS period_start
)
INSERT INTO tenders (
    id,
    source_system,
    external_id,
    procurement_number,
    title,
    customer_company_id,
    status,
    published_at,
    submission_deadline_at,
    completed_at
)
OVERRIDING SYSTEM VALUE
SELECT
    fixture.id,
    'analytics-test',
    fixture.external_id,
    fixture.procurement_number,
    fixture.title,
    1,
    'completed',
    bounds.period_start - INTERVAL '10 days',
    bounds.period_start - INTERVAL '1 day',
    bounds.period_start + INTERVAL '3 days'
FROM report_bounds bounds
CROSS JOIN (
    VALUES
        (3001, 'top-exact-cents-lower', 'TOP-EXACT-CENTS-LOWER', 'Точная сумма 100,01'),
        (3002, 'top-exact-cents-higher', 'TOP-EXACT-CENTS-HIGHER', 'Точная сумма 100,02')
) AS fixture(id, external_id, procurement_number, title);

INSERT INTO lots (
    id,
    tender_id,
    lot_number,
    title,
    initial_price,
    currency_code,
    status
)
OVERRIDING SYSTEM VALUE
VALUES
    (3001, 3001, 1, 'Точная сумма 100,01', 110.00, 'MXN', 'completed'),
    (3002, 3002, 1, 'Точная сумма 100,02', 110.00, 'MXN', 'completed');

WITH report_bounds AS (
    SELECT (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    ) AT TIME ZONE 'Europe/Moscow' AS period_start
)
INSERT INTO executors (
    id,
    lot_id,
    company_id,
    awarded_amount,
    awarded_at,
    status
)
OVERRIDING SYSTEM VALUE
SELECT
    3001,
    3001,
    3,
    100.01,
    bounds.period_start + INTERVAL '2 days',
    'completed'
FROM report_bounds bounds
UNION ALL
SELECT
    3002,
    3002,
    4,
    100.02,
    bounds.period_start + INTERVAL '2 days',
    'completed'
FROM report_bounds bounds;

DO $test$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM v_top_companies_previous_month
         WHERE currency_code = 'MXN'
           AND rank_in_currency = 1
           AND company_id = 4
           AND total_awarded_amount = 100.02
           AND won_lot_count = 1
           AND won_tender_count = 1
    ) OR NOT EXISTS (
        SELECT 1
          FROM v_top_companies_previous_month
         WHERE currency_code = 'MXN'
           AND rank_in_currency = 2
           AND company_id = 3
           AND total_awarded_amount = 100.01
           AND won_lot_count = 1
           AND won_tender_count = 1
    ) THEN
        RAISE EXCEPTION
            'Top companies must rank and preserve exact cent-level awarded totals';
    END IF;
END
$test$;

ROLLBACK;

SELECT 'top_exact_money_contract_passed' AS result;
