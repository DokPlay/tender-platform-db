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
FROM report_bounds bounds
UNION ALL
SELECT
    fixture.id,
    'analytics-test',
    fixture.external_id,
    fixture.procurement_number,
    fixture.title,
    fixture.customer_company_id,
    'completed',
    bounds.period_start - INTERVAL '10 days',
    bounds.period_start - INTERVAL '1 day',
    bounds.period_start + INTERVAL '2 days'
FROM report_bounds bounds
CROSS JOIN (
    VALUES
        (2502, 'zero-rank-customer-1', 'ANALYTICS-ZERO-RANK-1', 'Нулевой знаменатель заказчика 1', 1),
        (2503, 'zero-rank-customer-2', 'ANALYTICS-ZERO-RANK-2', 'Нулевой знаменатель заказчика 2', 2),
        (2504, 'equal-rank-customer-5', 'ANALYTICS-EQUAL-RANK-5', 'Равная экономия заказчика 5', 5),
        (2505, 'equal-rank-customer-6', 'ANALYTICS-EQUAL-RANK-6', 'Равная экономия заказчика 6', 6)
) AS fixture(
    id,
    external_id,
    procurement_number,
    title,
    customer_company_id
);

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
    (2501, 2501, 1, 'Лот с нулевой ценой', 0.00, 'CNY', 'completed'),
    (2502, 2502, 1, 'Нулевая цена и нулевое присуждение', 0.00, 'HKD', 'completed'),
    (2503, 2503, 1, 'Нулевая цена и ненулевое присуждение', 0.00, 'HKD', 'completed'),
    (2504, 2504, 1, 'Точная экономия 10 процентов A', 100.00, 'HKD', 'completed'),
    (2505, 2505, 1, 'Точная экономия 10 процентов B', 100.00, 'HKD', 'completed');

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
FROM report_bounds bounds
UNION ALL
SELECT
    fixture.id,
    fixture.lot_id,
    fixture.company_id,
    fixture.awarded_amount,
    bounds.period_start + INTERVAL '2 days',
    'completed'
FROM report_bounds bounds
CROSS JOIN (
    VALUES
        (2502, 2502, 3, 0.00::numeric),
        (2503, 2503, 4, 10.00::numeric),
        (2504, 2504, 5, 90.00::numeric),
        (2505, 2505, 6, 90.00::numeric)
) AS fixture(id, lot_id, company_id, awarded_amount);

DO $test$
DECLARE
    actual_rank bigint;
    actual_percent numeric;
    actual_average numeric;
    actual_initial numeric;
    actual_awarded numeric;
    actual_savings numeric;
    expected_report_month date := (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    )::date;
BEGIN
    SELECT
        customer_rank,
        savings_percent,
        average_admitted_bidders,
        initial_amount,
        awarded_amount,
        savings_amount
      INTO STRICT
        actual_rank,
        actual_percent,
        actual_average,
        actual_initial,
        actual_awarded,
        actual_savings
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

    IF actual_initial IS DISTINCT FROM 0.00
       OR actual_awarded IS DISTINCT FROM 0.00
       OR actual_savings IS DISTINCT FROM 0.00 THEN
        RAISE EXCEPTION
            'Zero-price monetary values changed: initial %, awarded %, savings %',
            actual_initial,
            actual_awarded,
            actual_savings;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM v_top_companies_previous_month
         WHERE currency_code = 'CNY'
           AND rank_in_currency = 1
           AND company_id = 3
           AND total_awarded_amount = 0.00
           AND won_lot_count = 1
           AND won_tender_count = 1
    ) THEN
        RAISE EXCEPTION 'Zero-value award is missing from top companies';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM v_customer_efficiency_last_six_months
         WHERE report_month = expected_report_month
           AND currency_code = 'HKD'
           AND customer_company_id = 5
           AND customer_rank = 1
           AND savings_percent = 10.00
    ) OR NOT EXISTS (
        SELECT 1
          FROM v_customer_efficiency_last_six_months
         WHERE report_month = expected_report_month
           AND currency_code = 'HKD'
           AND customer_company_id = 6
           AND customer_rank = 2
           AND savings_percent = 10.00
    ) THEN
        RAISE EXCEPTION
            'Equal non-null savings must rank by customer ID before NULL groups';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM v_customer_efficiency_last_six_months
         WHERE report_month = expected_report_month
           AND currency_code = 'HKD'
           AND customer_company_id IN (1, 2)
           AND (customer_rank IS NOT NULL OR savings_percent IS NOT NULL)
    ) THEN
        RAISE EXCEPTION
            'Zero-denominator customers must retain NULL percent and rank';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM v_customer_efficiency_last_six_months
         WHERE report_month = expected_report_month
           AND currency_code = 'HKD'
           AND customer_company_id = 2
           AND initial_amount = 0.00
           AND awarded_amount = 10.00
           AND savings_amount = -10.00
    ) THEN
        RAISE EXCEPTION
            'Zero-initial nonzero award monetary values were not preserved';
    END IF;
END
$test$;

ROLLBACK;

SELECT 'zero_price_contract_passed' AS result;
