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
    2901,
    'analytics-test',
    'average-rounding',
    'ANALYTICS-AVERAGE-ROUNDING',
    'Average bidder rounding contract',
    1,
    'completed',
    bounds.period_start - INTERVAL '10 days',
    bounds.period_start - INTERVAL '1 day',
    bounds.period_start + INTERVAL '3 days'
FROM report_bounds bounds;

INSERT INTO lots (id, tender_id, lot_number, title, initial_price, currency_code, status)
OVERRIDING SYSTEM VALUE
VALUES
    (2901, 2901, 1, 'One admitted bidder', 100.00, 'NOK', 'completed'),
    (2902, 2901, 2, 'No admitted bidders A', 100.00, 'NOK', 'completed'),
    (2903, 2901, 3, 'No admitted bidders B', 100.00, 'NOK', 'completed');

WITH report_bounds AS (
    SELECT (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    ) AT TIME ZONE 'Europe/Moscow' AS period_start
)
INSERT INTO bids (
    id, lot_id, bidder_company_id, version_no,
    amount, submitted_at, status
)
OVERRIDING SYSTEM VALUE
SELECT
    2901,
    2901,
    3,
    1,
    90.00,
    bounds.period_start - INTERVAL '2 days',
    'admitted'
FROM report_bounds bounds;

WITH report_bounds AS (
    SELECT (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    ) AT TIME ZONE 'Europe/Moscow' AS period_start
)
INSERT INTO executors (
    id, lot_id, company_id, awarded_amount, awarded_at, status
)
OVERRIDING SYSTEM VALUE
SELECT 2901, 2901, 3, 90.00, bounds.period_start + INTERVAL '1 day', 'completed'
  FROM report_bounds bounds
UNION ALL
SELECT 2902, 2902, 4, 90.00, bounds.period_start + INTERVAL '2 days', 'completed'
  FROM report_bounds bounds
UNION ALL
SELECT 2903, 2903, 5, 90.00, bounds.period_start + INTERVAL '3 days', 'completed'
  FROM report_bounds bounds;

DO $test$
DECLARE
    actual_average numeric;
    expected_report_month date := (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    )::date;
BEGIN
    SELECT average_admitted_bidders
      INTO STRICT actual_average
      FROM v_customer_efficiency_last_six_months
     WHERE customer_company_id = 1
       AND currency_code = 'NOK'
       AND report_month = expected_report_month;

    IF actual_average IS DISTINCT FROM 0.33 THEN
        RAISE EXCEPTION
            'Expected rounded average admitted bidders 0.33, found %',
            actual_average;
    END IF;
END
$test$;

ROLLBACK;

SELECT 'average_rounding_contract_passed' AS result;
