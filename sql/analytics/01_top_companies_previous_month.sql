\set ON_ERROR_STOP on

/*
Query 1. Top three awarded suppliers for the previous fully closed
calendar month. Month boundaries are calculated in Europe/Moscow.

Awards are compared only inside one currency. Cancelled tenders and lots are
excluded even if an imported award still has an active status. row_number()
returns up to three rows per currency and resolves equal totals by company ID.
The company name is joined only after aggregation and top-three filtering.
*/
CREATE OR REPLACE VIEW tender_platform.v_top_companies_previous_month AS
WITH report_bounds AS (
    SELECT
        (
            date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
            - INTERVAL '1 month'
        ) AT TIME ZONE 'Europe/Moscow' AS period_start,
        (
            date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        ) AT TIME ZONE 'Europe/Moscow' AS period_end
),
company_totals AS (
    SELECT
        executor.company_id,
        lot.currency_code,
        sum(executor.awarded_amount) AS total_awarded_amount,
        count(*) AS won_lot_count,
        count(DISTINCT lot.tender_id) AS won_tender_count,
        bounds.period_start,
        bounds.period_end
    FROM tender_platform.executors executor
    JOIN tender_platform.lots lot
      ON lot.id = executor.lot_id
    JOIN tender_platform.tenders tender
      ON tender.id = lot.tender_id
    CROSS JOIN report_bounds bounds
    WHERE executor.status IN ('awarded', 'contract_signed', 'performing', 'completed')
      AND tender.status <> 'cancelled'
      AND lot.status <> 'cancelled'
      AND executor.awarded_at >= bounds.period_start
      AND executor.awarded_at < bounds.period_end
    GROUP BY
        executor.company_id,
        lot.currency_code,
        bounds.period_start,
        bounds.period_end
),
ranked_companies AS (
    SELECT
        row_number() OVER (
            PARTITION BY currency_code
            ORDER BY total_awarded_amount DESC, company_id
        ) AS rank_in_currency,
        company_id,
        currency_code,
        total_awarded_amount,
        won_lot_count,
        won_tender_count,
        period_start,
        period_end
    FROM company_totals
)
SELECT
    ranked.rank_in_currency,
    ranked.company_id,
    company.name AS company_name,
    ranked.currency_code,
    ranked.total_awarded_amount,
    ranked.won_lot_count,
    ranked.won_tender_count,
    ranked.period_start,
    ranked.period_end
FROM ranked_companies ranked
JOIN tender_platform.companies company
  ON company.id = ranked.company_id
WHERE ranked.rank_in_currency <= 3;

SELECT *
FROM tender_platform.v_top_companies_previous_month
ORDER BY currency_code, rank_in_currency;
