\set ON_ERROR_STOP on

DO $test$
DECLARE
    missing_tables text[];
    invalid_columns text[];
    invalid_defaults text[];
    invalid_primary_keys text[];
    invalid_constraints text[];
    invalid_indexes text[];
    invalid_foreign_keys text[];
    invalid_triggers text[];
    unindexed_foreign_keys text[];
    foreign_key_count integer;
BEGIN
    SELECT array_agg(required.table_name ORDER BY required.table_name)
      INTO missing_tables
      FROM (
          VALUES
              ('companies'),
              ('tenders'),
              ('lots'),
              ('bids'),
              ('executors')
      ) AS required(table_name)
      LEFT JOIN information_schema.tables actual
        ON actual.table_schema = 'tender_platform'
       AND actual.table_name = required.table_name
       AND actual.table_type = 'BASE TABLE'
     WHERE actual.table_name IS NULL;

    IF missing_tables IS NOT NULL THEN
        RAISE EXCEPTION
            'Missing required tables: %',
            array_to_string(missing_tables, ', ');
    END IF;

    WITH required_columns AS (
        SELECT *
          FROM (
              VALUES
                  ('companies', 'id', 'bigint', true, 'a'),
                  ('companies', 'name', 'text', true, NULL),
                  ('companies', 'tax_id', 'text', true, NULL),
                  ('companies', 'created_at', 'timestamp with time zone', true, NULL),

                  ('tenders', 'id', 'bigint', true, 'a'),
                  ('tenders', 'source_system', 'text', true, NULL),
                  ('tenders', 'external_id', 'text', true, NULL),
                  ('tenders', 'procurement_number', 'text', true, NULL),
                  ('tenders', 'title', 'text', true, NULL),
                  ('tenders', 'customer_company_id', 'bigint', true, NULL),
                  ('tenders', 'status', 'text', true, NULL),
                  ('tenders', 'published_at', 'timestamp with time zone', true, NULL),
                  ('tenders', 'submission_deadline_at', 'timestamp with time zone', true, NULL),
                  ('tenders', 'completed_at', 'timestamp with time zone', false, NULL),
                  ('tenders', 'source_updated_at', 'timestamp with time zone', false, NULL),
                  ('tenders', 'created_at', 'timestamp with time zone', true, NULL),

                  ('lots', 'id', 'bigint', true, 'a'),
                  ('lots', 'tender_id', 'bigint', true, NULL),
                  ('lots', 'lot_number', 'integer', true, NULL),
                  ('lots', 'title', 'text', true, NULL),
                  ('lots', 'description', 'text', false, NULL),
                  ('lots', 'initial_price', 'numeric(20,2)', true, NULL),
                  ('lots', 'currency_code', 'character(3)', true, NULL),
                  ('lots', 'status', 'text', true, NULL),
                  ('lots', 'created_at', 'timestamp with time zone', true, NULL),

                  ('bids', 'id', 'bigint', true, 'a'),
                  ('bids', 'lot_id', 'bigint', true, NULL),
                  ('bids', 'bidder_company_id', 'bigint', true, NULL),
                  ('bids', 'version_no', 'integer', true, NULL),
                  ('bids', 'source_bid_id', 'text', false, NULL),
                  ('bids', 'amount', 'numeric(20,2)', true, NULL),
                  ('bids', 'submitted_at', 'timestamp with time zone', true, NULL),
                  ('bids', 'status', 'text', true, NULL),
                  ('bids', 'created_at', 'timestamp with time zone', true, NULL),

                  ('executors', 'id', 'bigint', true, 'a'),
                  ('executors', 'lot_id', 'bigint', true, NULL),
                  ('executors', 'company_id', 'bigint', true, NULL),
                  ('executors', 'awarded_amount', 'numeric(20,2)', true, NULL),
                  ('executors', 'awarded_at', 'timestamp with time zone', true, NULL),
                  ('executors', 'status', 'text', true, NULL),
                  ('executors', 'contract_number', 'text', false, NULL),
                  ('executors', 'created_at', 'timestamp with time zone', true, NULL)
          ) AS expected(
              table_name,
              column_name,
              data_type,
              not_null,
              identity_generation
          )
    ),
    actual_columns AS (
        SELECT
            table_info.relname AS table_name,
            attribute_info.attname AS column_name,
            format_type(
                attribute_info.atttypid,
                attribute_info.atttypmod
            ) AS data_type,
            attribute_info.attnotnull AS not_null,
            NULLIF(attribute_info.attidentity, '')::text AS identity_generation
        FROM pg_attribute attribute_info
        JOIN pg_class table_info
          ON table_info.oid = attribute_info.attrelid
        JOIN pg_namespace schema_info
          ON schema_info.oid = table_info.relnamespace
        WHERE schema_info.nspname = 'tender_platform'
          AND table_info.relkind = 'r'
          AND attribute_info.attnum > 0
          AND NOT attribute_info.attisdropped
    )
    SELECT array_agg(
               expected.table_name || '.' || expected.column_name
               ORDER BY expected.table_name, expected.column_name
           )
      INTO invalid_columns
      FROM required_columns expected
      LEFT JOIN actual_columns actual
        ON actual.table_name = expected.table_name
       AND actual.column_name = expected.column_name
       AND actual.data_type = expected.data_type
       AND actual.not_null = expected.not_null
       AND actual.identity_generation
           IS NOT DISTINCT FROM expected.identity_generation
     WHERE actual.column_name IS NULL;

    IF invalid_columns IS NOT NULL THEN
        RAISE EXCEPTION
            'Missing or incorrectly defined columns: %',
            array_to_string(invalid_columns, ', ');
    END IF;

    WITH required_defaults AS (
        SELECT *
          FROM (
              VALUES
                  ('companies', 'created_at', 'CURRENT_TIMESTAMP'),
                  ('tenders', 'source_system', $default$'zakupki.gov.ru'::text$default$),
                  ('tenders', 'created_at', 'CURRENT_TIMESTAMP'),
                  ('lots', 'currency_code', $default$'RUB'::bpchar$default$),
                  ('lots', 'created_at', 'CURRENT_TIMESTAMP'),
                  ('bids', 'version_no', '1'),
                  ('bids', 'created_at', 'CURRENT_TIMESTAMP'),
                  ('executors', 'created_at', 'CURRENT_TIMESTAMP')
          ) AS expected(table_name, column_name, default_expression)
    ),
    actual_defaults AS (
        SELECT
            table_info.relname::text AS table_name,
            attribute_info.attname::text AS column_name,
            pg_get_expr(
                default_info.adbin,
                default_info.adrelid
            ) AS default_expression
        FROM pg_attrdef default_info
        JOIN pg_class table_info
          ON table_info.oid = default_info.adrelid
        JOIN pg_namespace schema_info
          ON schema_info.oid = table_info.relnamespace
        JOIN pg_attribute attribute_info
          ON attribute_info.attrelid = default_info.adrelid
         AND attribute_info.attnum = default_info.adnum
        WHERE schema_info.nspname = 'tender_platform'
          AND table_info.relkind = 'r'
    ),
    default_differences AS (
        SELECT
            expected.table_name || '.' || expected.column_name AS item
        FROM required_defaults expected
        LEFT JOIN actual_defaults actual
          ON actual.table_name = expected.table_name
         AND actual.column_name = expected.column_name
         AND actual.default_expression = expected.default_expression
        WHERE actual.column_name IS NULL

        UNION ALL

        SELECT
            actual.table_name || '.' || actual.column_name AS item
        FROM actual_defaults actual
        LEFT JOIN required_defaults expected
          ON expected.table_name = actual.table_name
         AND expected.column_name = actual.column_name
         AND expected.default_expression = actual.default_expression
        WHERE expected.column_name IS NULL
    )
    SELECT array_agg(item ORDER BY item)
      INTO invalid_defaults
      FROM default_differences;

    IF invalid_defaults IS NOT NULL THEN
        RAISE EXCEPTION
            'Missing, unexpected, or incorrectly defined defaults: %',
            array_to_string(invalid_defaults, ', ');
    END IF;

    WITH required_primary_keys AS (
        SELECT *
          FROM (
              VALUES
                  ('pk_companies', 'companies', ARRAY['id']::text[]),
                  ('pk_tenders', 'tenders', ARRAY['id']::text[]),
                  ('pk_lots', 'lots', ARRAY['id']::text[]),
                  ('pk_bids', 'bids', ARRAY['id']::text[]),
                  ('pk_executors', 'executors', ARRAY['id']::text[])
          ) AS expected(constraint_name, table_name, key_columns)
    ),
    actual_primary_keys AS (
        SELECT
            constraint_info.conname::text AS constraint_name,
            table_info.relname::text AS table_name,
            ARRAY(
                SELECT attribute_info.attname::text
                  FROM unnest(constraint_info.conkey)
                       WITH ORDINALITY AS key_info(attnum, position)
                  JOIN pg_attribute attribute_info
                    ON attribute_info.attrelid = constraint_info.conrelid
                   AND attribute_info.attnum = key_info.attnum
                 ORDER BY key_info.position
            ) AS key_columns,
            constraint_info.convalidated,
            constraint_info.condeferrable,
            constraint_info.condeferred
        FROM pg_constraint constraint_info
        JOIN pg_class table_info
          ON table_info.oid = constraint_info.conrelid
        JOIN pg_namespace schema_info
          ON schema_info.oid = table_info.relnamespace
        WHERE schema_info.nspname = 'tender_platform'
          AND constraint_info.contype = 'p'
    )
    SELECT array_agg(expected.constraint_name ORDER BY expected.constraint_name)
      INTO invalid_primary_keys
      FROM required_primary_keys expected
      LEFT JOIN actual_primary_keys actual
        ON actual.constraint_name = expected.constraint_name
       AND actual.table_name = expected.table_name
       AND actual.key_columns = expected.key_columns
       AND actual.convalidated
       AND NOT actual.condeferrable
       AND NOT actual.condeferred
     WHERE actual.constraint_name IS NULL;

    IF invalid_primary_keys IS NOT NULL THEN
        RAISE EXCEPTION
            'Missing or incorrectly defined primary keys: %',
            array_to_string(invalid_primary_keys, ', ');
    END IF;

    WITH required_constraints AS (
        SELECT *
          FROM (
              VALUES
                  ('uq_companies_tax_id', 'companies', 'u', $definition$UNIQUE (tax_id)$definition$),
                  ('ck_companies_name_not_blank', 'companies', 'c', $definition$CHECK (tender_platform.has_non_whitespace(name))$definition$),
                  ('ck_companies_name_canonical_edges', 'companies', 'c', $definition$CHECK (tender_platform.has_canonical_edges(name))$definition$),
                  ('ck_companies_tax_id_not_blank', 'companies', 'c', $definition$CHECK (tender_platform.has_non_whitespace(tax_id))$definition$),
                  ('ck_companies_tax_id_canonical_edges', 'companies', 'c', $definition$CHECK (tender_platform.has_canonical_edges(tax_id))$definition$),
                  ('ck_companies_finite_times', 'companies', 'c', $definition$CHECK (isfinite(created_at))$definition$),

                  ('uq_tenders_source_external', 'tenders', 'u', $definition$UNIQUE (source_system, external_id)$definition$),
                  ('ck_tenders_source_not_blank', 'tenders', 'c', $definition$CHECK (tender_platform.has_non_whitespace(source_system))$definition$),
                  ('ck_tenders_source_canonical_edges', 'tenders', 'c', $definition$CHECK (tender_platform.has_canonical_edges(source_system))$definition$),
                  ('ck_tenders_external_id_not_blank', 'tenders', 'c', $definition$CHECK (tender_platform.has_non_whitespace(external_id))$definition$),
                  ('ck_tenders_external_id_canonical_edges', 'tenders', 'c', $definition$CHECK (tender_platform.has_canonical_edges(external_id))$definition$),
                  ('ck_tenders_procurement_number_not_blank', 'tenders', 'c', $definition$CHECK (tender_platform.has_non_whitespace(procurement_number))$definition$),
                  ('ck_tenders_procurement_number_canonical_edges', 'tenders', 'c', $definition$CHECK (tender_platform.has_canonical_edges(procurement_number))$definition$),
                  ('ck_tenders_title_not_blank', 'tenders', 'c', $definition$CHECK (tender_platform.has_non_whitespace(title))$definition$),
                  ('ck_tenders_title_canonical_edges', 'tenders', 'c', $definition$CHECK (tender_platform.has_canonical_edges(title))$definition$),
                  ('ck_tenders_status', 'tenders', 'c', $definition$CHECK (status = ANY (ARRAY['planned'::text, 'published'::text, 'bidding'::text, 'evaluation'::text, 'completed'::text, 'cancelled'::text]))$definition$),
                  ('ck_tenders_submission_window', 'tenders', 'c', $definition$CHECK (submission_deadline_at >= published_at)$definition$),
                  ('ck_tenders_completion_time', 'tenders', 'c', $definition$CHECK (completed_at IS NULL OR completed_at >= published_at)$definition$),
                  ('ck_tenders_completed_state', 'tenders', 'c', $definition$CHECK (status <> 'completed'::text OR completed_at IS NOT NULL AND completed_at >= submission_deadline_at)$definition$),
                  ('ck_tenders_finite_times', 'tenders', 'c', $definition$CHECK (isfinite(published_at) AND isfinite(submission_deadline_at) AND (completed_at IS NULL OR isfinite(completed_at)) AND (source_updated_at IS NULL OR isfinite(source_updated_at)) AND isfinite(created_at))$definition$),

                  ('uq_lots_tender_number', 'lots', 'u', $definition$UNIQUE (tender_id, lot_number)$definition$),
                  ('ck_lots_number', 'lots', 'c', $definition$CHECK (lot_number > 0)$definition$),
                  ('ck_lots_title_not_blank', 'lots', 'c', $definition$CHECK (tender_platform.has_non_whitespace(title))$definition$),
                  ('ck_lots_title_canonical_edges', 'lots', 'c', $definition$CHECK (tender_platform.has_canonical_edges(title))$definition$),
                  ('ck_lots_initial_price', 'lots', 'c', $definition$CHECK (initial_price <> 'NaN'::numeric AND initial_price >= 0::numeric)$definition$),
                  ('ck_lots_currency_code', 'lots', 'c', $definition$CHECK (currency_code ~ '^[A-Z]{3}$'::text)$definition$),
                  ('ck_lots_status', 'lots', 'c', $definition$CHECK (status = ANY (ARRAY['open'::text, 'evaluation'::text, 'awarded'::text, 'completed'::text, 'cancelled'::text]))$definition$),
                  ('ck_lots_finite_times', 'lots', 'c', $definition$CHECK (isfinite(created_at))$definition$),

                  ('uq_bids_lot_bidder_version', 'bids', 'u', $definition$UNIQUE (lot_id, bidder_company_id, version_no)$definition$),
                  ('ck_bids_version', 'bids', 'c', $definition$CHECK (version_no > 0)$definition$),
                  ('ck_bids_source_id_not_blank', 'bids', 'c', $definition$CHECK (source_bid_id IS NULL OR tender_platform.has_non_whitespace(source_bid_id))$definition$),
                  ('ck_bids_source_id_canonical_edges', 'bids', 'c', $definition$CHECK (source_bid_id IS NULL OR tender_platform.has_canonical_edges(source_bid_id))$definition$),
                  ('ck_bids_amount', 'bids', 'c', $definition$CHECK (amount <> 'NaN'::numeric AND amount >= 0::numeric)$definition$),
                  ('ck_bids_status', 'bids', 'c', $definition$CHECK (status = ANY (ARRAY['submitted'::text, 'admitted'::text, 'rejected'::text, 'withdrawn'::text, 'superseded'::text]))$definition$),
                  ('ck_bids_finite_times', 'bids', 'c', $definition$CHECK (isfinite(submitted_at) AND isfinite(created_at))$definition$),

                  ('uq_executors_lot', 'executors', 'u', $definition$UNIQUE (lot_id)$definition$),
                  ('ck_executors_awarded_amount', 'executors', 'c', $definition$CHECK (awarded_amount <> 'NaN'::numeric AND awarded_amount >= 0::numeric)$definition$),
                  ('ck_executors_status', 'executors', 'c', $definition$CHECK (status = ANY (ARRAY['awarded'::text, 'contract_signed'::text, 'performing'::text, 'completed'::text, 'terminated'::text]))$definition$),
                  ('ck_executors_contract_number_not_blank', 'executors', 'c', $definition$CHECK (contract_number IS NULL OR tender_platform.has_non_whitespace(contract_number))$definition$),
                  ('ck_executors_contract_number_canonical_edges', 'executors', 'c', $definition$CHECK (contract_number IS NULL OR tender_platform.has_canonical_edges(contract_number))$definition$),
                  ('ck_executors_finite_times', 'executors', 'c', $definition$CHECK (isfinite(awarded_at) AND isfinite(created_at))$definition$)
          ) AS expected(
              constraint_name,
              table_name,
              constraint_type,
              definition
          )
    ),
    actual_constraints AS (
        SELECT
            constraint_info.conname::text AS constraint_name,
            table_info.relname::text AS table_name,
            constraint_info.contype::text AS constraint_type,
            pg_get_constraintdef(constraint_info.oid, true) AS definition,
            constraint_info.convalidated,
            constraint_info.condeferrable,
            constraint_info.condeferred
        FROM pg_constraint constraint_info
        JOIN pg_class table_info
          ON table_info.oid = constraint_info.conrelid
        JOIN pg_namespace schema_info
          ON schema_info.oid = table_info.relnamespace
        WHERE schema_info.nspname = 'tender_platform'
          AND constraint_info.contype IN ('u', 'c')
    ),
    constraint_differences AS (
        SELECT expected.constraint_name AS item
          FROM required_constraints expected
          LEFT JOIN actual_constraints actual
            ON actual.constraint_name = expected.constraint_name
           AND actual.table_name = expected.table_name
           AND actual.constraint_type = expected.constraint_type
           AND actual.definition = expected.definition
           AND actual.convalidated
           AND NOT actual.condeferrable
           AND NOT actual.condeferred
         WHERE actual.constraint_name IS NULL

        UNION ALL

        SELECT actual.constraint_name AS item
          FROM actual_constraints actual
          LEFT JOIN required_constraints expected
            ON expected.constraint_name = actual.constraint_name
           AND expected.table_name = actual.table_name
           AND expected.constraint_type = actual.constraint_type
           AND expected.definition = actual.definition
           AND actual.convalidated
           AND NOT actual.condeferrable
           AND NOT actual.condeferred
         WHERE expected.constraint_name IS NULL
    )
    SELECT array_agg(item ORDER BY item)
      INTO invalid_constraints
      FROM constraint_differences;

    IF invalid_constraints IS NOT NULL THEN
        RAISE EXCEPTION
            'Missing or incorrectly defined business constraints: %',
            array_to_string(invalid_constraints, ', ');
    END IF;

    WITH required_indexes AS (
        SELECT *
          FROM (
              VALUES
                  (
                      'idx_tenders_customer_company',
                      $index$CREATE INDEX idx_tenders_customer_company ON tender_platform.tenders USING btree (customer_company_id)$index$
                  ),
                  (
                      'idx_tenders_status_submission_deadline',
                      $index$CREATE INDEX idx_tenders_status_submission_deadline ON tender_platform.tenders USING btree (status, submission_deadline_at)$index$
                  ),
                  (
                      'idx_bids_lot_status_bidder',
                      $index$CREATE INDEX idx_bids_lot_status_bidder ON tender_platform.bids USING btree (lot_id, status, bidder_company_id)$index$
                  ),
                  (
                      'idx_bids_admitted_lot_bidder',
                      $index$CREATE INDEX idx_bids_admitted_lot_bidder ON tender_platform.bids USING btree (lot_id, bidder_company_id) INCLUDE (version_no) WHERE (status = 'admitted'::text)$index$
                  ),
                  (
                      'idx_bids_bidder_company',
                      $index$CREATE INDEX idx_bids_bidder_company ON tender_platform.bids USING btree (bidder_company_id, submitted_at DESC)$index$
                  ),
                  (
                      'idx_executors_company',
                      $index$CREATE INDEX idx_executors_company ON tender_platform.executors USING btree (company_id)$index$
                  ),
                  (
                      'idx_executors_active_awarded_at_company',
                      $index$CREATE INDEX idx_executors_active_awarded_at_company ON tender_platform.executors USING btree (awarded_at, company_id) INCLUDE (awarded_amount, lot_id) WHERE (status = ANY (ARRAY['awarded'::text, 'contract_signed'::text, 'performing'::text, 'completed'::text]))$index$
                  )
          ) AS expected(index_name, definition)
    ),
    actual_indexes AS (
        SELECT
            index_class.relname::text AS index_name,
            pg_get_indexdef(index_info.indexrelid) AS definition,
            index_info.indisvalid,
            index_info.indisready
        FROM pg_index index_info
        JOIN pg_class index_class
          ON index_class.oid = index_info.indexrelid
        JOIN pg_namespace index_schema
          ON index_schema.oid = index_class.relnamespace
        WHERE index_schema.nspname = 'tender_platform'
    )
    SELECT array_agg(expected.index_name ORDER BY expected.index_name)
      INTO invalid_indexes
      FROM required_indexes expected
      LEFT JOIN actual_indexes actual
        ON actual.index_name = expected.index_name
       AND actual.definition = expected.definition
       AND actual.indisvalid
       AND actual.indisready
     WHERE actual.index_name IS NULL;

    IF invalid_indexes IS NOT NULL THEN
        RAISE EXCEPTION
            'Missing or incorrectly defined workload indexes: %',
            array_to_string(invalid_indexes, ', ');
    END IF;

    SELECT count(*)
      INTO foreign_key_count
      FROM pg_constraint constraint_info
      JOIN pg_class table_info
        ON table_info.oid = constraint_info.conrelid
     JOIN pg_namespace schema_info
        ON schema_info.oid = table_info.relnamespace
     WHERE schema_info.nspname = 'tender_platform'
       AND constraint_info.contype = 'f';

    IF foreign_key_count <> 6 THEN
        RAISE EXCEPTION 'Expected 6 foreign keys, found %', foreign_key_count;
    END IF;

    WITH required_foreign_keys AS (
        SELECT *
          FROM (
              VALUES
                  (
                      'fk_tenders_customer',
                      'tenders',
                      ARRAY['customer_company_id']::text[],
                      'companies',
                      ARRAY['id']::text[]
                  ),
                  (
                      'fk_lots_tender',
                      'lots',
                      ARRAY['tender_id']::text[],
                      'tenders',
                      ARRAY['id']::text[]
                  ),
                  (
                      'fk_bids_lot',
                      'bids',
                      ARRAY['lot_id']::text[],
                      'lots',
                      ARRAY['id']::text[]
                  ),
                  (
                      'fk_bids_bidder_company',
                      'bids',
                      ARRAY['bidder_company_id']::text[],
                      'companies',
                      ARRAY['id']::text[]
                  ),
                  (
                      'fk_executors_lot',
                      'executors',
                      ARRAY['lot_id']::text[],
                      'lots',
                      ARRAY['id']::text[]
                  ),
                  (
                      'fk_executors_company',
                      'executors',
                      ARRAY['company_id']::text[],
                      'companies',
                      ARRAY['id']::text[]
                  )
          ) AS expected(
              constraint_name,
              source_table,
              source_columns,
              target_table,
              target_columns
          )
    ),
    actual_foreign_keys AS (
        SELECT
            constraint_info.conname::text AS constraint_name,
            source_table.relname::text AS source_table,
            source_schema.nspname::text AS source_schema,
            ARRAY(
                SELECT attribute_info.attname::text
                  FROM unnest(constraint_info.conkey)
                       WITH ORDINALITY AS key_info(attnum, position)
                  JOIN pg_attribute attribute_info
                    ON attribute_info.attrelid = constraint_info.conrelid
                   AND attribute_info.attnum = key_info.attnum
                 ORDER BY key_info.position
            ) AS source_columns,
            target_table.relname::text AS target_table,
            target_schema.nspname::text AS target_schema,
            ARRAY(
                SELECT attribute_info.attname::text
                  FROM unnest(constraint_info.confkey)
                       WITH ORDINALITY AS key_info(attnum, position)
                  JOIN pg_attribute attribute_info
                    ON attribute_info.attrelid = constraint_info.confrelid
                   AND attribute_info.attnum = key_info.attnum
                 ORDER BY key_info.position
            ) AS target_columns,
            constraint_info.confupdtype,
            constraint_info.confdeltype,
            constraint_info.confmatchtype,
            constraint_info.convalidated,
            constraint_info.condeferrable,
            constraint_info.condeferred
        FROM pg_constraint constraint_info
        JOIN pg_class source_table
          ON source_table.oid = constraint_info.conrelid
        JOIN pg_namespace source_schema
          ON source_schema.oid = source_table.relnamespace
        JOIN pg_class target_table
          ON target_table.oid = constraint_info.confrelid
        JOIN pg_namespace target_schema
          ON target_schema.oid = target_table.relnamespace
        WHERE source_schema.nspname = 'tender_platform'
          AND constraint_info.contype = 'f'
    )
    SELECT array_agg(expected.constraint_name ORDER BY expected.constraint_name)
      INTO invalid_foreign_keys
      FROM required_foreign_keys expected
      LEFT JOIN actual_foreign_keys actual
        ON actual.constraint_name = expected.constraint_name
       AND actual.source_schema = 'tender_platform'
       AND actual.source_table = expected.source_table
       AND actual.source_columns = expected.source_columns
       AND actual.target_schema = 'tender_platform'
       AND actual.target_table = expected.target_table
       AND actual.target_columns = expected.target_columns
       AND actual.confupdtype = 'r'
       AND actual.confdeltype = 'r'
       AND actual.confmatchtype = 's'
       AND actual.convalidated
       AND NOT actual.condeferrable
       AND NOT actual.condeferred
     WHERE actual.constraint_name IS NULL;

    IF invalid_foreign_keys IS NOT NULL THEN
        RAISE EXCEPTION
            'Missing or incorrectly defined foreign keys: %',
            array_to_string(invalid_foreign_keys, ', ');
    END IF;

    WITH required_triggers AS (
        SELECT *
          FROM (
              VALUES
                  (
                      'ct_bids_submission_window',
                      'bids',
                      'enforce_bid_submission_window',
                      21::smallint,
                      '1 2 7'
                  ),
                  (
                      'ct_executors_award_window',
                      'executors',
                      'enforce_executor_award_window',
                      21::smallint,
                      '1 2 5'
                  ),
                  (
                      'ct_lots_related_timing',
                      'lots',
                      'revalidate_lot_related_timing',
                      17::smallint,
                      '2'
                  ),
                  (
                      'ct_tenders_related_timing',
                      'tenders',
                      'revalidate_tender_related_timing',
                      17::smallint,
                      '8 9'
                  )
          ) AS expected(
              trigger_name,
              table_name,
              function_name,
              trigger_type,
              update_columns
          )
    ),
    actual_triggers AS (
        SELECT
            trigger_info.tgname::text AS trigger_name,
            table_info.relname::text AS table_name,
            function_info.proname::text AS function_name,
            function_schema.nspname::text AS function_schema,
            trigger_info.tgtype AS trigger_type,
            trigger_info.tgattr::text AS update_columns,
            trigger_info.tgdeferrable,
            trigger_info.tginitdeferred,
            trigger_info.tgenabled
        FROM pg_trigger trigger_info
        JOIN pg_class table_info
          ON table_info.oid = trigger_info.tgrelid
        JOIN pg_namespace table_schema
          ON table_schema.oid = table_info.relnamespace
        JOIN pg_proc function_info
          ON function_info.oid = trigger_info.tgfoid
        JOIN pg_namespace function_schema
          ON function_schema.oid = function_info.pronamespace
        WHERE table_schema.nspname = 'tender_platform'
          AND NOT trigger_info.tgisinternal
    ),
    trigger_differences AS (
        SELECT expected.trigger_name AS item
          FROM required_triggers expected
          LEFT JOIN actual_triggers actual
            ON actual.trigger_name = expected.trigger_name
           AND actual.table_name = expected.table_name
           AND actual.function_name = expected.function_name
           AND actual.function_schema = 'tender_platform'
           AND actual.trigger_type = expected.trigger_type
           AND actual.update_columns = expected.update_columns
           AND actual.tgdeferrable
           AND NOT actual.tginitdeferred
           AND actual.tgenabled = 'O'
         WHERE actual.trigger_name IS NULL

        UNION ALL

        SELECT actual.trigger_name AS item
          FROM actual_triggers actual
          LEFT JOIN required_triggers expected
            ON expected.trigger_name = actual.trigger_name
           AND expected.table_name = actual.table_name
           AND expected.function_name = actual.function_name
           AND actual.function_schema = 'tender_platform'
           AND expected.trigger_type = actual.trigger_type
           AND expected.update_columns = actual.update_columns
           AND actual.tgdeferrable
           AND NOT actual.tginitdeferred
           AND actual.tgenabled = 'O'
         WHERE expected.trigger_name IS NULL
    )
    SELECT array_agg(item ORDER BY item)
      INTO invalid_triggers
      FROM trigger_differences;

    IF invalid_triggers IS NOT NULL THEN
        RAISE EXCEPTION
            'Missing, unexpected, or incorrectly defined lifecycle triggers: %',
            array_to_string(invalid_triggers, ', ');
    END IF;

    IF position(
        'ORDER BY company_totals.total_awarded_amount DESC, company_totals.company_id'
        IN pg_get_viewdef(
            'tender_platform.v_top_companies_previous_month'::regclass,
            true
        )
    ) = 0 THEN
        RAISE EXCEPTION
            'Top-company view must use company_id as deterministic tie-breaker';
    END IF;

    IF position(
        'ORDER BY customer_totals.savings_percent_exact DESC NULLS LAST, customer_totals.customer_company_id'
        IN pg_get_viewdef(
            'tender_platform.v_customer_efficiency_last_six_months'::regclass,
            true
        )
    ) = 0 THEN
        RAISE EXCEPTION
            'Customer-efficiency view must rank exact values with NULLS LAST and customer ID tie-breaker';
    END IF;

    SELECT array_agg(constraint_info.conname ORDER BY constraint_info.conname)
      INTO unindexed_foreign_keys
      FROM pg_constraint constraint_info
      JOIN pg_class table_info
        ON table_info.oid = constraint_info.conrelid
      JOIN pg_namespace schema_info
        ON schema_info.oid = table_info.relnamespace
     WHERE schema_info.nspname = 'tender_platform'
       AND constraint_info.contype = 'f'
       AND NOT EXISTS (
           SELECT 1
             FROM pg_index index_info
             JOIN pg_class index_class
               ON index_class.oid = index_info.indexrelid
             JOIN pg_am access_method
               ON access_method.oid = index_class.relam
            WHERE index_info.indrelid = constraint_info.conrelid
              AND access_method.amname = 'btree'
              AND index_info.indisvalid
              AND index_info.indisready
              AND index_info.indpred IS NULL
              AND index_info.indnkeyatts >= cardinality(constraint_info.conkey)
              AND NOT EXISTS (
                  SELECT 1
                    FROM generate_series(
                        1,
                        cardinality(constraint_info.conkey)
                    ) AS key_position(position)
                   WHERE index_info.indkey[key_position.position - 1]
                         <> constraint_info.conkey[key_position.position]
              )
       );

    IF unindexed_foreign_keys IS NOT NULL THEN
        RAISE EXCEPTION
            'Foreign keys without a full left-prefix index: %',
            array_to_string(unindexed_foreign_keys, ', ');
    END IF;
END
$test$;

SELECT 'schema_contract_passed' AS result;
