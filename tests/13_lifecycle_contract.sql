\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO tender_platform, public;

INSERT INTO companies (id, name, tax_id)
OVERRIDING SYSTEM VALUE
VALUES
    (2801, 'Lifecycle customer', 'LIFECYCLE-CUSTOMER-2801'),
    (2802, 'Lifecycle bidder', 'LIFECYCLE-BIDDER-2802');

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
VALUES
    (
        2801,
        'lifecycle-test',
        'lifecycle-primary',
        'LIFECYCLE-PRIMARY-2801',
        'Primary lifecycle tender',
        2801,
        'completed',
        timestamptz '2026-01-10 09:00:00+03',
        timestamptz '2026-01-20 18:00:00+03',
        timestamptz '2026-01-25 12:00:00+03'
    ),
    (
        2802,
        'lifecycle-test',
        'lifecycle-incompatible',
        'LIFECYCLE-INCOMPATIBLE-2802',
        'Incompatible lifecycle tender',
        2801,
        'completed',
        timestamptz '2026-02-01 09:00:00+03',
        timestamptz '2026-02-10 18:00:00+03',
        timestamptz '2026-02-12 12:00:00+03'
    );

INSERT INTO lots (id, tender_id, lot_number, title, initial_price, currency_code, status)
OVERRIDING SYSTEM VALUE
VALUES
    (2801, 2801, 1, 'Lifecycle lot', 100.00, 'RUB', 'completed'),
    (2802, 2801, 2, 'Deferred executor repair lot', 100.00, 'RUB', 'completed');

DO $test$
DECLARE
    violated_constraint text;
BEGIN
    BEGIN
        INSERT INTO bids (
            id, lot_id, bidder_company_id, version_no,
            amount, submitted_at, status
        )
        OVERRIDING SYSTEM VALUE
        VALUES (
            2810, 2801, 2802, 1,
            95.00, timestamptz '2026-01-09 12:00:00+03', 'admitted'
        );
        RAISE EXCEPTION 'Bid before tender publication was accepted';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ct_bids_submission_window' THEN
                RAISE EXCEPTION
                    'Early bid violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO bids (
            id, lot_id, bidder_company_id, version_no,
            amount, submitted_at, status
        )
        OVERRIDING SYSTEM VALUE
        VALUES (
            2811, 2801, 2802, 1,
            95.00, timestamptz '2026-01-21 12:00:00+03', 'admitted'
        );
        RAISE EXCEPTION 'Bid after tender deadline was accepted';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ct_bids_submission_window' THEN
                RAISE EXCEPTION
                    'Late bid violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    INSERT INTO bids (
        id, lot_id, bidder_company_id, version_no,
        amount, submitted_at, status
    )
    OVERRIDING SYSTEM VALUE
    VALUES (
        2801, 2801, 2802, 1,
        95.00, timestamptz '2026-01-15 12:00:00+03', 'admitted'
    );

    BEGIN
        INSERT INTO executors (
            id, lot_id, company_id, awarded_amount, awarded_at, status
        )
        OVERRIDING SYSTEM VALUE
        VALUES (
            2812, 2801, 2802, 95.00,
            timestamptz '2026-01-19 12:00:00+03', 'awarded'
        );
        RAISE EXCEPTION 'Executor award before tender deadline was accepted';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ct_executors_award_window' THEN
                RAISE EXCEPTION
                    'Early executor award violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    INSERT INTO executors (
        id, lot_id, company_id, awarded_amount, awarded_at, status
    )
    OVERRIDING SYSTEM VALUE
    VALUES (
        2801, 2801, 2802, 95.00,
        timestamptz '2026-01-21 12:00:00+03', 'completed'
    );

    BEGIN
        UPDATE tenders
           SET published_at = timestamptz '2026-01-16 09:00:00+03'
         WHERE id = 2801;
        RAISE EXCEPTION 'Parent tender update invalidated an existing bid';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ct_tenders_related_timing' THEN
                RAISE EXCEPTION
                    'Invalid tender date update violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        UPDATE tenders
           SET submission_deadline_at = timestamptz '2026-01-22 18:00:00+03',
               completed_at = timestamptz '2026-01-25 12:00:00+03'
         WHERE id = 2801;
        RAISE EXCEPTION 'Parent tender update invalidated an existing award';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ct_tenders_related_timing' THEN
                RAISE EXCEPTION
                    'Invalid tender deadline update violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    SET CONSTRAINTS
        ct_tenders_related_timing,
        ct_bids_submission_window
        DEFERRED;

    UPDATE tenders
       SET published_at = timestamptz '2026-01-16 09:00:00+03'
     WHERE id = 2801;

    UPDATE bids
       SET submitted_at = timestamptz '2026-01-17 12:00:00+03'
     WHERE id = 2801;

    SET CONSTRAINTS ALL IMMEDIATE;

    SET CONSTRAINTS ct_bids_submission_window DEFERRED;

    INSERT INTO bids (
        id, lot_id, bidder_company_id, version_no,
        amount, submitted_at, status
    )
    OVERRIDING SYSTEM VALUE
    VALUES (
        2820, 2801, 2802, 2,
        94.00, timestamptz '2026-01-09 12:00:00+03', 'admitted'
    );

    UPDATE bids
       SET submitted_at = timestamptz '2026-01-17 13:00:00+03'
     WHERE id = 2820;

    SET CONSTRAINTS ct_bids_submission_window IMMEDIATE;

    SET CONSTRAINTS ct_executors_award_window DEFERRED;

    INSERT INTO executors (
        id, lot_id, company_id, awarded_amount, awarded_at, status
    )
    OVERRIDING SYSTEM VALUE
    VALUES (
        2821, 2802, 2802, 94.00,
        timestamptz '2026-01-19 12:00:00+03', 'completed'
    );

    UPDATE executors
       SET awarded_at = timestamptz '2026-01-21 13:00:00+03'
     WHERE id = 2821;

    SET CONSTRAINTS ct_executors_award_window IMMEDIATE;

    SET CONSTRAINTS ct_tenders_related_timing DEFERRED;

    UPDATE tenders
       SET published_at = timestamptz '2026-01-18 09:00:00+03'
     WHERE id = 2801;

    UPDATE tenders
       SET published_at = timestamptz '2026-01-16 09:00:00+03'
     WHERE id = 2801;

    SET CONSTRAINTS ct_tenders_related_timing IMMEDIATE;

    SET CONSTRAINTS ct_lots_related_timing DEFERRED;

    UPDATE lots
       SET tender_id = 2802
     WHERE id = 2801;

    UPDATE lots
       SET tender_id = 2801
     WHERE id = 2801;

    SET CONSTRAINTS ct_lots_related_timing IMMEDIATE;

    BEGIN
        UPDATE lots
           SET tender_id = 2802
         WHERE id = 2801;
        RAISE EXCEPTION 'Lot reassignment invalidated related bid and award dates';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ct_lots_related_timing' THEN
                RAISE EXCEPTION
                    'Invalid lot reassignment violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;
END
$test$;

ROLLBACK;

SELECT 'lifecycle_contract_passed' AS result;
