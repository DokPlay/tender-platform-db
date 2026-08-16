\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO tender_platform, public;

INSERT INTO companies (id, name, tax_id)
OVERRIDING SYSTEM VALUE
VALUES
    (9001, 'Тестовый заказчик', 'TEST-CUSTOMER-9001'),
    (9002, 'Тестовый участник', 'TEST-BIDDER-9002'),
    (9003, 'Второй участник', 'TEST-BIDDER-9003');

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
    9001,
    'test',
    'tender-9001',
    'TEST-9001',
    'Проверка ограничений',
    9001,
    'completed',
    timestamptz '2026-01-01 09:00:00+03',
    timestamptz '2026-01-05 18:00:00+03',
    timestamptz '2026-01-10 12:00:00+03'
);

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
VALUES
    (
        9101,
        'source-a',
        'shared-external-id',
        'TEST-SOURCE-A',
        'Одинаковый внешний ID в первом источнике',
        9001,
        'published',
        timestamptz '2026-01-01 09:00:00+03',
        timestamptz '2026-01-05 18:00:00+03'
    ),
    (
        9102,
        'source-b',
        'shared-external-id',
        'TEST-SOURCE-B',
        'Одинаковый внешний ID во втором источнике',
        9001,
        'published',
        timestamptz '2026-01-01 09:00:00+03',
        timestamptz '2026-01-05 18:00:00+03'
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
    (
        9001,
        9001,
        1,
        'Тестовый лот',
        1000.00,
        'RUB',
        'awarded'
    ),
    (
        9002,
        9001,
        2,
        'Лот без результата',
        500.00,
        'RUB',
        'open'
    ),
    (
        9003,
        9001,
        3,
        'Лот с нулевой начальной ценой',
        0.00,
        'RUB',
        'awarded'
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
VALUES
    (
        9001,
        9001,
        9002,
        1,
        900.00,
        timestamptz '2026-01-04 12:00:00+03',
        'admitted'
    ),
    (
        9002,
        9003,
        9003,
        1,
        0.00,
        timestamptz '2026-01-04 12:30:00+03',
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
VALUES
    (
        9001,
        9001,
        9002,
        900.00,
        timestamptz '2026-01-10 12:00:00+03',
        'completed'
    ),
    (
        9002,
        9003,
        9003,
        0.00,
        timestamptz '2026-01-10 12:30:00+03',
        'completed'
    );

DO $test$
DECLARE
    violated_constraint text;
BEGIN
    BEGIN
        INSERT INTO companies (name, tax_id)
        VALUES ('Дубликат ИНН', 'TEST-CUSTOMER-9001');
        RAISE EXCEPTION 'uq_companies_tax_id did not reject a duplicate tax_id';
    EXCEPTION
        WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'uq_companies_tax_id' THEN
                RAISE EXCEPTION
                    'Duplicate tax_id violated unexpected constraint %',
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
            submission_deadline_at
        )
        OVERRIDING SYSTEM VALUE
        VALUES (
            9103,
            'source-a',
            'shared-external-id',
            'TEST-SOURCE-A-DUPLICATE',
            'Дубликат пары источника и внешнего ID',
            9001,
            'published',
            timestamptz '2026-01-01 09:00:00+03',
            timestamptz '2026-01-05 18:00:00+03'
        );
        RAISE EXCEPTION
            'uq_tenders_source_external did not reject a duplicate source pair';
    EXCEPTION
        WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint
               IS DISTINCT FROM 'uq_tenders_source_external' THEN
                RAISE EXCEPTION
                    'Duplicate tender source pair violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO tenders (
            source_system,
            external_id,
            procurement_number,
            title,
            customer_company_id,
            status,
            published_at,
            submission_deadline_at
        )
        VALUES (
            'test',
            'invalid-status',
            'INVALID-STATUS',
            'Недопустимый статус',
            9001,
            'unknown',
            timestamptz '2026-01-01 09:00:00+03',
            timestamptz '2026-01-05 18:00:00+03'
        );
        RAISE EXCEPTION 'ck_tenders_status did not reject an invalid status';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_tenders_status' THEN
                RAISE EXCEPTION
                    'Invalid tender status violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO tenders (
            source_system,
            external_id,
            procurement_number,
            title,
            customer_company_id,
            status,
            published_at,
            submission_deadline_at
        )
        VALUES (
            'test',
            'completed-without-completed-at',
            'INVALID-COMPLETED-MISSING',
            'Завершённый тендер без даты завершения',
            9001,
            'completed',
            timestamptz '2026-02-01 09:00:00+03',
            timestamptz '2026-02-05 18:00:00+03'
        );
        RAISE EXCEPTION
            'ck_tenders_completed_state did not require completed_at for a completed tender';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_tenders_completed_state' THEN
                RAISE EXCEPTION
                    'Missing completed_at violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO tenders (
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
        VALUES (
            'test',
            'completed-before-deadline',
            'INVALID-COMPLETED-EARLY',
            'Завершённый тендер раньше срока подачи заявок',
            9001,
            'completed',
            timestamptz '2026-02-01 09:00:00+03',
            timestamptz '2026-02-05 18:00:00+03',
            timestamptz '2026-02-03 12:00:00+03'
        );
        RAISE EXCEPTION
            'ck_tenders_completed_state allowed completion before the submission deadline';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_tenders_completed_state' THEN
                RAISE EXCEPTION
                    'Early completion violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO tenders (
            source_system,
            external_id,
            procurement_number,
            title,
            customer_company_id,
            status,
            published_at,
            submission_deadline_at
        )
        VALUES (
            'test',
            'invalid-dates',
            'INVALID-DATES',
            'Недопустимые даты',
            9001,
            'published',
            timestamptz '2026-01-05 18:00:00+03',
            timestamptz '2026-01-01 09:00:00+03'
        );
        RAISE EXCEPTION 'ck_tenders_submission_window did not reject an invalid deadline';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_tenders_submission_window' THEN
                RAISE EXCEPTION
                    'Invalid submission window violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO lots (
            tender_id,
            lot_number,
            title,
            initial_price,
            currency_code,
            status
        )
        VALUES (999999, 1, 'Лот без тендера', 100.00, 'RUB', 'open');
        RAISE EXCEPTION 'fk_lots_tender did not reject an orphan lot';
    EXCEPTION
        WHEN foreign_key_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'fk_lots_tender' THEN
                RAISE EXCEPTION
                    'Orphan lot violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO lots (
            tender_id,
            lot_number,
            title,
            initial_price,
            currency_code,
            status
        )
        VALUES (9001, 4, 'Отрицательная цена', -1.00, 'RUB', 'open');
        RAISE EXCEPTION 'ck_lots_initial_price did not reject a negative amount';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_lots_initial_price' THEN
                RAISE EXCEPTION
                    'Negative lot price violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO lots (
            tender_id,
            lot_number,
            title,
            initial_price,
            currency_code,
            status
        )
        VALUES (9001, 5, 'Цена NaN', 'NaN'::numeric, 'RUB', 'open');
        RAISE EXCEPTION 'ck_lots_initial_price did not reject NaN';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_lots_initial_price' THEN
                RAISE EXCEPTION
                    'NaN lot price violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO lots (
            tender_id,
            lot_number,
            title,
            initial_price,
            currency_code,
            status
        )
        VALUES (9001, 1, 'Дубликат номера лота', 100.00, 'RUB', 'open');
        RAISE EXCEPTION 'uq_lots_tender_number did not reject a duplicate lot number';
    EXCEPTION
        WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'uq_lots_tender_number' THEN
                RAISE EXCEPTION
                    'Duplicate lot number violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO bids (
            lot_id,
            bidder_company_id,
            version_no,
            amount,
            submitted_at,
            status
        )
        VALUES (
            9002,
            9003,
            1,
            -1.00,
            timestamptz '2026-01-04 13:00:00+03',
            'submitted'
        );
        RAISE EXCEPTION 'ck_bids_amount did not reject a negative amount';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_bids_amount' THEN
                RAISE EXCEPTION
                    'Negative bid amount violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO bids (
            lot_id,
            bidder_company_id,
            version_no,
            amount,
            submitted_at,
            status
        )
        VALUES (
            9002,
            9003,
            1,
            'NaN'::numeric,
            timestamptz '2026-01-04 13:30:00+03',
            'submitted'
        );
        RAISE EXCEPTION 'ck_bids_amount did not reject NaN';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_bids_amount' THEN
                RAISE EXCEPTION
                    'NaN bid amount violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO bids (
            lot_id,
            bidder_company_id,
            version_no,
            amount,
            submitted_at,
            status
        )
        VALUES (
            9001,
            9002,
            1,
            850.00,
            timestamptz '2026-01-04 14:00:00+03',
            'rejected'
        );
        RAISE EXCEPTION 'uq_bids_lot_bidder_version did not reject a duplicate version';
    EXCEPTION
        WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint
               IS DISTINCT FROM 'uq_bids_lot_bidder_version' THEN
                RAISE EXCEPTION
                    'Duplicate bid version violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO executors (
            lot_id,
            company_id,
            awarded_amount,
            awarded_at,
            status
        )
        VALUES (
            9001,
            9003,
            850.00,
            timestamptz '2026-01-10 13:00:00+03',
            'awarded'
        );
        RAISE EXCEPTION 'uq_executors_lot did not reject a second executor for one lot';
    EXCEPTION
        WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'uq_executors_lot' THEN
                RAISE EXCEPTION
                    'Second executor violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;

    BEGIN
        INSERT INTO executors (
            lot_id,
            company_id,
            awarded_amount,
            awarded_at,
            status
        )
        VALUES (
            9002,
            9003,
            -1.00,
            timestamptz '2026-01-10 13:00:00+03',
            'awarded'
        );
        RAISE EXCEPTION 'ck_executors_awarded_amount did not reject a negative amount';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint
               IS DISTINCT FROM 'ck_executors_awarded_amount' THEN
                RAISE EXCEPTION
                    'Negative awarded amount violated unexpected constraint %',
                    violated_constraint;
            END IF;
        WHEN unique_violation THEN
            RAISE EXCEPTION 'Negative award test reached uniqueness before amount validation';
    END;

    BEGIN
        INSERT INTO executors (
            lot_id,
            company_id,
            awarded_amount,
            awarded_at,
            status
        )
        VALUES (
            9002,
            9003,
            'NaN'::numeric,
            timestamptz '2026-01-10 14:00:00+03',
            'awarded'
        );
        RAISE EXCEPTION 'ck_executors_awarded_amount did not reject NaN';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
            IF violated_constraint IS DISTINCT FROM 'ck_executors_awarded_amount' THEN
                RAISE EXCEPTION
                    'NaN awarded amount violated unexpected constraint %',
                    violated_constraint;
            END IF;
    END;
END
$test$;

ROLLBACK;

SELECT 'constraint_contract_passed' AS result;
