\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO tender_platform, public;

WITH report_bounds AS (
    SELECT
        (
            date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
            - INTERVAL '1 month'
        ) AT TIME ZONE 'Europe/Moscow' AS period_start,
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
            AT TIME ZONE 'Europe/Moscow' AS period_end
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
    2201,
    'analytics-test',
    'boundary-currency',
    'ANALYTICS-BOUNDARY',
    'Проверка границ периода и валюты',
    1,
    'completed',
    bounds.period_start - INTERVAL '10 days',
    bounds.period_start - INTERVAL '1 day',
    bounds.period_start
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
VALUES
    (2201, 2201, 1, 'Ровно на нижней границе', 120.00, 'EUR', 'completed'),
    (2202, 2201, 2, 'Равная сумма внутри периода', 120.00, 'EUR', 'completed'),
    (2203, 2201, 3, 'Ровно на верхней границе', 10000.00, 'EUR', 'completed');

WITH report_bounds AS (
    SELECT
        (
            date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
            - INTERVAL '1 month'
        ) AT TIME ZONE 'Europe/Moscow' AS period_start,
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
            AT TIME ZONE 'Europe/Moscow' AS period_end
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
SELECT 2201, 2201, 3, 100.00, bounds.period_start, 'completed'
  FROM report_bounds bounds
UNION ALL
SELECT 2202, 2202, 4, 100.00, bounds.period_start + INTERVAL '1 day', 'completed'
  FROM report_bounds bounds
UNION ALL
SELECT 2203, 2203, 5, 9999.00, bounds.period_end, 'completed'
  FROM report_bounds bounds;

DO $test$
DECLARE
    actual_count bigint;
    actual_total numeric;
    expected_start timestamptz := (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    ) AT TIME ZONE 'Europe/Moscow';
    expected_end timestamptz := date_trunc(
        'month',
        CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow'
    ) AT TIME ZONE 'Europe/Moscow';
BEGIN
    SELECT count(*), sum(total_awarded_amount)
      INTO actual_count, actual_total
      FROM v_top_companies_previous_month
     WHERE currency_code = 'EUR';

    IF actual_count <> 2 OR actual_total <> 200.00 THEN
        RAISE EXCEPTION
            'Expected two included EUR awards totalling 200.00, found count %, total %',
            actual_count,
            actual_total;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM v_top_companies_previous_month
         WHERE currency_code = 'EUR'
           AND rank_in_currency = 1
           AND company_id = 3
           AND period_start = expected_start
           AND period_end = expected_end
    ) OR NOT EXISTS (
        SELECT 1
          FROM v_top_companies_previous_month
         WHERE currency_code = 'EUR'
           AND rank_in_currency = 2
           AND company_id = 4
    ) THEN
        RAISE EXCEPTION 'EUR ties or Moscow month boundaries are not deterministic';
    END IF;
END
$test$;

ROLLBACK;

SELECT 'boundary_currency_contract_passed' AS result;
