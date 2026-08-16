\set ON_ERROR_STOP on

DO $test$
DECLARE
    missing_tables text[];
    missing_constraints text[];
    missing_indexes text[];
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
              ('uq_executors_lot')
      ) AS required(constraint_name)
      LEFT JOIN pg_constraint actual
        ON actual.conname = required.constraint_name
       AND actual.connamespace = 'tender_platform'::regnamespace
     WHERE actual.oid IS NULL;

    IF missing_constraints IS NOT NULL THEN
        RAISE EXCEPTION 'Missing business constraints: %', array_to_string(missing_constraints, ', ');
    END IF;

    SELECT array_agg(required.index_name ORDER BY required.index_name)
      INTO missing_indexes
      FROM (
          VALUES
              ('idx_tenders_customer_company'),
              ('idx_tenders_status_submission_deadline'),
              ('idx_bids_lot_status_bidder'),
              ('idx_bids_bidder_company'),
              ('idx_executors_active_awarded_at_company')
      ) AS required(index_name)
      LEFT JOIN pg_indexes actual
        ON actual.schemaname = 'tender_platform'
       AND actual.indexname = required.index_name
     WHERE actual.indexname IS NULL;

    IF missing_indexes IS NOT NULL THEN
        RAISE EXCEPTION 'Missing workload indexes: %', array_to_string(missing_indexes, ', ');
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
