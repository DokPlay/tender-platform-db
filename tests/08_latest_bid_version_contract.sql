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
    2301,
    'analytics-test',
    'latest-bid-version',
    'ANALYTICS-LATEST-BID',
    'Проверка последней версии ставки',
    1,
    'completed',
    bounds.period_start - INTERVAL '10 days',
    bounds.period_start - INTERVAL '1 day',
    bounds.period_start + INTERVAL '2 days'
FROM report_bounds bounds;

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
VALUES (
    2301,
    2301,
    1,
    'Лот с изменениями ставок',
    1000.00,
    'GBP',
    'completed'
);

WITH report_bounds AS (
    SELECT (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    ) AT TIME ZONE 'Europe/Moscow' AS period_start
)
INSERT INTO bids (
    id,
    lot_id,
    bidder_company_id,
    version_no,
    amount,
    submitted_at,
    status
)
OVERRIDING SYSTEM VALUE
SELECT 2301, 2301, 3, 1, 950.00, bounds.period_start - INTERVAL '6 days', 'admitted'
  FROM report_bounds bounds
UNION ALL
SELECT 2302, 2301, 3, 2, 940.00, bounds.period_start - INTERVAL '5 days', 'admitted'
  FROM report_bounds bounds
UNION ALL
SELECT 2303, 2301, 4, 1, 930.00, bounds.period_start - INTERVAL '4 days', 'admitted'
  FROM report_bounds bounds
UNION ALL
SELECT 2304, 2301, 4, 2, 920.00, bounds.period_start - INTERVAL '5 days', 'withdrawn'
  FROM report_bounds bounds
UNION ALL
SELECT 2305, 2301, 5, 1, 910.00, bounds.period_start - INTERVAL '4 days', 'rejected'
  FROM report_bounds bounds
UNION ALL
SELECT 2306, 2301, 5, 2, 900.00, bounds.period_start - INTERVAL '3 days', 'admitted'
  FROM report_bounds bounds;

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
    2301,
    2301,
    5,
    900.00,
    bounds.period_start + INTERVAL '2 days',
    'completed'
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
       AND currency_code = 'GBP'
       AND report_month = expected_report_month;

    IF actual_average IS DISTINCT FROM 2.00 THEN
        RAISE EXCEPTION
            'Expected 2 admitted bidders by latest version, found %',
            actual_average;
    END IF;
END
$test$;

ROLLBACK;

SELECT 'latest_bid_version_contract_passed' AS result;
