<#
.SYNOPSIS
    Pester tests for CS_MongoServiceCheck.ps1

.DESCRIPTION
    Unit tests covering the following scenarios:
        - No servers returned from the database (early exit)
        - Service running normally on all servers (no alerts)
        - Service stopped on a server (alert generated)
        - Service not found on a server (alert generated)
        - Initial CIM query fails, retry succeeds (retry logic)
        - Initial CIM query fails, retry succeeds but service is stopped
        - All retry attempts exhausted (alert generated after 5 minutes of retries)
        - Slack webhook is called when alerts exist
        - Slack webhook is NOT called when no alerts exist
        - CIM session cleanup in the finally block

    All external dependencies (Invoke-DbaQuery, New-CimSession, Get-CimInstance,
    Remove-CimSession, Invoke-RestMethod, Start-Sleep) are mocked so tests run
    without network or database access.

    Mock call counts are tracked via global counter variables because Pester 3.x
    mock scriptblocks execute in changing scopes when invoked from child scripts.

.NOTES
    Requires: Pester 3.x+
    Usage  : Invoke-Pester -Path .\CS_MongoServiceCheck.Tests.ps1
#>

# Path to the script under test
$ScriptPath = Join-Path $PSScriptRoot 'CS_MongoServiceCheck.ps1'

# ---------- Helper: build a fake Win32_Service CIM object ----------
function New-FakeService {
    param(
        [string]$Name        = 'MongoDB',
        [string]$DisplayName = 'MongoDB Server',
        [string]$State       = 'Running',
        [string]$StartMode   = 'Auto',
        [int]$ProcessId      = 1234
    )
    [PSCustomObject]@{
        Name        = $Name
        DisplayName = $DisplayName
        State       = $State
        StartMode   = $StartMode
        ProcessId   = $ProcessId
    }
}

# ---------- Helper: build a fake server row from the DB ----------
function New-FakeServer {
    param([string]$HostName)
    [PSCustomObject]@{ HostName = $HostName }
}

# =====================================================================
#  Test Suite
# =====================================================================
Describe 'CS_MongoServiceCheck.ps1' {

    # ------------------------------------------------------------------
    #  Reset counters and set up base mocks before each It block.
    #  NOTE: New-CimSession is NOT mocked here to avoid overwriting
    #  Context-level mocks that need it to throw.
    # ------------------------------------------------------------------
    BeforeEach {
        $global:SleepCount      = 0
        $global:CimSessionCount = 0
        $global:RestCount       = 0
        $global:RemoveCount     = 0

        Mock Start-Sleep        { $global:SleepCount++ }
        Mock Remove-CimSession  { $global:RemoveCount++ }
        Mock Invoke-RestMethod  { $global:RestCount++ }
    }

    AfterEach {
        # Clean up global counters
        Remove-Variable -Name SleepCount,CimSessionCount,RestCount,RemoveCount -Scope Global -ErrorAction SilentlyContinue
    }

    # ==================================================================
    #  1. No servers returned from the database
    # ==================================================================
    Context 'When no servers are returned from the database' {
        Mock Invoke-DbaQuery { $null }

        It 'Should write an error and exit' {
            $result = & $ScriptPath -SqlInstance 'fake' -Database 'fake' 2>&1

            $errors = $result | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
            $errors | Should Not BeNullOrEmpty
            ($errors | Out-String) | Should Match 'No MongoDB servers found'
        }
    }

    # ==================================================================
    #  2. All services running — happy path
    # ==================================================================
    Context 'When all services are running' {
        Mock Invoke-DbaQuery {
            @(
                (New-FakeServer -HostName 'SERVER01'),
                (New-FakeServer -HostName 'SERVER02')
            )
        }
        Mock New-CimSession  { $global:CimSessionCount++; [Microsoft.Management.Infrastructure.CimSession]::Create('localhost') }
        Mock Get-CimInstance  { New-FakeService -State 'Running' }

        It 'Should output a result object for each server' {
            $results = & $ScriptPath 2>&1 | Where-Object { $_ -is [PSCustomObject] -and $_.ComputerName }
            $results.Count | Should Be 2
        }

        It 'Should report Running status for each server' {
            $results = & $ScriptPath 2>&1 | Where-Object { $_ -is [PSCustomObject] -and $_.ComputerName }
            $results | ForEach-Object { $_.Status | Should Be 'Running' }
        }

        It 'Should NOT send a Slack alert' {
            & $ScriptPath 2>&1 | Out-Null
            $global:RestCount | Should Be 0
        }

        It 'Should clean up CIM sessions' {
            & $ScriptPath 2>&1 | Out-Null
            $global:RemoveCount | Should Be 2
        }
    }

    # ==================================================================
    #  3. Service is stopped on one server
    # ==================================================================
    Context 'When a service is stopped on a server' {
        Mock Invoke-DbaQuery {
            @( (New-FakeServer -HostName 'SERVER01') )
        }
        Mock New-CimSession  { $global:CimSessionCount++; [Microsoft.Management.Infrastructure.CimSession]::Create('localhost') }
        Mock Get-CimInstance  { New-FakeService -State 'Stopped' }

        It 'Should output the result with Stopped status' {
            $results = & $ScriptPath 2>&1 | Where-Object { $_ -is [PSCustomObject] -and $_.ComputerName }
            $results[0].Status | Should Be 'Stopped'
        }

        It 'Should send a Slack alert' {
            & $ScriptPath 2>&1 | Out-Null
            $global:RestCount | Should Be 1
        }
    }

    # ==================================================================
    #  4. Service not found on a server
    # ==================================================================
    Context 'When the service is not found on a server' {
        Mock Invoke-DbaQuery {
            @( (New-FakeServer -HostName 'SERVER01') )
        }
        Mock New-CimSession  { $global:CimSessionCount++; [Microsoft.Management.Infrastructure.CimSession]::Create('localhost') }
        Mock Get-CimInstance  { $null }

        It 'Should send a Slack alert for Service Not Found' {
            & $ScriptPath 2>&1 | Out-Null
            $global:RestCount | Should Be 1
        }
    }

    # ==================================================================
    #  5. Initial CIM query fails, retry succeeds
    # ==================================================================
    Context 'When the initial CIM query fails but retry succeeds' {
        Mock Invoke-DbaQuery {
            @( (New-FakeServer -HostName 'SERVER01') )
        }

        Mock New-CimSession {
            $global:CimSessionCount++
            if ($global:CimSessionCount -eq 1) {
                throw 'WinRM connection failed'
            }
            [Microsoft.Management.Infrastructure.CimSession]::Create('localhost')
        }

        Mock Get-CimInstance { New-FakeService -State 'Running' }

        It 'Should succeed on retry and output a Running result' {
            $results = & $ScriptPath 2>&1 | Where-Object { $_ -is [PSCustomObject] -and $_.ComputerName }
            $results.Count | Should Be 1
            $results[0].Status | Should Be 'Running'
        }

        It 'Should NOT send a Slack alert' {
            & $ScriptPath 2>&1 | Out-Null
            $global:RestCount | Should Be 0
        }

        It 'Should have waited before retrying' {
            & $ScriptPath 2>&1 | Out-Null
            $global:SleepCount | Should Be 1
        }
    }

    # ==================================================================
    #  6. Initial CIM query fails, retry succeeds but service stopped
    # ==================================================================
    Context 'When the initial CIM query fails and retry finds the service stopped' {
        Mock Invoke-DbaQuery {
            @( (New-FakeServer -HostName 'SERVER01') )
        }

        Mock New-CimSession {
            $global:CimSessionCount++
            if ($global:CimSessionCount -eq 1) {
                throw 'WinRM connection failed'
            }
            [Microsoft.Management.Infrastructure.CimSession]::Create('localhost')
        }

        Mock Get-CimInstance { New-FakeService -State 'Stopped' }

        It 'Should output a Stopped result from the retry' {
            $results = & $ScriptPath 2>&1 | Where-Object { $_ -is [PSCustomObject] -and $_.ComputerName }
            $results[0].Status | Should Be 'Stopped'
        }

        It 'Should send a Slack alert for the stopped service' {
            & $ScriptPath 2>&1 | Out-Null
            $global:RestCount | Should Be 1
        }
    }

    # ==================================================================
    #  7. All retry attempts exhausted (unreachable server)
    # ==================================================================
    Context 'When all retry attempts are exhausted' {
        Mock Invoke-DbaQuery {
            @( (New-FakeServer -HostName 'SERVER01') )
        }

        # Every New-CimSession call throws to simulate a completely unreachable server
        Mock New-CimSession { $global:CimSessionCount++; throw 'WinRM connection failed' }

        It 'Should send a Slack alert after exhausting retries' {
            & $ScriptPath 2>&1 | Out-Null
            $global:RestCount | Should Be 1
        }

        It 'Should have called New-CimSession 11 times (1 initial + 10 retries)' {
            & $ScriptPath 2>&1 | Out-Null
            $global:CimSessionCount | Should Be 11
        }

        It 'Should have slept 10 times (once per retry attempt)' {
            & $ScriptPath 2>&1 | Out-Null
            $global:SleepCount | Should Be 10
        }
    }

    # ==================================================================
    #  8. Retry succeeds on the 3rd attempt
    # ==================================================================
    Context 'When retry succeeds on the 3rd attempt' {
        Mock Invoke-DbaQuery {
            @( (New-FakeServer -HostName 'SERVER01') )
        }

        # Fail the initial call + first 2 retries, succeed on retry #3
        Mock New-CimSession {
            $global:CimSessionCount++
            if ($global:CimSessionCount -le 3) {
                throw 'WinRM connection failed'
            }
            [Microsoft.Management.Infrastructure.CimSession]::Create('localhost')
        }

        Mock Get-CimInstance { New-FakeService -State 'Running' }

        It 'Should succeed after 3 retry sleeps' {
            $results = & $ScriptPath 2>&1 | Where-Object { $_ -is [PSCustomObject] -and $_.ComputerName }
            $results.Count | Should Be 1
            $results[0].Status | Should Be 'Running'
        }

        It 'Should have slept exactly 3 times' {
            & $ScriptPath 2>&1 | Out-Null
            $global:SleepCount | Should Be 3
        }

        It 'Should NOT send a Slack alert' {
            & $ScriptPath 2>&1 | Out-Null
            $global:RestCount | Should Be 0
        }
    }

    # ==================================================================
    #  9. Multiple servers — mixed results
    # ==================================================================
    Context 'When one server is healthy and another is unreachable' {
        Mock Invoke-DbaQuery {
            @(
                (New-FakeServer -HostName 'HEALTHY01'),
                (New-FakeServer -HostName 'DOWN01')
            )
        }

        Mock New-CimSession {
            param($ComputerName)
            $global:CimSessionCount++
            if ($ComputerName -eq 'DOWN01') {
                throw 'WinRM connection failed'
            }
            [Microsoft.Management.Infrastructure.CimSession]::Create('localhost')
        }

        Mock Get-CimInstance { New-FakeService -State 'Running' }

        It 'Should output a Running result for the healthy server' {
            $results = & $ScriptPath 2>&1 | Where-Object { $_ -is [PSCustomObject] -and $_.ComputerName }
            ($results | Where-Object { $_.ComputerName -eq 'HEALTHY01' }).Status | Should Be 'Running'
        }

        It 'Should send a Slack alert (for the unreachable server)' {
            & $ScriptPath 2>&1 | Out-Null
            $global:RestCount | Should Be 1
        }
    }

    # ==================================================================
    # 10. Slack webhook failure does not throw unhandled exception
    # ==================================================================
    Context 'When the Slack webhook call fails' {
        Mock Invoke-DbaQuery {
            @( (New-FakeServer -HostName 'SERVER01') )
        }
        Mock New-CimSession  { [Microsoft.Management.Infrastructure.CimSession]::Create('localhost') }
        Mock Get-CimInstance  { New-FakeService -State 'Stopped' }
        Mock Invoke-RestMethod { throw 'Webhook unreachable' }

        It 'Should not throw an unhandled exception' {
            { & $ScriptPath 2>&1 | Out-Null } | Should Not Throw
        }
    }

    # ==================================================================
    # 11. Output object has expected properties
    # ==================================================================
    Context 'Output object schema' {
        Mock Invoke-DbaQuery {
            @( (New-FakeServer -HostName 'SERVER01') )
        }
        Mock New-CimSession  { [Microsoft.Management.Infrastructure.CimSession]::Create('localhost') }
        Mock Get-CimInstance  { New-FakeService }

        It 'Should contain all expected properties' {
            $result = & $ScriptPath 2>&1 | Where-Object { $_ -is [PSCustomObject] -and $_.ComputerName } | Select-Object -First 1

            ($result.PSObject.Properties.Name -contains 'ComputerName') | Should Be $true
            ($result.PSObject.Properties.Name -contains 'ServiceName')  | Should Be $true
            ($result.PSObject.Properties.Name -contains 'DisplayName')  | Should Be $true
            ($result.PSObject.Properties.Name -contains 'Status')       | Should Be $true
            ($result.PSObject.Properties.Name -contains 'StartMode')    | Should Be $true
            ($result.PSObject.Properties.Name -contains 'ProcessId')    | Should Be $true
            ($result.PSObject.Properties.Name -contains 'Timestamp')    | Should Be $true
        }

        It 'Should have a valid Timestamp format' {
            $result = & $ScriptPath 2>&1 | Where-Object { $_ -is [PSCustomObject] -and $_.ComputerName } | Select-Object -First 1
            $result.Timestamp | Should Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        }
    }
}
