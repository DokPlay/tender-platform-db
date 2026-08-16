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
    2501,
    'analytics-test',
    'zero-initial-price',
    'ANALYTICS-ZERO-PRICE',
    'Проверка нулевой начальной цены',
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
VALUES (2501, 2501, 1, 'Лот с нулевой ценой', 0.00, 'CNY', 'completed');

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
    2501,
    2501,
    3,
    0.00,
    bounds.period_start + INTERVAL '2 days',
    'completed'
FROM report_bounds bounds;

DO $test$
DECLARE
    actual_rank bigint;
    actual_percent numeric;
    actual_average numeric;
    expected_report_month date := (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    )::date;
BEGIN
    SELECT
        customer_rank,
        savings_percent,
        average_admitted_bidders
      INTO STRICT actual_rank, actual_percent, actual_average
      FROM v_customer_efficiency_last_six_months
     WHERE customer_company_id = 1
       AND currency_code = 'CNY'
       AND report_month = expected_report_month;

    IF actual_percent IS NOT NULL OR actual_rank IS NOT NULL THEN
        RAISE EXCEPTION
            'Zero initial amount must have NULL percent and rank, found percent %, rank %',
            actual_percent,
            actual_rank;
    END IF;

    IF actual_average IS DISTINCT FROM 0.00 THEN
        RAISE EXCEPTION
            'Lot without bids must contribute zero admitted bidders, found %',
            actual_average;
    END IF;
END
$test$;

ROLLBACK;

SELECT 'zero_price_contract_passed' AS result;
