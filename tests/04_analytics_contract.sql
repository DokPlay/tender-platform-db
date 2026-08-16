\set ON_ERROR_STOP on

SET search_path TO tender_platform, public;

\ir ../sql/analytics/01_top_companies_previous_month.sql
\ir ../sql/analytics/02_customer_efficiency.sql

-- An interim award on a tender that is still under evaluation must not appear
-- in a report explicitly defined as completed procurement efficiency.
INSERT INTO tenders (
    id,
    source_system,
    external_id,
    procurement_number,
    title,
    customer_company_id,
    status,
    published_at,
    submission_deadline_at
)
OVERRIDING SYSTEM VALUE
VALUES (
    1001,
    'analytics-test',
    'incomplete-tender',
    'ANALYTICS-INCOMPLETE',
    'Незавершённая закупка для регрессионной проверки',
    2,
    'evaluation',
    (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '3 months 10 days'
    ) AT TIME ZONE 'Europe/Moscow',
    (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '3 months 1 day'
    ) AT TIME ZONE 'Europe/Moscow'
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
VALUES (
    1001,
    1001,
    1,
    'Незавершённый лот для регрессионной проверки',
    50000000.00,
    'RUB',
    'evaluation'
);

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
VALUES (
    1001,
    1001,
    6,
    1,
    49000000.00,
    (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '3 months 2 days'
    ) AT TIME ZONE 'Europe/Moscow',
    'admitted'
);

INSERT INTO executors (
    id,
    lot_id,
    company_id,
    awarded_amount,
    awarded_at,
    status
)
OVERRIDING SYSTEM VALUE
VALUES (
    1001,
    1001,
    6,
    49000000.00,
    (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '2 months 20 days'
    ) AT TIME ZONE 'Europe/Moscow',
    'awarded'
);

CREATE TEMPORARY TABLE actual_top_companies AS
SELECT * FROM v_top_companies_previous_month;

CREATE TEMPORARY TABLE actual_customer_efficiency AS
SELECT * FROM v_customer_efficiency_last_six_months;

DO $test$
DECLARE
    actual_count bigint;
    previous_month date := (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    )::date;
    expected_period_start timestamptz := (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    ) AT TIME ZONE 'Europe/Moscow';
    expected_period_end timestamptz := (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
    ) AT TIME ZONE 'Europe/Moscow';
BEGIN
    SELECT count(*) INTO actual_count FROM actual_top_companies;
    IF actual_count <> 3 THEN
        RAISE EXCEPTION 'Expected exactly 3 top-company rows, found %', actual_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM actual_top_companies
         WHERE rank_in_currency = 1
           AND company_id = 3
           AND company_name = 'ООО «Альфа-Строй»'
           AND currency_code = 'RUB'
           AND total_awarded_amount = 1500000.00
           AND won_lot_count = 2
           AND won_tender_count = 1
           AND period_start = expected_period_start
           AND period_end = expected_period_end
    ) THEN
        RAISE EXCEPTION 'Top-company rank 1 does not match the hand-checked fixture';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM actual_top_companies
         WHERE rank_in_currency = 2
           AND company_id = 4
           AND total_awarded_amount = 1200000.00
           AND won_lot_count = 1
           AND won_tender_count = 1
    ) THEN
        RAISE EXCEPTION 'Top-company rank 2 does not match the hand-checked fixture';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM actual_top_companies
         WHERE rank_in_currency = 3
           AND company_id = 5
           AND total_awarded_amount = 700000.00
           AND won_lot_count = 1
           AND won_tender_count = 1
    ) THEN
        RAISE EXCEPTION 'Top-company rank 3 does not match the hand-checked fixture';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM actual_top_companies
         WHERE company_id = 6
           AND total_awarded_amount >= 9000000.00
    ) THEN
        RAISE EXCEPTION 'Terminated award leaked into the top-company report';
    END IF;

    SELECT count(*) INTO actual_count FROM actual_customer_efficiency;
    IF actual_count <> 3 THEN
        RAISE EXCEPTION 'Expected 3 customer-efficiency rows, found %', actual_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM actual_customer_efficiency
         WHERE report_month = previous_month
           AND customer_rank = 1
           AND customer_company_id = 2
           AND currency_code = 'RUB'
           AND completed_lot_count = 2
           AND average_admitted_bidders = 2.50
           AND initial_amount = 1400000.00
           AND awarded_amount = 1200000.00
           AND savings_amount = 200000.00
           AND savings_percent = 14.29
    ) THEN
        RAISE EXCEPTION 'Previous-month efficiency rank 1 is incorrect';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM actual_customer_efficiency
         WHERE report_month = previous_month
           AND customer_rank = 2
           AND customer_company_id = 1
           AND currency_code = 'RUB'
           AND completed_lot_count = 3
           AND average_admitted_bidders = 2.00
           AND initial_amount = 3100000.00
           AND awarded_amount = 2700000.00
           AND savings_amount = 400000.00
           AND savings_percent = 12.90
    ) THEN
        RAISE EXCEPTION 'Previous-month efficiency rank 2 is incorrect';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM actual_customer_efficiency
         WHERE report_month = (previous_month - INTERVAL '2 months')::date
           AND customer_rank = 1
           AND customer_company_id = 1
           AND completed_lot_count = 1
           AND average_admitted_bidders = 2.00
           AND initial_amount = 400000.00
           AND awarded_amount = 350000.00
           AND savings_amount = 50000.00
           AND savings_percent = 12.50
    ) THEN
        RAISE EXCEPTION 'Older-month customer efficiency row is incorrect';
    END IF;
END
$test$;

SELECT 'analytics_contract_passed' AS result;
