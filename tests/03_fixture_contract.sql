\set ON_ERROR_STOP on

SET search_path TO tender_platform, public;

DO $test$
DECLARE
    actual_count bigint;
    active_previous_month_total numeric(20, 2);
    terminated_total numeric(20, 2);
    next_company_id bigint;
BEGIN
    SELECT count(*) INTO actual_count FROM companies;
    IF actual_count <> 6 THEN
        RAISE EXCEPTION 'Expected 6 sample companies, found %', actual_count;
    END IF;

    SELECT count(*) INTO actual_count FROM tenders;
    IF actual_count <> 5 THEN
        RAISE EXCEPTION 'Expected 5 sample tenders, found %', actual_count;
    END IF;

    SELECT count(*) INTO actual_count FROM lots;
    IF actual_count <> 7 THEN
        RAISE EXCEPTION 'Expected 7 sample lots, found %', actual_count;
    END IF;

    SELECT count(*) INTO actual_count FROM bids;
    IF actual_count <> 18 THEN
        RAISE EXCEPTION 'Expected 18 sample bid revisions, found %', actual_count;
    END IF;

    SELECT count(*) INTO actual_count FROM executors;
    IF actual_count <> 7 THEN
        RAISE EXCEPTION 'Expected 7 sample award facts, found %', actual_count;
    END IF;

    SELECT count(*)
      INTO actual_count
      FROM bids
     WHERE lot_id = 1
       AND bidder_company_id = 3;

    IF actual_count <> 2 THEN
        RAISE EXCEPTION 'Expected two bid versions for company 3 on lot 1, found %', actual_count;
    END IF;

    SELECT coalesce(sum(executor.awarded_amount), 0)
      INTO active_previous_month_total
      FROM executors executor
     WHERE executor.status IN ('awarded', 'contract_signed', 'performing', 'completed')
       AND executor.awarded_at >= (
            date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
            - INTERVAL '1 month'
       ) AT TIME ZONE 'Europe/Moscow'
       AND executor.awarded_at < (
            date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
       ) AT TIME ZONE 'Europe/Moscow';

    IF active_previous_month_total <> 3900000.00 THEN
        RAISE EXCEPTION
            'Expected active previous-month awards of 3900000.00, found %',
            active_previous_month_total;
    END IF;

    SELECT coalesce(sum(awarded_amount), 0)
      INTO terminated_total
      FROM executors
     WHERE status = 'terminated';

    IF terminated_total <> 9000000.00 THEN
        RAISE EXCEPTION 'Expected terminated awards of 9000000.00, found %', terminated_total;
    END IF;

    SELECT nextval(pg_get_serial_sequence('companies', 'id'))
      INTO next_company_id;

    IF next_company_id <> 7 THEN
        RAISE EXCEPTION 'Expected next company identity value 7, found %', next_company_id;
    END IF;
END
$test$;

SELECT 'fixture_contract_passed' AS result;
