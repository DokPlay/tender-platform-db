\set ON_ERROR_STOP on

/*
Query 2. Customer procurement efficiency for the last six fully closed
calendar months. Bidders and award facts are aggregated at lot grain before
customer totals are calculated, preventing multiplication of monetary values.
*/
CREATE OR REPLACE VIEW tender_platform.v_customer_efficiency_last_six_months AS
WITH report_bounds AS (
    SELECT
        (
            date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
            - INTERVAL '6 months'
        ) AT TIME ZONE 'Europe/Moscow' AS period_start,
        (
            date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        ) AT TIME ZONE 'Europe/Moscow' AS period_end
),
admitted_bidders_by_lot AS (
    SELECT
        bid.lot_id,
        count(DISTINCT bid.bidder_company_id) AS admitted_bidder_count
    FROM tender_platform.bids bid
    WHERE bid.status = 'admitted'
    GROUP BY bid.lot_id
),
lot_metrics AS (
    SELECT
        date_trunc(
            'month',
            executor.awarded_at AT TIME ZONE 'Europe/Moscow'
        )::date AS report_month,
        tender.customer_company_id,
        customer.name AS customer_name,
        lot.currency_code,
        lot.id AS lot_id,
        lot.initial_price,
        executor.awarded_amount,
        coalesce(bidders.admitted_bidder_count, 0) AS admitted_bidder_count
    FROM tender_platform.executors executor
    JOIN tender_platform.lots lot
      ON lot.id = executor.lot_id
    JOIN tender_platform.tenders tender
      ON tender.id = lot.tender_id
    JOIN tender_platform.companies customer
      ON customer.id = tender.customer_company_id
    LEFT JOIN admitted_bidders_by_lot bidders
      ON bidders.lot_id = lot.id
    CROSS JOIN report_bounds bounds
    WHERE executor.status IN ('awarded', 'contract_signed', 'performing', 'completed')
      AND tender.status = 'completed'
      AND lot.status = 'completed'
      AND executor.awarded_at >= bounds.period_start
      AND executor.awarded_at < bounds.period_end
),
customer_totals AS (
    SELECT
        report_month,
        customer_company_id,
        customer_name,
        currency_code,
        count(*) AS completed_lot_count,
        round(avg(admitted_bidder_count), 2) AS average_admitted_bidders,
        sum(initial_price) AS initial_amount,
        sum(awarded_amount) AS awarded_amount,
        sum(initial_price) - sum(awarded_amount) AS savings_amount,
        round(
            100 * (sum(initial_price) - sum(awarded_amount))
            / NULLIF(sum(initial_price), 0),
            2
        ) AS savings_percent
    FROM lot_metrics
    GROUP BY
        report_month,
        customer_company_id,
        customer_name,
        currency_code
),
ranked_customers AS (
    SELECT
        row_number() OVER (
            PARTITION BY report_month, currency_code
            ORDER BY savings_percent DESC NULLS LAST, customer_company_id
        ) AS customer_rank,
        report_month,
        customer_company_id,
        customer_name,
        currency_code,
        completed_lot_count,
        average_admitted_bidders,
        initial_amount,
        awarded_amount,
        savings_amount,
        savings_percent
    FROM customer_totals
)
SELECT
    customer_rank,
    report_month,
    customer_company_id,
    customer_name,
    currency_code,
    completed_lot_count,
    average_admitted_bidders,
    initial_amount,
    awarded_amount,
    savings_amount,
    savings_percent
FROM ranked_customers;

SELECT *
FROM tender_platform.v_customer_efficiency_last_six_months
ORDER BY report_month DESC, currency_code, customer_rank;
