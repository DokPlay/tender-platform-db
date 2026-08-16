[Русская версия](README.ru.md)

# Tender Platform DB

A verifiable PostgreSQL schema design and implementation for monitoring public procurement.

## Overview

The project contains the five required business tables:

- `companies` — a shared directory of customers, bidders, and winners;
- `tenders` — procurement notices associated with a customer company;
- `lots` — individual tender lots;
- `bids` — versioned price proposals submitted by bidders;
- `executors` — lot award results assigned to winning companies.

`executors` is the source of truth for both the winner and the awarded amount. Company details are not duplicated in a separate contractor directory.

```mermaid
erDiagram
    COMPANIES ||--o{ TENDERS : customer
    TENDERS ||--o{ LOTS : contains
    COMPANIES ||--o{ BIDS : submits
    LOTS ||--o{ BIDS : receives
    COMPANIES ||--o{ EXECUTORS : wins
    LOTS ||--o| EXECUTORS : awarded_to
```

## Project structure

```text
sql/
  tender_platform.sql
  01_schema.sql
  02_sample_data.sql
  analytics/
    01_top_companies_previous_month.sql
    02_customer_efficiency.sql
scripts/
  test.ps1
tests/
  fixtures/
    failing_analytics.sql
  01_schema_contract.sql
  02_constraints.sql
  03_fixture_contract.sql
  04_analytics_contract.sql
  05_cancelled_award_contract.sql
  06_exact_ranking_contract.sql
  07_boundary_currency_contract.sql
  08_latest_bid_version_contract.sql
  09_six_month_boundary_contract.sql
  10_zero_price_contract.sql
  11_status_isolation_contract.sql
  12_data_hygiene_defaults_contract.sql
  13_lifecycle_contract.sql
  14_average_rounding_contract.sql
  15_top_exact_money_contract.sql
```

## Requirements

- PostgreSQL 16 or newer;
- Docker and PowerShell 7 for automated verification.

The scripts use only standard PostgreSQL 16 features and require no extensions.
The complete automated test suite has been run on PostgreSQL 16 and PostgreSQL 18.

## Quick verification with Docker

Run from the project root:

```powershell
.\scripts\test.ps1
```

The script:

1. starts a temporary `postgres:16-alpine` container;
2. deploys the schema into a clean database;
3. verifies all required columns, data types, defaults, `NOT NULL` constraints, `GENERATED ALWAYS` identities, primary keys, business constraints, exactly six foreign keys, workload indexes, and lifecycle triggers;
4. proves that invalid data is rejected, including negative monetary values and `NaN`;
5. loads reproducible sample data;
6. runs and verifies both deliverable analytical queries;
7. checks cancelled and terminated results, independent tender and lot statuses, company names, exact cent-level amounts, zero-value awards, tied rankings, `NULLS LAST`, the latest bid version, the report-month source, average rounding, currencies, and period boundaries;
8. checks the complete Unicode White_Space set, finite timestamps, business defaults, final-state semantics of deferred lifecycle constraints (including identity-key changes), and cross-table bid and award timing rules;
9. reproduces concurrent tender-date changes against both an award and a bid in two parallel sessions and verifies that integrity is preserved;
10. analyzes JSON plans for 60,000 lots and 240,000 bids: the `awarded_at` range must remain an index condition, and admitted bids must use a covering `Index Only Scan` with no heap fetches;
11. proves that the internal schema component cannot be run directly and leave tables in `public`;
12. deliberately breaks the second installation stage to prove a complete rollback, and verifies that a repeated clean-only installation fails safely without losing existing data;
13. removes only the container it created.

## Manual installation with psql

Run against an existing empty database:

```powershell
psql -v ON_ERROR_STOP=1 -f sql/tender_platform.sql
```

The single entry-point script creates the schema, tables, constraints, indexes, and two analytical views in one transaction. An error at any stage rolls back the entire installation. Sample data is intentionally excluded from production deployment. To inspect a verified result after installation, run:

```powershell
psql -v ON_ERROR_STOP=1 -f sql/02_sample_data.sql
psql -v ON_ERROR_STOP=1 -f sql/analytics/01_top_companies_previous_month.sql
psql -v ON_ERROR_STOP=1 -f sql/analytics/02_customer_efficiency.sql
```

`tender_platform.sql` intentionally targets a clean database: running it again without removing the schema fails, protecting existing data from implicit replacement.
`01_schema.sql` is an internal component protected against direct execution; use only the entry-point script shown above.

## Data integrity

The schema provides:

- `bigint GENERATED ALWAYS AS IDENTITY` and a primary key for every table;
- six foreign keys with `ON DELETE RESTRICT`;
- uniqueness for tax IDs, each tender's source/external-ID pair, lot numbers within a tender, and bidder bid versions;
- one award result per lot in version 1;
- a mandatory completion timestamp for completed tenders that cannot precede the submission deadline;
- non-empty identifier and name checks, plus rejection of leading and trailing Unicode whitespace;
- non-negative `numeric(20,2)` monetary values with an explicit `NaN` prohibition;
- controlled statuses enforced by named `CHECK` constraints;
- finite `timestamptz` values with no `infinity` or `-infinity`;
- deferred constraint triggers that validate the final row state: a bid must fall between publication and submission deadline, while an award cannot precede the deadline; reverse updates to tender dates and lot ownership revalidate existing child rows;
- indexes for foreign-key joins, active tenders, bids, and award reports;
- a compact covering partial index limited to admitted bids for competition analytics.

Historical procurement data is not deleted through cascading operations. If a record is already referenced by a tender, lot, bid, or award result, deleting its parent must be explicit and controlled.

## Analytical query 1

[`01_top_companies_previous_month.sql`](sql/analytics/01_top_companies_previous_month.sql) returns the three companies with the highest total awarded lot value for the previous fully completed calendar month.

Rules:

- month boundaries are calculated in the `Europe/Moscow` time zone;
- a half-open interval `[start of previous month, start of current month)` is used;
- terminated results, cancelled tenders, and cancelled lots are excluded;
- totals use `executors.awarded_amount`, not the initial price;
- lots and distinct tenders are counted separately;
- amounts in different currencies are never combined, so each currency has its own top list;
- `row_number()` and the company ID produce up to three deterministic rows per currency.

The query creates `tender_platform.v_top_companies_previous_month` and outputs its contents.
The company name is joined after aggregation and the top-three restriction, keeping the text field out of intermediate grouping.

## Analytical query 2

[`02_customer_efficiency.sql`](sql/analytics/02_customer_efficiency.sql) calculates customer efficiency for the last six fully completed months:

- number of completed lots;
- average number of admitted bidders per lot;
- initial and awarded amounts;
- absolute and percentage savings;
- customer rank within each month and currency.

Only the completed lots in the six-month reporting window are materialized first. For each bidder, the status of the version with the highest `version_no` is used: the bidder is admitted only when that latest version has the `admitted` status. Candidates and their `version_no` values are read from the covering partial index, while the unique `(lot_id, bidder_company_id, version_no)` index is used to check for a newer version. Aggregation takes place at the lot level, so versions of the same bid are not counted as separate bidders and joining bids does not multiply monetary totals.

The customer name is joined after totals and ranks have been calculated, keeping the wide text field out of the materialized lot set and intermediate grouping.

Customer rank is calculated from the exact savings percentage. Rounding to two decimal places is applied only for display, so close values do not change their correct ranking order.

The final output is fully deterministic: `NULL` ranks appear last, and ties are resolved by customer ID.

When a group's total initial amount is zero, its savings percentage is mathematically undefined: `savings_percent` and `customer_rank` are returned as `NULL`, while the monetary values are preserved.

The query creates `tender_platform.v_customer_efficiency_last_six_months` and outputs its contents.

## Version 1 assumptions

- each tender has one customer;
- the loader or application ensures that every tender has at least one lot, because foreign keys alone cannot express this rule;
- each lot has at most one active executor;
- a company may submit multiple versions of a bid;
- a win is determined by the lot award timestamp;
- the won amount is the awarded amount, not actual payments;
- the reporting time zone is `Europe/Moscow`;
- amounts in different currencies are analyzed separately.

## License

[MIT](LICENSE), © 2026 DokPlay.
