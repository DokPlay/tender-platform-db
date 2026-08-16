\set ON_ERROR_STOP on

-- Included by tender_platform.sql inside one transaction.
DO $install_guard$
BEGIN
    IF current_setting('tender_platform.install_context', true)
       IS DISTINCT FROM 'complete' THEN
        RAISE EXCEPTION USING
            ERRCODE = '55000',
            MESSAGE = 'sql/01_schema.sql is an internal component; run sql/tender_platform.sql';
    END IF;
END
$install_guard$;

CREATE SCHEMA tender_platform;
COMMENT ON SCHEMA tender_platform IS
    'Normalized data model for monitoring government procurement tenders.';

SET LOCAL search_path TO tender_platform, public;

CREATE FUNCTION has_non_whitespace(input_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
RETURN input_value ~ U&'[^\0009-\000D\0020\0085\00A0\1680\2000-\200A\2028-\2029\202F\205F\3000]';

CREATE FUNCTION has_canonical_edges(input_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
RETURN input_value !~ U&'(^[\0009-\000D\0020\0085\00A0\1680\2000-\200A\2028-\2029\202F\205F\3000])|([\0009-\000D\0020\0085\00A0\1680\2000-\200A\2028-\2029\202F\205F\3000]$)';

COMMENT ON FUNCTION has_non_whitespace(text) IS
    'True when text contains a character outside the Unicode White_Space property.';
COMMENT ON FUNCTION has_canonical_edges(text) IS
    'True when text has no leading or trailing Unicode White_Space character.';

CREATE TABLE companies (
    id bigint GENERATED ALWAYS AS IDENTITY,
    name text NOT NULL,
    tax_id text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_companies PRIMARY KEY (id),
    CONSTRAINT uq_companies_tax_id UNIQUE (tax_id),
    CONSTRAINT ck_companies_name_not_blank CHECK (has_non_whitespace(name)),
    CONSTRAINT ck_companies_name_canonical_edges CHECK (has_canonical_edges(name)),
    CONSTRAINT ck_companies_tax_id_not_blank CHECK (has_non_whitespace(tax_id)),
    CONSTRAINT ck_companies_tax_id_canonical_edges CHECK (has_canonical_edges(tax_id)),
    CONSTRAINT ck_companies_finite_times CHECK (isfinite(created_at))
);

COMMENT ON TABLE companies IS
    'Single registry of customers, bidders, and awarded suppliers.';
COMMENT ON COLUMN companies.tax_id IS
    'Textual tax or registration identifier; text preserves leading zeroes.';

CREATE TABLE tenders (
    id bigint GENERATED ALWAYS AS IDENTITY,
    source_system text NOT NULL DEFAULT 'zakupki.gov.ru',
    external_id text NOT NULL,
    procurement_number text NOT NULL,
    title text NOT NULL,
    customer_company_id bigint NOT NULL,
    status text NOT NULL,
    published_at timestamptz NOT NULL,
    submission_deadline_at timestamptz NOT NULL,
    completed_at timestamptz,
    source_updated_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_tenders PRIMARY KEY (id),
    CONSTRAINT fk_tenders_customer
        FOREIGN KEY (customer_company_id)
        REFERENCES companies (id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    CONSTRAINT uq_tenders_source_external
        UNIQUE (source_system, external_id),
    CONSTRAINT ck_tenders_source_not_blank
        CHECK (has_non_whitespace(source_system)),
    CONSTRAINT ck_tenders_source_canonical_edges
        CHECK (has_canonical_edges(source_system)),
    CONSTRAINT ck_tenders_external_id_not_blank
        CHECK (has_non_whitespace(external_id)),
    CONSTRAINT ck_tenders_external_id_canonical_edges
        CHECK (has_canonical_edges(external_id)),
    CONSTRAINT ck_tenders_procurement_number_not_blank
        CHECK (has_non_whitespace(procurement_number)),
    CONSTRAINT ck_tenders_procurement_number_canonical_edges
        CHECK (has_canonical_edges(procurement_number)),
    CONSTRAINT ck_tenders_title_not_blank
        CHECK (has_non_whitespace(title)),
    CONSTRAINT ck_tenders_title_canonical_edges
        CHECK (has_canonical_edges(title)),
    CONSTRAINT ck_tenders_status
        CHECK (status IN (
            'planned',
            'published',
            'bidding',
            'evaluation',
            'completed',
            'cancelled'
        )),
    CONSTRAINT ck_tenders_submission_window
        CHECK (submission_deadline_at >= published_at),
    CONSTRAINT ck_tenders_completion_time
        CHECK (completed_at IS NULL OR completed_at >= published_at),
    CONSTRAINT ck_tenders_completed_state
        CHECK (
            status <> 'completed'
            OR (
                completed_at IS NOT NULL
                AND completed_at >= submission_deadline_at
            )
        ),
    CONSTRAINT ck_tenders_finite_times
        CHECK (
            isfinite(published_at)
            AND isfinite(submission_deadline_at)
            AND (completed_at IS NULL OR isfinite(completed_at))
            AND (source_updated_at IS NULL OR isfinite(source_updated_at))
            AND isfinite(created_at)
        )
);

COMMENT ON TABLE tenders IS
    'Procurement notices. Each tender belongs to one customer company.';

CREATE TABLE lots (
    id bigint GENERATED ALWAYS AS IDENTITY,
    tender_id bigint NOT NULL,
    lot_number integer NOT NULL,
    title text NOT NULL,
    description text,
    initial_price numeric(20, 2) NOT NULL,
    currency_code character(3) NOT NULL DEFAULT 'RUB',
    status text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_lots PRIMARY KEY (id),
    CONSTRAINT fk_lots_tender
        FOREIGN KEY (tender_id)
        REFERENCES tenders (id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    CONSTRAINT uq_lots_tender_number UNIQUE (tender_id, lot_number),
    CONSTRAINT ck_lots_number CHECK (lot_number > 0),
    CONSTRAINT ck_lots_title_not_blank CHECK (has_non_whitespace(title)),
    CONSTRAINT ck_lots_title_canonical_edges CHECK (has_canonical_edges(title)),
    CONSTRAINT ck_lots_initial_price
        CHECK (initial_price <> 'NaN'::numeric AND initial_price >= 0),
    CONSTRAINT ck_lots_currency_code
        CHECK (currency_code ~ '^[A-Z]{3}$'),
    CONSTRAINT ck_lots_status
        CHECK (status IN ('open', 'evaluation', 'awarded', 'completed', 'cancelled')),
    CONSTRAINT ck_lots_finite_times CHECK (isfinite(created_at))
);

COMMENT ON TABLE lots IS
    'Tender lots. Bids and awards are recorded at lot granularity.';

CREATE TABLE bids (
    id bigint GENERATED ALWAYS AS IDENTITY,
    lot_id bigint NOT NULL,
    bidder_company_id bigint NOT NULL,
    version_no integer NOT NULL DEFAULT 1,
    source_bid_id text,
    amount numeric(20, 2) NOT NULL,
    submitted_at timestamptz NOT NULL,
    status text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_bids PRIMARY KEY (id),
    CONSTRAINT fk_bids_lot
        FOREIGN KEY (lot_id)
        REFERENCES lots (id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    CONSTRAINT fk_bids_bidder_company
        FOREIGN KEY (bidder_company_id)
        REFERENCES companies (id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    CONSTRAINT uq_bids_lot_bidder_version
        UNIQUE (lot_id, bidder_company_id, version_no),
    CONSTRAINT ck_bids_version CHECK (version_no > 0),
    CONSTRAINT ck_bids_source_id_not_blank
        CHECK (source_bid_id IS NULL OR has_non_whitespace(source_bid_id)),
    CONSTRAINT ck_bids_source_id_canonical_edges
        CHECK (source_bid_id IS NULL OR has_canonical_edges(source_bid_id)),
    CONSTRAINT ck_bids_amount
        CHECK (amount <> 'NaN'::numeric AND amount >= 0),
    CONSTRAINT ck_bids_status
        CHECK (status IN ('submitted', 'admitted', 'rejected', 'withdrawn', 'superseded')),
    CONSTRAINT ck_bids_finite_times
        CHECK (isfinite(submitted_at) AND isfinite(created_at))
);

COMMENT ON TABLE bids IS
    'Versioned company offers for a lot. Award status is not duplicated here.';

CREATE TABLE executors (
    id bigint GENERATED ALWAYS AS IDENTITY,
    lot_id bigint NOT NULL,
    company_id bigint NOT NULL,
    awarded_amount numeric(20, 2) NOT NULL,
    awarded_at timestamptz NOT NULL,
    status text NOT NULL,
    contract_number text,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_executors PRIMARY KEY (id),
    CONSTRAINT fk_executors_lot
        FOREIGN KEY (lot_id)
        REFERENCES lots (id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    CONSTRAINT fk_executors_company
        FOREIGN KEY (company_id)
        REFERENCES companies (id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    CONSTRAINT uq_executors_lot UNIQUE (lot_id),
    CONSTRAINT ck_executors_awarded_amount
        CHECK (awarded_amount <> 'NaN'::numeric AND awarded_amount >= 0),
    CONSTRAINT ck_executors_status
        CHECK (status IN (
            'awarded',
            'contract_signed',
            'performing',
            'completed',
            'terminated'
        )),
    CONSTRAINT ck_executors_contract_number_not_blank
        CHECK (contract_number IS NULL OR has_non_whitespace(contract_number)),
    CONSTRAINT ck_executors_contract_number_canonical_edges
        CHECK (contract_number IS NULL OR has_canonical_edges(contract_number)),
    CONSTRAINT ck_executors_finite_times
        CHECK (isfinite(awarded_at) AND isfinite(created_at))
);

COMMENT ON TABLE executors IS
    'Award facts: one awarded company and amount per lot in version 1.';

CREATE FUNCTION enforce_bid_submission_window()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, tender_platform
AS $function$
DECLARE
    current_submitted_at timestamptz;
    tender_published_at timestamptz;
    tender_deadline_at timestamptz;
BEGIN
    SELECT
        bid.submitted_at,
        tender.published_at,
        tender.submission_deadline_at
      INTO
        current_submitted_at,
        tender_published_at,
        tender_deadline_at
      FROM tender_platform.bids bid
      JOIN tender_platform.lots lot
        ON lot.id = bid.lot_id
      JOIN tender_platform.tenders tender
        ON tender.id = lot.tender_id
     WHERE bid.id = NEW.id
       FOR SHARE OF bid, lot, tender;

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    IF current_submitted_at < tender_published_at
       OR current_submitted_at > tender_deadline_at THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            CONSTRAINT = 'ct_bids_submission_window',
            MESSAGE = format(
                'bid %s timestamp must be within tender publication and submission deadline',
                NEW.id
            );
    END IF;

    RETURN NEW;
END
$function$;

CREATE FUNCTION enforce_executor_award_window()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, tender_platform
AS $function$
DECLARE
    current_awarded_at timestamptz;
    tender_deadline_at timestamptz;
BEGIN
    SELECT executor.awarded_at, tender.submission_deadline_at
      INTO current_awarded_at, tender_deadline_at
      FROM tender_platform.executors executor
      JOIN tender_platform.lots lot
        ON lot.id = executor.lot_id
     JOIN tender_platform.tenders tender
        ON tender.id = lot.tender_id
     WHERE executor.id = NEW.id
       FOR SHARE OF executor, lot, tender;

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    IF current_awarded_at < tender_deadline_at THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            CONSTRAINT = 'ct_executors_award_window',
            MESSAGE = format(
                'executor award %s cannot precede the tender submission deadline',
                NEW.id
            );
    END IF;

    RETURN NEW;
END
$function$;

CREATE FUNCTION revalidate_tender_related_timing()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, tender_platform
AS $function$
DECLARE
    current_published_at timestamptz;
    current_deadline_at timestamptz;
BEGIN
    SELECT tender.published_at, tender.submission_deadline_at
      INTO current_published_at, current_deadline_at
      FROM tender_platform.tenders tender
     WHERE tender.id = NEW.id
       FOR SHARE;

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM tender_platform.lots lot
          JOIN tender_platform.bids bid
            ON bid.lot_id = lot.id
         WHERE lot.tender_id = NEW.id
           AND (
               bid.submitted_at < current_published_at
               OR bid.submitted_at > current_deadline_at
           )
    ) OR EXISTS (
        SELECT 1
          FROM tender_platform.lots lot
          JOIN tender_platform.executors executor
            ON executor.lot_id = lot.id
         WHERE lot.tender_id = NEW.id
           AND executor.awarded_at < current_deadline_at
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            CONSTRAINT = 'ct_tenders_related_timing',
            MESSAGE = format(
                'tender %s date change invalidates related bid or award timestamps',
                NEW.id
            );
    END IF;

    RETURN NEW;
END
$function$;

CREATE FUNCTION revalidate_lot_related_timing()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, tender_platform
AS $function$
DECLARE
    tender_published_at timestamptz;
    tender_deadline_at timestamptz;
BEGIN
    SELECT tender.published_at, tender.submission_deadline_at
      INTO tender_published_at, tender_deadline_at
      FROM tender_platform.lots lot
      JOIN tender_platform.tenders tender
        ON tender.id = lot.tender_id
     WHERE lot.id = NEW.id
       FOR SHARE OF lot, tender;

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM tender_platform.bids bid
         WHERE bid.lot_id = NEW.id
           AND (
               bid.submitted_at < tender_published_at
               OR bid.submitted_at > tender_deadline_at
           )
    ) OR EXISTS (
        SELECT 1
          FROM tender_platform.executors executor
         WHERE executor.lot_id = NEW.id
           AND executor.awarded_at < tender_deadline_at
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            CONSTRAINT = 'ct_lots_related_timing',
            MESSAGE = format(
                'lot %s tender reassignment invalidates related bid or award timestamps',
                NEW.id
            );
    END IF;

    RETURN NEW;
END
$function$;

CREATE CONSTRAINT TRIGGER ct_bids_submission_window
AFTER INSERT OR UPDATE OF id, lot_id, submitted_at ON bids
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW
EXECUTE FUNCTION enforce_bid_submission_window();

CREATE CONSTRAINT TRIGGER ct_executors_award_window
AFTER INSERT OR UPDATE OF id, lot_id, awarded_at ON executors
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW
EXECUTE FUNCTION enforce_executor_award_window();

CREATE CONSTRAINT TRIGGER ct_tenders_related_timing
AFTER UPDATE OF published_at, submission_deadline_at ON tenders
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW
EXECUTE FUNCTION revalidate_tender_related_timing();

CREATE CONSTRAINT TRIGGER ct_lots_related_timing
AFTER UPDATE OF tender_id ON lots
DEFERRABLE INITIALLY IMMEDIATE
FOR EACH ROW
EXECUTE FUNCTION revalidate_lot_related_timing();

COMMENT ON TRIGGER ct_bids_submission_window ON bids IS
    'Keeps bid timestamps inside the publication/submission window.';
COMMENT ON TRIGGER ct_executors_award_window ON executors IS
    'Prevents award timestamps before the submission deadline.';
COMMENT ON TRIGGER ct_tenders_related_timing ON tenders IS
    'Revalidates related bids and awards after tender date changes.';
COMMENT ON TRIGGER ct_lots_related_timing ON lots IS
    'Revalidates related bids and awards after moving a lot to another tender.';

CREATE INDEX idx_tenders_customer_company
    ON tenders (customer_company_id);

CREATE INDEX idx_tenders_status_submission_deadline
    ON tenders (status, submission_deadline_at);

CREATE INDEX idx_bids_lot_status_bidder
    ON bids (lot_id, status, bidder_company_id);

CREATE INDEX idx_bids_admitted_lot_bidder
    ON bids (lot_id, bidder_company_id)
    INCLUDE (version_no)
    WHERE status = 'admitted';

CREATE INDEX idx_bids_bidder_company
    ON bids (bidder_company_id, submitted_at DESC);

CREATE INDEX idx_executors_company
    ON executors (company_id);

CREATE INDEX idx_executors_active_awarded_at_company
    ON executors (awarded_at, company_id)
    INCLUDE (awarded_amount, lot_id)
    WHERE status IN ('awarded', 'contract_signed', 'performing', 'completed');
