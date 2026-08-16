[CmdletBinding()]
param(
    [string]$PostgresImage = 'postgres:16-alpine'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$containerSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$containerName = "tender-platform-db-test-$PID-$containerSuffix"
$databaseName = 'tender_platform_test'
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

    Write-Output 'PASS: 10 database contracts and 2 canonical analytical queries completed successfully.'
}
finally {
    if ($containerCreated) {
        docker rm -f $containerName 2>$null | Out-Null
    }
}
