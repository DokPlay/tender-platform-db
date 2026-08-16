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
$databaseUser = 'postgres'
$containerCreated = $false

function Assert-NativeSuccess {
    param([string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE"
    }
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

try {
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

    Write-Output 'PASS: 14 database contracts, guarded atomic installation, safe rerun rejection, and 2 canonical analytical queries completed successfully.'
}
finally {
    if ($containerCreated) {
        docker rm -f $containerName 2>$null | Out-Null
    }
}
