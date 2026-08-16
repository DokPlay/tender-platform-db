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
    2001,
    'analytics-test',
    'cancelled-tender',
    'ANALYTICS-CANCELLED',
    'Отменённая закупка с устаревшим активным результатом',
    1,
    'cancelled',
    bounds.period_start - INTERVAL '10 days',
    bounds.period_start - INTERVAL '1 day',
    NULL
FROM report_bounds bounds
UNION ALL
SELECT
    2002,
    'analytics-test',
    'tender-with-cancelled-lot',
    'ANALYTICS-CANCELLED-LOT',
    'Завершённая закупка с отменённым лотом',
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
    (
        2001,
        2001,
        1,
        'Активный лот отменённого тендера',
        99999999.00,
        'RUB',
        'awarded'
    ),
    (
        2002,
        2002,
        1,
        'Отменённый лот завершённого тендера',
        88888888.00,
        'RUB',
        'cancelled'
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
    2001,
    2001,
    6,
    99999999.00,
    bounds.period_start + INTERVAL '1 day',
    'awarded'
FROM report_bounds bounds
UNION ALL
SELECT
    2002,
    2002,
    5,
    88888888.00,
    bounds.period_start + INTERVAL '1 day',
    'awarded'
FROM report_bounds bounds;

DO $test$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM v_top_companies_previous_month
         WHERE company_id = 6
           AND currency_code = 'RUB'
           AND total_awarded_amount >= 99999999.00
    ) THEN
        RAISE EXCEPTION 'An active award from a cancelled tender leaked into the top report';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM v_top_companies_previous_month
         WHERE company_id = 5
           AND currency_code = 'RUB'
           AND total_awarded_amount >= 88888888.00
    ) THEN
        RAISE EXCEPTION 'An active award from a cancelled lot leaked into the top report';
    END IF;
END
$test$;

ROLLBACK;

SELECT 'cancelled_award_contract_passed' AS result;
