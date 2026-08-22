\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO tender_platform, public;

CREATE TEMPORARY TABLE sample_bounds ON COMMIT DROP AS
SELECT
    (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        AT TIME ZONE 'Europe/Moscow'
    ) AS current_month_start,
    (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    ) AT TIME ZONE 'Europe/Moscow' AS previous_month_start;

INSERT INTO companies (id, name, tax_id)
OVERRIDING SYSTEM VALUE
VALUES
    (1, 'Федеральное агентство инфраструктуры', '7701000001'),
    (2, 'Городская клиническая больница', '7702000002'),
    (3, 'ООО «Альфа-Строй»', '7703000003'),
    (4, 'ООО «Бета-Сервис»', '7704000004'),
    (5, 'ООО «Гамма-Тех»', '7705000005'),
    (6, 'ООО «Дельта-Логистика»', '7706000006');

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
    completed_at,
    source_updated_at
)
OVERRIDING SYSTEM VALUE
SELECT
    sample.id,
    'sample',
    sample.external_id,
    sample.procurement_number,
    sample.title,
    sample.customer_company_id,
    'completed',
    bounds.previous_month_start + sample.published_offset,
    bounds.previous_month_start + sample.deadline_offset,
    bounds.previous_month_start + sample.completed_offset,
    bounds.previous_month_start + sample.completed_offset
FROM sample_bounds bounds
CROSS JOIN (
    VALUES
        (
            1,
            'tender-001',
            'SAMPLE-001',
            'Ремонт объектов инфраструктуры',
            1,
            INTERVAL '-20 days',
            INTERVAL '2 days',
            INTERVAL '5 days'
        ),
        (
            2,
            'tender-002',
            'SAMPLE-002',
            'Техническое обслуживание оборудования',
            1,
            INTERVAL '-15 days',
            INTERVAL '7 days',
            INTERVAL '10 days'
        ),
        (
            3,
            'tender-003',
            'SAMPLE-003',
            'Поставка медицинского оборудования',
            2,
            INTERVAL '-12 days',
            INTERVAL '12 days',
            INTERVAL '15 days'
        ),
        (
            4,
            'tender-004',
            'SAMPLE-004',
            'Логистические и сопутствующие услуги',
            2,
            INTERVAL '-10 days',
            INTERVAL '18 days',
            INTERVAL '20 days'
        ),
        (
            5,
            'tender-005',
            'SAMPLE-005',
            'Поставка расходных материалов',
            1,
            INTERVAL '-3 months 1 day',
            INTERVAL '-2 months 5 days',
            INTERVAL '-2 months 10 days'
        )
) AS sample(
    id,
    external_id,
    procurement_number,
    title,
    customer_company_id,
    published_offset,
    deadline_offset,
    completed_offset
);

INSERT INTO lots (
    id,
    tender_id,
    lot_number,
    title,
    description,
    initial_price,
    currency_code,
    status
)
OVERRIDING SYSTEM VALUE
VALUES
    (1, 1, 1, 'Ремонт здания', 'Строительные и отделочные работы', 1000000.00, 'RUB', 'completed'),
    (2, 1, 2, 'Ремонт инженерных сетей', 'Работы по инженерным коммуникациям', 700000.00, 'RUB', 'completed'),
    (3, 2, 1, 'Годовое обслуживание', 'Обслуживание технологического оборудования', 1400000.00, 'RUB', 'completed'),
    (4, 3, 1, 'Диагностическая система', 'Поставка и ввод в эксплуатацию', 800000.00, 'RUB', 'completed'),
    (5, 4, 1, 'Регулярные перевозки', 'Логистические услуги', 600000.00, 'RUB', 'completed'),
    (6, 4, 2, 'Комплексная логистика', 'Результат закупки впоследствии прекращён', 9500000.00, 'RUB', 'cancelled'),
    (7, 5, 1, 'Медицинские расходные материалы', 'Поставка предыдущего отчётного периода', 400000.00, 'RUB', 'completed');

INSERT INTO bids (
    id,
    lot_id,
    bidder_company_id,
    version_no,
    source_bid_id,
    amount,
    submitted_at,
    status
)
OVERRIDING SYSTEM VALUE
SELECT
    sample.id,
    sample.lot_id,
    sample.bidder_company_id,
    sample.version_no,
    'sample-bid-' || lpad(sample.id::text, 3, '0'),
    sample.amount,
    bounds.previous_month_start + sample.submitted_offset,
    sample.status
FROM sample_bounds bounds
CROSS JOIN (
    VALUES
        (1, 1, 3, 1, 950000.00::numeric, INTERVAL '1 day 09 hours', 'superseded'),
        (2, 1, 3, 2, 900000.00::numeric, INTERVAL '1 day 14 hours', 'admitted'),
        (3, 1, 4, 1, 930000.00::numeric, INTERVAL '1 day 15 hours', 'admitted'),
        (4, 2, 3, 1, 600000.00::numeric, INTERVAL '1 day 10 hours', 'admitted'),
        (5, 2, 4, 1, 650000.00::numeric, INTERVAL '1 day 11 hours', 'admitted'),
        (6, 2, 5, 1, 675000.00::numeric, INTERVAL '1 day 12 hours', 'rejected'),
        (7, 3, 4, 1, 1200000.00::numeric, INTERVAL '6 days 10 hours', 'admitted'),
        (8, 3, 5, 1, 1250000.00::numeric, INTERVAL '6 days 11 hours', 'admitted'),
        (9, 3, 6, 1, 1300000.00::numeric, INTERVAL '6 days 12 hours', 'withdrawn'),
        (10, 4, 5, 1, 700000.00::numeric, INTERVAL '11 days 10 hours', 'admitted'),
        (11, 4, 6, 1, 720000.00::numeric, INTERVAL '11 days 11 hours', 'admitted'),
        (12, 4, 3, 1, 750000.00::numeric, INTERVAL '11 days 12 hours', 'admitted'),
        (13, 5, 6, 1, 500000.00::numeric, INTERVAL '17 days 10 hours', 'admitted'),
        (14, 5, 3, 1, 520000.00::numeric, INTERVAL '17 days 11 hours', 'admitted'),
        (15, 6, 6, 1, 9000000.00::numeric, INTERVAL '17 days 12 hours', 'admitted'),
        (16, 6, 4, 1, 9200000.00::numeric, INTERVAL '17 days 13 hours', 'admitted'),
        (17, 7, 5, 1, 350000.00::numeric, INTERVAL '-2 months 4 days 10 hours', 'admitted'),
        (18, 7, 3, 1, 370000.00::numeric, INTERVAL '-2 months 4 days 11 hours', 'admitted')
) AS sample(
    id,
    lot_id,
    bidder_company_id,
    version_no,
    amount,
    submitted_offset,
    status
);

INSERT INTO executors (
    id,
    lot_id,
    company_id,
    awarded_amount,
    awarded_at,
    status,
    contract_number
)
OVERRIDING SYSTEM VALUE
SELECT
    sample.id,
    sample.lot_id,
    sample.company_id,
    sample.awarded_amount,
    bounds.previous_month_start + sample.awarded_offset,
    sample.status,
    sample.contract_number
FROM sample_bounds bounds
CROSS JOIN (
    VALUES
        (1, 1, 3, 900000.00::numeric, INTERVAL '5 days', 'completed', 'CONTRACT-001'),
        (2, 2, 3, 600000.00::numeric, INTERVAL '5 days 1 hour', 'completed', 'CONTRACT-002'),
        (3, 3, 4, 1200000.00::numeric, INTERVAL '10 days', 'contract_signed', 'CONTRACT-003'),
        (4, 4, 5, 700000.00::numeric, INTERVAL '15 days', 'performing', 'CONTRACT-004'),
        (5, 5, 6, 500000.00::numeric, INTERVAL '20 days', 'awarded', 'CONTRACT-005'),
        (6, 6, 6, 9000000.00::numeric, INTERVAL '20 days 1 hour', 'terminated', 'CONTRACT-006'),
        (7, 7, 5, 350000.00::numeric, INTERVAL '-2 months 10 days', 'completed', 'CONTRACT-007')
) AS sample(
    id,
    lot_id,
    company_id,
    awarded_amount,
    awarded_offset,
    status,
    contract_number
);

SELECT setval(
    pg_get_serial_sequence('tender_platform.companies', 'id'),
    (SELECT max(id) FROM companies),
    true
);
SELECT setval(
    pg_get_serial_sequence('tender_platform.tenders', 'id'),
    (SELECT max(id) FROM tenders),
    true
);
SELECT setval(
    pg_get_serial_sequence('tender_platform.lots', 'id'),
    (SELECT max(id) FROM lots),
    true
);
SELECT setval(
    pg_get_serial_sequence('tender_platform.bids', 'id'),
    (SELECT max(id) FROM bids),
    true
);
SELECT setval(
    pg_get_serial_sequence('tender_platform.executors', 'id'),
    (SELECT max(id) FROM executors),
    true
);

COMMIT;
