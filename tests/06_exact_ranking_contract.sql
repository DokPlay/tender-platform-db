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
    2101,
    'analytics-test',
    'exact-ranking-lower',
    'ANALYTICS-EXACT-LOWER',
    'Экономия 10,003 процента',
    1,
    'completed',
    bounds.period_start - INTERVAL '10 days',
    bounds.period_start - INTERVAL '1 day',
    bounds.period_start + INTERVAL '2 days'
FROM report_bounds bounds
UNION ALL
SELECT
    2102,
    'analytics-test',
    'exact-ranking-higher',
    'ANALYTICS-EXACT-HIGHER',
    'Экономия 10,004 процента',
    2,
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
    (2101, 2101, 1, 'Экономия 10,003 процента', 10000.00, 'JPY', 'completed'),
    (2102, 2102, 1, 'Экономия 10,004 процента', 10000.00, 'JPY', 'completed');

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
    2101,
    2101,
    3,
    8999.70,
    bounds.period_start + INTERVAL '2 days',
    'completed'
FROM report_bounds bounds
UNION ALL
SELECT
    2102,
    2102,
    3,
    8999.60,
    bounds.period_start + INTERVAL '2 days',
    'completed'
FROM report_bounds bounds;

DO $test$
DECLARE
    lower_rank bigint;
    higher_rank bigint;
    lower_displayed_percent numeric;
    higher_displayed_percent numeric;
    lower_initial_amount numeric;
    lower_awarded_amount numeric;
    lower_savings_amount numeric;
    higher_initial_amount numeric;
    higher_awarded_amount numeric;
    higher_savings_amount numeric;
    expected_report_month date := (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    )::date;
BEGIN
    SELECT
        customer_rank,
        savings_percent,
        initial_amount,
        awarded_amount,
        savings_amount
      INTO STRICT
        lower_rank,
        lower_displayed_percent,
        lower_initial_amount,
        lower_awarded_amount,
        lower_savings_amount
      FROM v_customer_efficiency_last_six_months
     WHERE customer_company_id = 1
       AND currency_code = 'JPY'
       AND report_month = expected_report_month;

    SELECT
        customer_rank,
        savings_percent,
        initial_amount,
        awarded_amount,
        savings_amount
      INTO STRICT
        higher_rank,
        higher_displayed_percent,
        higher_initial_amount,
        higher_awarded_amount,
        higher_savings_amount
      FROM v_customer_efficiency_last_six_months
     WHERE customer_company_id = 2
       AND currency_code = 'JPY'
       AND report_month = expected_report_month;

    IF higher_rank IS DISTINCT FROM 1 OR lower_rank IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION
            'Expected exact 10.004%% to rank above 10.003%%, found ranks % and %',
            higher_rank,
            lower_rank;
    END IF;

    IF lower_displayed_percent IS DISTINCT FROM 10.00
       OR higher_displayed_percent IS DISTINCT FROM 10.00 THEN
        RAISE EXCEPTION
            'Expected both displayed percentages to remain rounded to 10.00, found % and %',
            lower_displayed_percent,
            higher_displayed_percent;
    END IF;

    IF lower_initial_amount IS DISTINCT FROM 10000.00
       OR lower_awarded_amount IS DISTINCT FROM 8999.70
       OR lower_savings_amount IS DISTINCT FROM 1000.30
       OR higher_initial_amount IS DISTINCT FROM 10000.00
       OR higher_awarded_amount IS DISTINCT FROM 8999.60
       OR higher_savings_amount IS DISTINCT FROM 1000.40 THEN
        RAISE EXCEPTION
            'Cent-level money changed: lower (%, %, %), higher (%, %, %)',
            lower_initial_amount,
            lower_awarded_amount,
            lower_savings_amount,
            higher_initial_amount,
            higher_awarded_amount,
            higher_savings_amount;
    END IF;
END
$test$;

ROLLBACK;

SELECT 'exact_ranking_contract_passed' AS result;
