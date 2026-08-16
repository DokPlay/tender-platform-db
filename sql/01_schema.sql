\set ON_ERROR_STOP on

BEGIN;

CREATE SCHEMA tender_platform;
COMMENT ON SCHEMA tender_platform IS
    'Normalized data model for monitoring government procurement tenders.';

SET LOCAL search_path TO tender_platform, public;

CREATE TABLE companies (
    id bigint GENERATED ALWAYS AS IDENTITY,
    name text NOT NULL,
    tax_id text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_companies PRIMARY KEY (id),
    CONSTRAINT uq_companies_tax_id UNIQUE (tax_id),
    CONSTRAINT ck_companies_name_not_blank CHECK (btrim(name) <> ''),
    CONSTRAINT ck_companies_tax_id_not_blank CHECK (btrim(tax_id) <> '')
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
        CHECK (btrim(source_system) <> ''),
    CONSTRAINT ck_tenders_external_id_not_blank
        CHECK (btrim(external_id) <> ''),
    CONSTRAINT ck_tenders_procurement_number_not_blank
        CHECK (btrim(procurement_number) <> ''),
    CONSTRAINT ck_tenders_title_not_blank
        CHECK (btrim(title) <> ''),
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
        CHECK (completed_at IS NULL OR completed_at >= published_at)
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
    CONSTRAINT ck_lots_title_not_blank CHECK (btrim(title) <> ''),
    CONSTRAINT ck_lots_initial_price CHECK (initial_price >= 0),
    CONSTRAINT ck_lots_currency_code
        CHECK (currency_code ~ '^[A-Z]{3}$'),
    CONSTRAINT ck_lots_status
        CHECK (status IN ('open', 'evaluation', 'awarded', 'completed', 'cancelled'))
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
        CHECK (source_bid_id IS NULL OR btrim(source_bid_id) <> ''),
    CONSTRAINT ck_bids_amount CHECK (amount >= 0),
    CONSTRAINT ck_bids_status
        CHECK (status IN ('submitted', 'admitted', 'rejected', 'withdrawn', 'superseded'))
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
    CONSTRAINT ck_executors_awarded_amount CHECK (awarded_amount >= 0),
    CONSTRAINT ck_executors_status
        CHECK (status IN (
            'awarded',
            'contract_signed',
            'performing',
            'completed',
            'terminated'
        )),
    CONSTRAINT ck_executors_contract_number_not_blank
        CHECK (contract_number IS NULL OR btrim(contract_number) <> '')
);

COMMENT ON TABLE executors IS
    'Award facts: one awarded company and amount per lot in version 1.';

CREATE INDEX idx_tenders_customer_company
    ON tenders (customer_company_id);

CREATE INDEX idx_tenders_status_submission_deadline
    ON tenders (status, submission_deadline_at);

CREATE INDEX idx_bids_lot_status_bidder
    ON bids (lot_id, status, bidder_company_id);

CREATE INDEX idx_bids_bidder_company
    ON bids (bidder_company_id, submitted_at DESC);

CREATE INDEX idx_executors_company
    ON executors (company_id);

CREATE INDEX idx_executors_active_awarded_at_company
    ON executors (awarded_at, company_id)
    INCLUDE (awarded_amount, lot_id)
    WHERE status IN ('awarded', 'contract_signed', 'performing', 'completed');

COMMIT;
