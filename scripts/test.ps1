[CmdletBinding()]
param(
    [string]$PostgresImage = 'postgres:16-alpine'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = Split-Path -Parent $PSScriptRoot
$containerSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$containerName = "tender-platform-db-test-$PID-$containerSuffix"
$databaseName = 'tender_platform_test'
$atomicDatabaseName = 'tender_platform_atomic_test'
$componentGuardDatabaseName = 'tender_platform_component_guard_test'
$rerunDatabaseName = 'tender_platform_rerun_test'
$concurrencyDatabaseName = 'tender_platform_concurrency_test'
$planDatabaseName = 'tender_platform_plan_test'
$databaseUser = 'postgres'
$containerCreated = $false

function Assert-NativeSuccess {
    param([string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE"
    }
}

function Find-PlanNodeByIndex {
    param(
        [object]$Node,
        [string]$IndexName
    )

    if ($null -eq $Node) {
        return $null
    }

    if ($Node.PSObject.Properties.Name -contains 'Index Name' -and
        $Node.'Index Name' -eq $IndexName) {
        return $Node
    }

    foreach ($childNode in @($Node.Plans)) {
        $match = Find-PlanNodeByIndex `
            -Node $childNode `
            -IndexName $IndexName

        if ($null -ne $match) {
            return $match
        }
    }

    return $null
}

function Assert-CanonicalQueryOutputOrder {
    Write-Output 'Running canonical efficiency output-order contract'

    $efficiencySql = Get-Content -Raw -LiteralPath (
        Join-Path $projectRoot 'sql\analytics\02_customer_efficiency.sql'
    )

    if ($efficiencySql -notmatch (
        'ORDER BY\s+report_month DESC,\s*currency_code,\s*' +
        'customer_rank NULLS LAST,\s*customer_company_id;'
    )) {
        throw 'Canonical customer-efficiency output is not totally ordered by customer ID'
    }

    Write-Output 'PASS: canonical customer-efficiency output has a deterministic final tie-breaker.'
}

function Invoke-PsqlFile {
    param([string]$ContainerPath)

    Write-Output "Running $ContainerPath"
    docker exec $containerName psql `
        -U $databaseUser `
        -d $databaseName `
        -v ON_ERROR_STOP=1 `
        -f $ContainerPath
    Assert-NativeSuccess "psql file $ContainerPath"
}

function Assert-AtomicInstallRollback {
    Write-Output 'Running atomic install rollback contract'

    docker exec $containerName createdb `
        -U $databaseUser `
        $atomicDatabaseName
    Assert-NativeSuccess 'Atomic-test database creation'

    docker exec $containerName mkdir -p /work/atomic-sql/analytics | Out-Null
    Assert-NativeSuccess 'Atomic-test work directory creation'

    docker cp (Join-Path $projectRoot 'sql\.') `
        "${containerName}:/work/atomic-sql"
    Assert-NativeSuccess 'Atomic-test SQL copy'

    docker cp `
        (Join-Path $projectRoot 'tests\fixtures\failing_analytics.sql') `
        "${containerName}:/work/atomic-sql/analytics/02_customer_efficiency.sql"
    Assert-NativeSuccess 'Atomic-test failing fixture copy'

    $failureOutput = docker exec $containerName psql `
        -U $databaseUser `
        -d $atomicDatabaseName `
        -v ON_ERROR_STOP=1 `
        -f /work/atomic-sql/tender_platform.sql 2>&1
    $failureExitCode = $LASTEXITCODE

    if ($failureExitCode -eq 0) {
        throw 'Atomic-test installer unexpectedly succeeded'
    }

    $schemaWasRolledBack = docker exec $containerName psql `
        -U $databaseUser `
        -d $atomicDatabaseName `
        -At `
        -v ON_ERROR_STOP=1 `
        -c "SELECT to_regnamespace('tender_platform') IS NULL;"
    Assert-NativeSuccess 'Atomic-test rollback inspection'

    if (($schemaWasRolledBack | Out-String).Trim() -ne 't') {
        $failureOutput | Select-Object -Last 8 | Write-Output
        throw 'Failed installer left a partial tender_platform schema behind'
    }

    Write-Output 'PASS: failed complete installation left no partial schema.'
}

function Assert-ComponentInstallGuard {
    Write-Output 'Running schema-component direct-run guard contract'

    docker exec $containerName createdb `
        -U $databaseUser `
        $componentGuardDatabaseName
    Assert-NativeSuccess 'Component-guard database creation'

    $failureOutput = docker exec $containerName psql `
        -U $databaseUser `
        -d $componentGuardDatabaseName `
        -v ON_ERROR_STOP=1 `
        -f /work/sql/01_schema.sql 2>&1
    $failureExitCode = $LASTEXITCODE

    if ($failureExitCode -eq 0) {
        throw 'Internal schema component unexpectedly allowed direct execution'
    }

    $databaseStayedEmpty = docker exec $containerName psql `
        -U $databaseUser `
        -d $componentGuardDatabaseName `
        -At `
        -v ON_ERROR_STOP=1 `
        -c "SELECT to_regnamespace('tender_platform') IS NULL
            AND NOT EXISTS (
                SELECT 1
                FROM information_schema.tables
                WHERE table_schema = 'public'
                  AND table_name IN ('companies', 'tenders', 'lots', 'bids', 'executors')
            );"
    Assert-NativeSuccess 'Component-guard database inspection'

    if (($databaseStayedEmpty | Out-String).Trim() -ne 't') {
        $failureOutput | Select-Object -Last 8 | Write-Output
        throw 'Direct schema-component execution left database objects behind'
    }

    Write-Output 'PASS: internal schema component rejected direct execution without side effects.'
}

function Assert-InstallerRerunPreservesState {
    Write-Output 'Running clean-only installer rerun contract'

    docker exec $containerName createdb `
        -U $databaseUser `
        $rerunDatabaseName
    Assert-NativeSuccess 'Rerun-test database creation'

    docker exec $containerName psql `
        -U $databaseUser `
        -d $rerunDatabaseName `
        -v ON_ERROR_STOP=1 `
        -f /work/sql/tender_platform.sql | Out-Null
    Assert-NativeSuccess 'Rerun-test initial installation'

    docker exec $containerName psql `
        -U $databaseUser `
        -d $rerunDatabaseName `
        -v ON_ERROR_STOP=1 `
        -c "INSERT INTO tender_platform.companies (id, name, tax_id)
            OVERRIDING SYSTEM VALUE
            VALUES (990001, 'Rerun sentinel', 'RERUN-SENTINEL');" | Out-Null
    Assert-NativeSuccess 'Rerun-test sentinel creation'

    $failureOutput = docker exec $containerName psql `
        -U $databaseUser `
        -d $rerunDatabaseName `
        -v ON_ERROR_STOP=1 `
        -f /work/sql/tender_platform.sql 2>&1
    $failureExitCode = $LASTEXITCODE

    if ($failureExitCode -eq 0) {
        throw 'Clean-only installer unexpectedly allowed a second installation'
    }

    $stateWasPreserved = docker exec $containerName psql `
        -U $databaseUser `
        -d $rerunDatabaseName `
        -At `
        -v ON_ERROR_STOP=1 `
        -c "SELECT EXISTS (
                SELECT 1
                FROM tender_platform.companies
                WHERE id = 990001 AND tax_id = 'RERUN-SENTINEL'
            )
            AND to_regclass('tender_platform.companies') IS NOT NULL
            AND to_regclass('tender_platform.tenders') IS NOT NULL
            AND to_regclass('tender_platform.lots') IS NOT NULL
            AND to_regclass('tender_platform.bids') IS NOT NULL
            AND to_regclass('tender_platform.executors') IS NOT NULL
            AND to_regclass('tender_platform.v_top_companies_previous_month') IS NOT NULL
            AND to_regclass('tender_platform.v_customer_efficiency_last_six_months') IS NOT NULL;"
    Assert-NativeSuccess 'Rerun-test state inspection'

    if (($stateWasPreserved | Out-String).Trim() -ne 't') {
        $failureOutput | Select-Object -Last 8 | Write-Output
        throw 'Failed installer rerun changed the previously installed state'
    }

    Write-Output 'PASS: rejected installer rerun preserved existing data and views.'
}

function Assert-LifecycleConcurrency {
    Write-Output 'Running two-session lifecycle concurrency contract'

    docker exec $containerName createdb `
        -U $databaseUser `
        $concurrencyDatabaseName
    Assert-NativeSuccess 'Concurrency-test database creation'

    docker exec $containerName psql `
        -U $databaseUser `
        -d $concurrencyDatabaseName `
        -v ON_ERROR_STOP=1 `
        -f /work/sql/tender_platform.sql | Out-Null
    Assert-NativeSuccess 'Concurrency-test installation'

    $fixtureSql = @'
SET search_path = tender_platform, public;
INSERT INTO companies (id, name, tax_id)
OVERRIDING SYSTEM VALUE
VALUES
    (910001, 'Concurrency customer', 'CONCURRENCY-CUSTOMER'),
    (910002, 'Concurrency executor', 'CONCURRENCY-EXECUTOR');
INSERT INTO tenders (
    id, source_system, external_id, procurement_number, title,
    customer_company_id, status, published_at,
    submission_deadline_at, completed_at
)
OVERRIDING SYSTEM VALUE
VALUES (
    910001, 'concurrency-test', 'deadline-race', 'CONCURRENCY-910001',
    'Deadline and award race', 910001, 'completed',
    timestamptz '2026-01-10 09:00:00+03',
    timestamptz '2026-01-20 18:00:00+03',
    timestamptz '2026-01-25 12:00:00+03'
);
INSERT INTO lots (
    id, tender_id, lot_number, title, initial_price, currency_code, status
)
OVERRIDING SYSTEM VALUE
VALUES (910001, 910001, 1, 'Concurrency lot', 100.00, 'RUB', 'completed');
'@

    docker exec $containerName psql `
        -U $databaseUser `
        -d $concurrencyDatabaseName `
        -v ON_ERROR_STOP=1 `
        -c $fixtureSql | Out-Null
    Assert-NativeSuccess 'Concurrency-test fixture creation'

    $sessionASql = @'
/* lifecycle-concurrency-session-a */
BEGIN;
SET LOCAL search_path = tender_platform, public;
UPDATE tenders
   SET submission_deadline_at = timestamptz '2026-01-22 18:00:00+03'
 WHERE id = 910001;
SELECT pg_sleep(3);
COMMIT;
'@

    $sessionA = Start-Job -ScriptBlock {
        param($TargetContainer, $TargetDatabase, $TargetUser, $Sql)

        $nativeOutput = docker exec $TargetContainer psql `
            -U $TargetUser `
            -d $TargetDatabase `
            -v ON_ERROR_STOP=1 `
            -c $Sql 2>&1

        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = ($nativeOutput | Out-String)
        }
    } -ArgumentList `
        $containerName, `
        $concurrencyDatabaseName, `
        $databaseUser, `
        $sessionASql

    try {
        $sessionAIsSleeping = $false

        for ($attempt = 1; $attempt -le 50; $attempt++) {
            $activityProbe = docker exec $containerName psql `
                -U $databaseUser `
                -d $concurrencyDatabaseName `
                -At `
                -v ON_ERROR_STOP=1 `
                -c "SELECT EXISTS (
                        SELECT 1
                        FROM pg_stat_activity
                        WHERE datname = '$concurrencyDatabaseName'
                          AND query LIKE '%lifecycle-concurrency-session-a%'
                          AND wait_event = 'PgSleep'
                    );"
            Assert-NativeSuccess 'Concurrency-test session A readiness probe'

            if (($activityProbe | Out-String).Trim() -eq 't') {
                $sessionAIsSleeping = $true
                break
            }

            Start-Sleep -Milliseconds 100
        }

        if (-not $sessionAIsSleeping) {
            throw 'Concurrency-test session A did not reach the controlled lock window'
        }

        $sessionBOutput = docker exec $containerName psql `
            -U $databaseUser `
            -d $concurrencyDatabaseName `
            -v ON_ERROR_STOP=1 `
            -c "SET statement_timeout = '10s';
                SET search_path = tender_platform, public;
                INSERT INTO executors (
                    id, lot_id, company_id, awarded_amount, awarded_at, status
                )
                OVERRIDING SYSTEM VALUE
                VALUES (
                    910001, 910001, 910002, 90.00,
                    timestamptz '2026-01-21 12:00:00+03', 'completed'
                );" 2>&1
        $sessionBExitCode = $LASTEXITCODE

        Wait-Job -Job $sessionA -Timeout 10 | Out-Null
        if ($sessionA.State -ne 'Completed') {
            throw 'Concurrency-test session A did not complete'
        }

        $sessionAResult = Receive-Job -Job $sessionA
        if ($sessionAResult.ExitCode -ne 0) {
            $sessionAResult.Output | Write-Output
            throw 'Concurrency-test session A failed'
        }

        if ($sessionBExitCode -eq 0) {
            throw 'Concurrent award incorrectly committed against the new deadline'
        }

        if (($sessionBOutput | Out-String) -notmatch
            'cannot precede the tender submission deadline') {
            $sessionBOutput | Write-Output
            throw 'Concurrent award failed for an unexpected reason'
        }

        $finalState = docker exec $containerName psql `
            -U $databaseUser `
            -d $concurrencyDatabaseName `
            -At `
            -v ON_ERROR_STOP=1 `
            -c "SELECT submission_deadline_at = timestamptz '2026-01-22 18:00:00+03'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM tender_platform.executors
                        WHERE id = 910001
                    )
                FROM tender_platform.tenders
                WHERE id = 910001;"
        Assert-NativeSuccess 'Concurrency-test final-state inspection'

        if (($finalState | Out-String).Trim() -ne 't') {
            throw 'Concurrent lifecycle operations left an invalid final state'
        }
    }
    finally {
        if ($sessionA.State -notin ('Completed', 'Failed', 'Stopped')) {
            Stop-Job -Job $sessionA | Out-Null
        }

        Remove-Job -Job $sessionA -Force | Out-Null
    }

    Write-Output 'PASS: concurrent deadline and award changes preserved lifecycle integrity.'
}

function Assert-AnalyticalPlans {
    Write-Output 'Running scaled analytical plan contract'

    docker exec $containerName createdb `
        -U $databaseUser `
        $planDatabaseName
    Assert-NativeSuccess 'Plan-test database creation'

    docker exec $containerName psql `
        -U $databaseUser `
        -d $planDatabaseName `
        -v ON_ERROR_STOP=1 `
        -f /work/sql/tender_platform.sql | Out-Null
    Assert-NativeSuccess 'Plan-test installation'

    $planFixtureSql = @'
SET search_path = tender_platform, public;
SET synchronous_commit = off;
SET session_replication_role = replica;

INSERT INTO companies (id, name, tax_id)
OVERRIDING SYSTEM VALUE
SELECT g, 'Plan company ' || g, 'PLAN-' || g
FROM generate_series(1, 6) AS g;

WITH bounds AS (
    SELECT (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    ) AT TIME ZONE 'Europe/Moscow' AS previous_month
), fixture AS (
    SELECT
        g,
        CASE
            WHEN g <= 2000 THEN bounds.previous_month
            ELSE bounds.previous_month - INTERVAL '24 months'
        END AS award_month
    FROM generate_series(1, 60000) AS g
    CROSS JOIN bounds
)
INSERT INTO tenders (
    id, external_id, procurement_number, title, customer_company_id,
    status, published_at, submission_deadline_at, completed_at
)
OVERRIDING SYSTEM VALUE
SELECT
    g,
    'PLAN-' || g,
    'PLAN-NUMBER-' || g,
    'Plan tender ' || g,
    1 + (g % 2),
    'completed',
    award_month - INTERVAL '10 days',
    award_month - INTERVAL '1 day',
    award_month + INTERVAL '3 days'
FROM fixture;

INSERT INTO lots (
    id, tender_id, lot_number, title, initial_price, currency_code, status
)
OVERRIDING SYSTEM VALUE
SELECT
    g,
    g,
    1,
    'Plan lot ' || g,
    1000 + (g % 100),
    'RUB',
    'completed'
FROM generate_series(1, 60000) AS g;

WITH bounds AS (
    SELECT (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    ) AT TIME ZONE 'Europe/Moscow' AS previous_month
), fixture AS (
    SELECT
        g,
        CASE
            WHEN g <= 2000 THEN bounds.previous_month
            ELSE bounds.previous_month - INTERVAL '24 months'
        END AS award_month
    FROM generate_series(1, 60000) AS g
    CROSS JOIN bounds
)
INSERT INTO executors (
    id, lot_id, company_id, awarded_amount, awarded_at, status
)
OVERRIDING SYSTEM VALUE
SELECT
    g,
    g,
    3 + (g % 4),
    900 + (g % 100),
    award_month + INTERVAL '2 days',
    'completed'
FROM fixture;

WITH bounds AS (
    SELECT (
        date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')
        - INTERVAL '1 month'
    ) AT TIME ZONE 'Europe/Moscow' AS previous_month
), fixture AS (
    SELECT
        lot_id,
        bidder_no,
        CASE
            WHEN lot_id <= 2000 THEN bounds.previous_month
            ELSE bounds.previous_month - INTERVAL '24 months'
        END AS award_month
    FROM generate_series(1, 60000) AS lot_id
    CROSS JOIN generate_series(1, 4) AS bidder_no
    CROSS JOIN bounds
)
INSERT INTO bids (
    id, lot_id, bidder_company_id, version_no,
    amount, submitted_at, status
)
OVERRIDING SYSTEM VALUE
SELECT
    ((lot_id - 1) * 4) + bidder_no,
    lot_id,
    2 + bidder_no,
    1,
    980 - bidder_no,
    award_month - INTERVAL '5 days',
    CASE WHEN bidder_no = 1 THEN 'admitted' ELSE 'rejected' END
FROM fixture;

SET session_replication_role = origin;
'@

    docker exec $containerName psql `
        -U $databaseUser `
        -d $planDatabaseName `
        -v ON_ERROR_STOP=1 `
        -c $planFixtureSql | Out-Null
    Assert-NativeSuccess 'Plan-test fixture creation'

    foreach ($tableName in @('tenders', 'lots', 'executors', 'bids')) {
        docker exec $containerName psql `
            -U $databaseUser `
            -d $planDatabaseName `
            -v ON_ERROR_STOP=1 `
            -c "VACUUM (ANALYZE, FREEZE) tender_platform.$tableName;" | Out-Null
        Assert-NativeSuccess "Plan-test VACUUM $tableName"
    }

    $topPlanOutput = docker exec $containerName psql `
        -U $databaseUser `
        -d $planDatabaseName `
        -X `
        -At `
        -v ON_ERROR_STOP=1 `
        -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
            SELECT *
            FROM tender_platform.v_top_companies_previous_month;" 2>&1
    Assert-NativeSuccess 'Top-company plan inspection'

    $efficiencyPlanOutput = docker exec $containerName psql `
        -U $databaseUser `
        -d $planDatabaseName `
        -X `
        -At `
        -v ON_ERROR_STOP=1 `
        -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
            SELECT *
            FROM tender_platform.v_customer_efficiency_last_six_months;" 2>&1
    Assert-NativeSuccess 'Customer-efficiency plan inspection'

    $topPlanText = ($topPlanOutput | Out-String)
    $efficiencyPlanText = ($efficiencyPlanOutput | Out-String)

    try {
        $topPlanDocument = $topPlanText | ConvertFrom-Json
        $efficiencyPlanDocument = $efficiencyPlanText | ConvertFrom-Json
    }
    catch {
        $topPlanOutput | Write-Output
        $efficiencyPlanOutput | Write-Output
        throw 'Analytical EXPLAIN output was not valid JSON'
    }

    $topExecutorNode = Find-PlanNodeByIndex `
        -Node $topPlanDocument[0].Plan `
        -IndexName 'idx_executors_active_awarded_at_company'
    $efficiencyExecutorNode = Find-PlanNodeByIndex `
        -Node $efficiencyPlanDocument[0].Plan `
        -IndexName 'idx_executors_active_awarded_at_company'
    $admittedBidNode = Find-PlanNodeByIndex `
        -Node $efficiencyPlanDocument[0].Plan `
        -IndexName 'idx_bids_admitted_lot_bidder'

    if ($null -eq $topExecutorNode -or
        [string]$topExecutorNode.'Index Cond' -notmatch 'awarded_at >=.*awarded_at <') {
        $topPlanOutput | Write-Output
        throw 'Top-company report lost the sargable awarded_at index range'
    }

    if ($null -eq $efficiencyExecutorNode -or
        [string]$efficiencyExecutorNode.'Index Cond' -notmatch
        'awarded_at >=.*awarded_at <') {
        $efficiencyPlanOutput | Write-Output
        throw 'Customer-efficiency report lost the sargable awarded_at index range'
    }

    if ($null -eq $admittedBidNode -or
        $admittedBidNode.'Node Type' -ne 'Index Only Scan' -or
        $admittedBidNode.'Heap Fetches' -ne 0) {
        $efficiencyPlanOutput | Write-Output
        throw 'Customer-efficiency report lost covering admitted-bid index access'
    }

    $topExecutionTime = $topPlanDocument[0].'Execution Time'
    $efficiencyExecutionTime = $efficiencyPlanDocument[0].'Execution Time'

    Write-Output (
        'PASS: scaled plans used executor and covering bid indexes ' +
        "(top ${topExecutionTime} ms; efficiency ${efficiencyExecutionTime} ms)."
    )
}

try {
    Assert-CanonicalQueryOutputOrder

    docker version --format '{{.Server.Version}}' | Out-Null
    Assert-NativeSuccess 'Docker availability check'

    docker run `
        --name $containerName `
        -e POSTGRES_PASSWORD=test_password `
        -e POSTGRES_DB=$databaseName `
        -d $PostgresImage | Out-Null
    Assert-NativeSuccess 'PostgreSQL container startup'
    $containerCreated = $true

    $ready = $false
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        docker exec $containerName pg_isready `
            -U $databaseUser `
            -d $databaseName | Out-Null

        if ($LASTEXITCODE -eq 0) {
            $ready = $true
            break
        }

        Start-Sleep -Seconds 1
    }

    if (-not $ready) {
        throw 'PostgreSQL did not become ready within 30 seconds'
    }

    docker exec $containerName mkdir -p /work | Out-Null
    Assert-NativeSuccess 'Container work directory creation'

    docker cp (Join-Path $projectRoot 'sql') "${containerName}:/work/sql"
    Assert-NativeSuccess 'SQL files copy'

    docker cp (Join-Path $projectRoot 'tests') "${containerName}:/work/tests"
    Assert-NativeSuccess 'Test files copy'

    Assert-ComponentInstallGuard
    Assert-AtomicInstallRollback
    Assert-InstallerRerunPreservesState
    Assert-LifecycleConcurrency

    Invoke-PsqlFile '/work/sql/tender_platform.sql'
    Invoke-PsqlFile '/work/tests/01_schema_contract.sql'
    Invoke-PsqlFile '/work/tests/02_constraints.sql'
    Invoke-PsqlFile '/work/sql/02_sample_data.sql'
    Invoke-PsqlFile '/work/tests/03_fixture_contract.sql'
    Invoke-PsqlFile '/work/tests/04_analytics_contract.sql'
    Invoke-PsqlFile '/work/tests/05_cancelled_award_contract.sql'
    Invoke-PsqlFile '/work/tests/06_exact_ranking_contract.sql'
    Invoke-PsqlFile '/work/tests/07_boundary_currency_contract.sql'
    Invoke-PsqlFile '/work/tests/08_latest_bid_version_contract.sql'
    Invoke-PsqlFile '/work/tests/09_six_month_boundary_contract.sql'
    Invoke-PsqlFile '/work/tests/10_zero_price_contract.sql'
    Invoke-PsqlFile '/work/tests/11_status_isolation_contract.sql'
    Invoke-PsqlFile '/work/tests/12_data_hygiene_defaults_contract.sql'
    Invoke-PsqlFile '/work/tests/13_lifecycle_contract.sql'
    Invoke-PsqlFile '/work/tests/14_average_rounding_contract.sql'
    Invoke-PsqlFile '/work/tests/15_top_exact_money_contract.sql'

    Assert-AnalyticalPlans

    Write-Output 'PASS: 15 database contracts, guarded atomic installation, concurrency safety, scaled query plans, and 2 canonical analytical queries completed successfully.'
}
finally {
    if ($containerCreated) {
        docker rm -f $containerName 2>$null | Out-Null
    }
}
