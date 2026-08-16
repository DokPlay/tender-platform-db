\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO tender_platform, public;

DO $test$
BEGIN
    IF tender_platform.has_non_whitespace(E'\t\n') IS DISTINCT FROM false
       OR tender_platform.has_non_whitespace(U&'\00A0') IS DISTINCT FROM false
       OR tender_platform.has_non_whitespace('A B') IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Unicode-aware non-whitespace detection is incorrect';
    END IF;

    IF tender_platform.has_canonical_edges(' A') IS DISTINCT FROM false
       OR tender_platform.has_canonical_edges(E'A\t') IS DISTINCT FROM false
       OR tender_platform.has_canonical_edges(U&'\00A0A') IS DISTINCT FROM false
       OR tender_platform.has_canonical_edges('A B') IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Unicode-aware edge-whitespace detection is incorrect';
    END IF;
END
$test$;

INSERT INTO companies (id, name, tax_id)
OVERRIDING SYSTEM VALUE
VALUES
    (2701, 'Default customer', 'DEFAULT-CUSTOMER-2701'),
    (2702, 'Default bidder', 'DEFAULT-BIDDER-2702');

INSERT INTO tenders (
    id,
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
VALUES (
    2701,
    'defaults-tender',
    'DEFAULTS-2701',
    'Default values contract',
    2701,
    'completed',
    timestamptz '2026-01-01 09:00:00+03',
    timestamptz '2026-01-10 18:00:00+03',
    timestamptz '2026-01-12 12:00:00+03'
);

INSERT INTO lots (
    id,
    tender_id,
    lot_number,
    title,
    initial_price,
    status
)
OVERRIDING SYSTEM VALUE
VALUES
    (2701, 2701, 1, 'Default currency lot', 100.00, 'completed'),
    (2702, 2701, 2, 'Finite executor probe lot', 100.00, 'completed');

INSERT INTO bids (
    id,
    lot_id,
    bidder_company_id,
    amount,
    submitted_at,
    status
)
OVERRIDING SYSTEM VALUE
VALUES (
    2701,
    2701,
    2702,
    90.00,
    timestamptz '2026-01-05 12:00:00+03',
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
    2701,
    2701,
    2702,
    90.00,
    timestamptz '2026-01-11 12:00:00+03',
    'completed'
);

DO $test$
DECLARE
    actual_source text;
    actual_currency character(3);
    actual_version integer;
    all_created_at_finite boolean;
    violated_constraint text;
BEGIN
    SELECT source_system
      INTO STRICT actual_source
      FROM tenders
     WHERE id = 2701;

    SELECT currency_code
      INTO STRICT actual_currency
      FROM lots
     WHERE id = 2701;

    SELECT version_no
      INTO STRICT actual_version
      FROM bids
     WHERE id = 2701;

    SELECT bool_and(isfinite(created_at))
      INTO all_created_at_finite
      FROM (
          SELECT created_at FROM companies WHERE id IN (2701, 2702)
          UNION ALL SELECT created_at FROM tenders WHERE id = 2701
          UNION ALL SELECT created_at FROM lots WHERE id IN (2701, 2702)
          UNION ALL SELECT created_at FROM bids WHERE id = 2701
          UNION ALL SELECT created_at FROM executors WHERE id = 2701
      ) defaults_created_at;

    IF actual_source IS DISTINCT FROM 'zakupki.gov.ru'
       OR actual_currency IS DISTINCT FROM 'RUB'::character(3)
       OR actual_version IS DISTINCT FROM 1
       OR all_created_at_finite IS DISTINCT FROM true THEN
        RAISE EXCEPTION
            'Default mismatch: source %, currency %, version %, finite created_at %',
            actual_source,
            actual_currency,
            actual_version,
            all_created_at_finite;
    END IF;

    BEGIN
        INSERT INTO companies (id, name, tax_id)
        OVERRIDING SYSTEM VALUE
        VALUES (2710, ' Padded company', 'PADDED-NAME-2710');
        RAISE EXCEPTION 'Leading whitespace in company name was accepted';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_companies_name_canonical_edges' THEN
                RAISE EXCEPTION
                    'Padded company name violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO companies (id, name, tax_id)
        OVERRIDING SYSTEM VALUE
        VALUES (2711, 'Padded tax ID', ' PADDED-TAX-2711 ');
        RAISE EXCEPTION 'Edge whitespace in tax ID was accepted';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_companies_tax_id_canonical_edges' THEN
                RAISE EXCEPTION
                    'Padded tax ID violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO companies (id, name, tax_id, created_at)
        OVERRIDING SYSTEM VALUE
        VALUES (2712, 'Infinite company date', 'INFINITE-COMPANY-2712', 'infinity');
        RAISE EXCEPTION 'Infinite company created_at was accepted';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_companies_finite_times' THEN
                RAISE EXCEPTION
                    'Infinite company date violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
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
        VALUES (
            2713,
            'hygiene-test',
            'infinite-tender',
            'INFINITE-TENDER-2713',
            'Infinite tender date',
            2701,
            'completed',
            '-infinity',
            'infinity',
            'infinity'
        );
        RAISE EXCEPTION 'Infinite tender dates were accepted';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_tenders_finite_times' THEN
                RAISE EXCEPTION
                    'Infinite tender date violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
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
        VALUES (2714, 2702, 2702, 1, 90.00, 'infinity', 'admitted');
        RAISE EXCEPTION 'Infinite bid submitted_at was accepted';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_bids_finite_times' THEN
                RAISE EXCEPTION
                    'Infinite bid date violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO executors (
            id,
            lot_id,
            company_id,
            awarded_amount,
            awarded_at,
            status
        )
        OVERRIDING SYSTEM VALUE
        VALUES (2715, 2702, 2702, 90.00, 'infinity', 'awarded');
        RAISE EXCEPTION 'Infinite executor awarded_at was accepted';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_executors_finite_times' THEN
                RAISE EXCEPTION
                    'Infinite executor date violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;
END
$test$;

ROLLBACK;

SELECT 'data_hygiene_defaults_contract_passed' AS result;
