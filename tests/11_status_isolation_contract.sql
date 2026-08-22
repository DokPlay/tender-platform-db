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
    2601,
    'analytics-test',
    'terminated-only-filter',
    'ANALYTICS-TERMINATED',
    'Прекращённый результат на завершённом лоте',
    1,
    'completed',
    bounds.period_start - INTERVAL '10 days',
    bounds.period_start - INTERVAL '1 day',
    bounds.period_start + INTERVAL '2 days'
FROM report_bounds bounds
UNION ALL
SELECT
    2602,
    'analytics-test',
    'incomplete-tender-only',
    'ANALYTICS-INCOMPLETE-TENDER',
    'Незавершённый тендер с завершённым лотом',
    1,
    'evaluation',
    bounds.period_start - INTERVAL '10 days',
    bounds.period_start - INTERVAL '1 day',
    NULL
FROM report_bounds bounds
UNION ALL
SELECT
    2603,
    'analytics-test',
    'incomplete-lot-only',
    'ANALYTICS-INCOMPLETE-LOT',
    'Завершённый тендер с незавершённым лотом',
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
VALUES
    (
        2601,
        2601,
        1,
        'Завершённый лот с прекращённым результатом',
        1000000.00,
        'CAD',
        'completed'
    ),
    (
        2602,
        2602,
        1,
        'Завершённый лот незавершённого тендера',
        1000000.00,
        'NZD',
        'completed'
    ),
    (
        2603,
        2603,
        1,
        'Незавершённый лот завершённого тендера',
        1000000.00,
        'SEK',
        'evaluation'
    );

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
    2601,
    2601,
    3,
    999999.00,
    bounds.period_start + INTERVAL '2 days',
    'terminated'
FROM report_bounds bounds
UNION ALL
SELECT
    2602,
    2602,
    3,
    999999.00,
    bounds.period_start + INTERVAL '2 days',
    'completed'
FROM report_bounds bounds
UNION ALL
SELECT
    2603,
    2603,
    3,
    999999.00,
    bounds.period_start + INTERVAL '2 days',
    'completed'
FROM report_bounds bounds;

DO $test$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM v_top_companies_previous_month
         WHERE currency_code = 'CAD'
    ) THEN
        RAISE EXCEPTION
            'Terminated executor on active tender and lot leaked into top companies';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM v_customer_efficiency_last_six_months
         WHERE currency_code = 'CAD'
    ) THEN
        RAISE EXCEPTION
            'Terminated executor leaked into customer efficiency';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM v_customer_efficiency_last_six_months
         WHERE currency_code = 'NZD'
    ) THEN
        RAISE EXCEPTION
            'Incomplete tender with completed lot leaked into customer efficiency';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM v_customer_efficiency_last_six_months
         WHERE currency_code = 'SEK'
    ) THEN
        RAISE EXCEPTION
            'Incomplete lot with completed tender leaked into customer efficiency';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM v_top_companies_previous_month
         WHERE currency_code = 'NZD'
           AND rank_in_currency = 1
           AND company_id = 3
           AND total_awarded_amount = 999999.00
           AND won_lot_count = 1
           AND won_tender_count = 1
    ) THEN
        RAISE EXCEPTION
            'Valid award on a non-cancelled evaluation tender is missing from top companies';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM v_top_companies_previous_month
         WHERE currency_code = 'SEK'
           AND rank_in_currency = 1
           AND company_id = 3
           AND total_awarded_amount = 999999.00
           AND won_lot_count = 1
           AND won_tender_count = 1
    ) THEN
        RAISE EXCEPTION
            'Valid award on a non-cancelled evaluation lot is missing from top companies';
    END IF;
END
$test$;

ROLLBACK;

SELECT 'status_isolation_contract_passed' AS result;
