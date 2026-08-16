\set ON_ERROR_STOP on

DO $test$
DECLARE
    missing_tables text[];
    missing_constraints text[];
    invalid_indexes text[];
    invalid_foreign_keys text[];
    unindexed_foreign_keys text[];
    primary_key_count integer;
    foreign_key_count integer;
    identity_key_count integer;
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
        RAISE EXCEPTION 'Missing required tables: %', array_to_string(missing_tables, ', ');
    END IF;

    SELECT count(*)
      INTO primary_key_count
      FROM pg_constraint constraint_info
      JOIN pg_class table_info
        ON table_info.oid = constraint_info.conrelid
      JOIN pg_namespace schema_info
        ON schema_info.oid = table_info.relnamespace
     WHERE schema_info.nspname = 'tender_platform'
       AND table_info.relname IN ('companies', 'tenders', 'lots', 'bids', 'executors')
       AND constraint_info.contype = 'p';

    IF primary_key_count <> 5 THEN
        RAISE EXCEPTION 'Expected 5 primary keys, found %', primary_key_count;
    END IF;

    SELECT count(*)
      INTO identity_key_count
      FROM information_schema.columns
     WHERE table_schema = 'tender_platform'
       AND table_name IN ('companies', 'tenders', 'lots', 'bids', 'executors')
       AND column_name = 'id'
       AND data_type = 'bigint'
       AND is_identity = 'YES';

    IF identity_key_count <> 5 THEN
        RAISE EXCEPTION 'Expected 5 bigint identity primary-key columns, found %', identity_key_count;
    END IF;

    SELECT count(*)
      INTO foreign_key_count
      FROM pg_constraint constraint_info
      JOIN pg_class table_info
        ON table_info.oid = constraint_info.conrelid
      JOIN pg_namespace schema_info
        ON schema_info.oid = table_info.relnamespace
     WHERE schema_info.nspname = 'tender_platform'
       AND table_info.relname IN ('tenders', 'lots', 'bids', 'executors')
       AND constraint_info.contype = 'f';

    IF foreign_key_count <> 6 THEN
        RAISE EXCEPTION 'Expected 6 foreign keys, found %', foreign_key_count;
    END IF;

    SELECT array_agg(required.constraint_name ORDER BY required.constraint_name)
      INTO missing_constraints
      FROM (
          VALUES
              ('uq_companies_tax_id'),
              ('uq_tenders_source_external'),
              ('uq_lots_tender_number'),
              ('uq_bids_lot_bidder_version'),
              ('uq_executors_lot'),
              ('ck_tenders_completed_state')
      ) AS required(constraint_name)
      LEFT JOIN pg_constraint actual
        ON actual.conname = required.constraint_name
       AND actual.connamespace = 'tender_platform'::regnamespace
     WHERE actual.oid IS NULL;

    IF missing_constraints IS NOT NULL THEN
        RAISE EXCEPTION 'Missing business constraints: %', array_to_string(missing_constraints, ', ');
    END IF;

    WITH required_indexes AS (
        SELECT *
          FROM (
              VALUES
                  (
                      'idx_tenders_customer_company',
                      'tenders',
                      ARRAY['customer_company_id']::text[],
                      ARRAY[]::text[],
                      ARRAY[false]::boolean[],
                      NULL::text
                  ),
                  (
                      'idx_tenders_status_submission_deadline',
                      'tenders',
                      ARRAY['status', 'submission_deadline_at'],
                      ARRAY[]::text[],
                      ARRAY[false, false],
                      NULL
                  ),
                  (
                      'idx_bids_lot_status_bidder',
                      'bids',
                      ARRAY['lot_id', 'status', 'bidder_company_id'],
                      ARRAY[]::text[],
                      ARRAY[false, false, false],
                      NULL
                  ),
                  (
                      'idx_bids_admitted_lot_bidder',
                      'bids',
                      ARRAY['lot_id', 'bidder_company_id'],
                      ARRAY[]::text[],
                      ARRAY[false, false],
                      'status = ''admitted''::text'
                  ),
                  (
                      'idx_bids_bidder_company',
                      'bids',
                      ARRAY['bidder_company_id', 'submitted_at'],
                      ARRAY[]::text[],
                      ARRAY[false, true],
                      NULL
                  ),
                  (
                      'idx_executors_company',
                      'executors',
                      ARRAY['company_id'],
                      ARRAY[]::text[],
                      ARRAY[false],
                      NULL
                  ),
                  (
                      'idx_executors_active_awarded_at_company',
                      'executors',
                      ARRAY['awarded_at', 'company_id'],
                      ARRAY['awarded_amount', 'lot_id'],
                      ARRAY[false, false],
                      'status = ANY (ARRAY[''awarded''::text, ''contract_signed''::text, ''performing''::text, ''completed''::text])'
                  )
          ) AS expected(
              index_name,
              table_name,
              key_expressions,
              included_expressions,
              descending_keys,
              predicate
          )
    ),
    actual_indexes AS (
        SELECT
            index_table.relname AS table_name,
            index_class.relname AS index_name,
            access_method.amname AS access_method,
            ARRAY(
                SELECT pg_get_indexdef(index_info.indexrelid, position, true)
                  FROM generate_series(1, index_info.indnkeyatts) position
                 ORDER BY position
            ) AS key_expressions,
            ARRAY(
                SELECT pg_get_indexdef(index_info.indexrelid, position, true)
                  FROM generate_series(
                      index_info.indnkeyatts + 1,
                      index_info.indnatts
                  ) position
                 ORDER BY position
            ) AS included_expressions,
            ARRAY(
                SELECT (index_info.indoption[position - 1] & 1) = 1
                  FROM generate_series(1, index_info.indnkeyatts) position
                 ORDER BY position
            ) AS descending_keys,
            pg_get_expr(index_info.indpred, index_info.indrelid, true) AS predicate,
            index_info.indisunique,
            index_info.indisvalid,
            index_info.indisready
        FROM pg_index index_info
        JOIN pg_class index_class
          ON index_class.oid = index_info.indexrelid
        JOIN pg_namespace index_schema
          ON index_schema.oid = index_class.relnamespace
        JOIN pg_class index_table
          ON index_table.oid = index_info.indrelid
        JOIN pg_namespace table_schema
          ON table_schema.oid = index_table.relnamespace
        JOIN pg_am access_method
          ON access_method.oid = index_class.relam
        WHERE index_schema.nspname = 'tender_platform'
          AND table_schema.nspname = 'tender_platform'
    )
    SELECT array_agg(expected.index_name ORDER BY expected.index_name)
      INTO invalid_indexes
      FROM required_indexes expected
      LEFT JOIN actual_indexes actual
        ON actual.index_name = expected.index_name
       AND actual.table_name = expected.table_name
       AND actual.access_method = 'btree'
       AND actual.key_expressions = expected.key_expressions
       AND actual.included_expressions = expected.included_expressions
       AND actual.descending_keys = expected.descending_keys
       AND actual.predicate IS NOT DISTINCT FROM expected.predicate
       AND NOT actual.indisunique
       AND actual.indisvalid
       AND actual.indisready
     WHERE actual.index_name IS NULL;

    IF invalid_indexes IS NOT NULL THEN
        RAISE EXCEPTION
            'Missing or incorrectly defined workload indexes: %',
            array_to_string(invalid_indexes, ', ');
    END IF;

    WITH required_foreign_keys AS (
        SELECT *
          FROM (
              VALUES
                  ('fk_tenders_customer', 'tenders', 'customer_company_id', 'companies', 'id'),
                  ('fk_lots_tender', 'lots', 'tender_id', 'tenders', 'id'),
                  ('fk_bids_lot', 'bids', 'lot_id', 'lots', 'id'),
                  ('fk_bids_bidder_company', 'bids', 'bidder_company_id', 'companies', 'id'),
                  ('fk_executors_lot', 'executors', 'lot_id', 'lots', 'id'),
                  ('fk_executors_company', 'executors', 'company_id', 'companies', 'id')
          ) AS expected(
              constraint_name,
              source_table,
              source_column,
              target_table,
              target_column
          )
    ),
    actual_foreign_keys AS (
        SELECT
            constraint_info.conname AS constraint_name,
            source_table.relname AS source_table,
            source_column.attname AS source_column,
            target_table.relname AS target_table,
            target_column.attname AS target_column,
            constraint_info.confupdtype,
            constraint_info.confdeltype
        FROM pg_constraint constraint_info
        JOIN pg_class source_table
          ON source_table.oid = constraint_info.conrelid
        JOIN pg_namespace source_schema
          ON source_schema.oid = source_table.relnamespace
        JOIN pg_attribute source_column
          ON source_column.attrelid = source_table.oid
         AND source_column.attnum = constraint_info.conkey[1]
        JOIN pg_class target_table
          ON target_table.oid = constraint_info.confrelid
        JOIN pg_attribute target_column
          ON target_column.attrelid = target_table.oid
         AND target_column.attnum = constraint_info.confkey[1]
        WHERE source_schema.nspname = 'tender_platform'
          AND constraint_info.contype = 'f'
    )
    SELECT array_agg(expected.constraint_name ORDER BY expected.constraint_name)
      INTO invalid_foreign_keys
      FROM required_foreign_keys expected
      LEFT JOIN actual_foreign_keys actual
        ON actual.constraint_name = expected.constraint_name
       AND actual.source_table = expected.source_table
       AND actual.source_column = expected.source_column
       AND actual.target_table = expected.target_table
       AND actual.target_column = expected.target_column
       AND actual.confupdtype = 'r'
       AND actual.confdeltype = 'r'
     WHERE actual.constraint_name IS NULL;

    IF invalid_foreign_keys IS NOT NULL THEN
        RAISE EXCEPTION
            'Missing or incorrectly defined foreign keys: %',
            array_to_string(invalid_foreign_keys, ', ');
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
            WHERE index_info.indrelid = constraint_info.conrelid
              AND index_info.indisvalid
              AND index_info.indisready
              AND index_info.indpred IS NULL
              AND index_info.indkey[0] = constraint_info.conkey[1]
       );

    IF unindexed_foreign_keys IS NOT NULL THEN
        RAISE EXCEPTION
            'Foreign keys without a left-prefix index: %',
            array_to_string(unindexed_foreign_keys, ', ');
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'tender_platform'
           AND table_name = 'executors'
           AND column_name = 'awarded_amount'
           AND data_type = 'numeric'
           AND numeric_precision = 20
           AND numeric_scale = 2
    ) THEN
        RAISE EXCEPTION 'executors.awarded_amount must be numeric(20,2)';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'tender_platform'
           AND table_name = 'executors'
           AND column_name = 'awarded_at'
           AND data_type = 'timestamp with time zone'
    ) THEN
        RAISE EXCEPTION 'executors.awarded_at must be timestamptz';
    END IF;
END
$test$;

SELECT 'schema_contract_passed' AS result;
