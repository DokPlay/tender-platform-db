\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO tender_platform, public;

WITH report_bounds AS (
    SELECT
        (
            date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
            - INTERVAL '6 months'
        ) AT TIME ZONE 'Europe/Moscow' AS period_start,
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
            AT TIME ZONE 'Europe/Moscow' AS period_end
), fixtures AS (
    SELECT 2401::bigint AS id, 1::bigint AS customer_id,
           bounds.period_start AS awarded_at
      FROM report_bounds bounds
    UNION ALL
    SELECT 2402, 2, bounds.period_start - INTERVAL '1 microsecond'
      FROM report_bounds bounds
    UNION ALL
    SELECT 2403, 2, bounds.period_end
      FROM report_bounds bounds
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
    'six-month-boundary-' || fixture.id,
    'ANALYTICS-SIX-MONTH-' || fixture.id,
    'Проверка шестимесячной границы ' || fixture.id,
    fixture.customer_id,
    'completed',
    fixture.awarded_at - INTERVAL '10 days',
    fixture.awarded_at - INTERVAL '1 day',
    fixture.awarded_at
FROM fixtures fixture;

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
    (2401, 2401, 1, 'Нижняя граница включена', 100.00, 'AUD', 'completed'),
    (2402, 2402, 1, 'До нижней границы исключено', 100000.00, 'AUD', 'completed'),
    (2403, 2403, 1, 'Верхняя граница исключена', 100000.00, 'AUD', 'completed');

WITH report_bounds AS (
    SELECT
        (
            date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
            - INTERVAL '6 months'
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
SELECT 2401, 2401, 3, 90.00, bounds.period_start, 'completed'
  FROM report_bounds bounds
UNION ALL
SELECT 2402, 2402, 4, 99999.00, bounds.period_start - INTERVAL '1 microsecond', 'completed'
  FROM report_bounds bounds
UNION ALL
SELECT 2403, 2403, 5, 99999.00, bounds.period_end, 'completed'
  FROM report_bounds bounds;

DO $test$
DECLARE
    actual_customer_id bigint;
    actual_initial_amount numeric;
    actual_awarded_amount numeric;
    actual_count bigint;
    expected_report_month date := (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '6 months'
    )::date;
BEGIN
    SELECT
        count(*),
        min(customer_company_id),
        min(initial_amount),
        min(awarded_amount)
      INTO
        actual_count,
        actual_customer_id,
        actual_initial_amount,
        actual_awarded_amount
      FROM v_customer_efficiency_last_six_months
     WHERE currency_code = 'AUD';

    IF actual_count IS DISTINCT FROM 1
       OR actual_customer_id IS DISTINCT FROM 1
       OR actual_initial_amount IS DISTINCT FROM 100.00
       OR actual_awarded_amount IS DISTINCT FROM 90.00 THEN
        RAISE EXCEPTION
            'Six-month boundary mismatch: count %, customer %, initial %, awarded %',
            actual_count,
            actual_customer_id,
            actual_initial_amount,
            actual_awarded_amount;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM v_customer_efficiency_last_six_months
         WHERE currency_code = 'AUD'
           AND customer_company_id = 1
           AND report_month = expected_report_month
    ) THEN
        RAISE EXCEPTION 'Included lower-bound row has an unexpected report month';
    END IF;
END
$test$;

ROLLBACK;

SELECT 'six_month_boundary_contract_passed' AS result;
