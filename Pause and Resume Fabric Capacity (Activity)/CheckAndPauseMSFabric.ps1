<# 
Check-And-Pause-Fabric.ps1  (PowerShell 7)
- Auto-pause Microsoft Fabric capacity if there’s no activity in the last QuietMinutes
- Filters by Capacities[capacityName] (no GUID needed)
- Robust URL building (UriBuilder), detailed logs
- Activity detection via TimePoints[TimePoint] on Interactive & Background detail tables
#>

param(
  [Parameter(Mandatory=$true)][string]$SubscriptionId,
  [Parameter(Mandatory=$true)][string]$ResourceGroup,      # RG of the capacity resource
  [Parameter(Mandatory=$true)][string]$CapacityName,       # Azure resource name, e.g. "fabricdev01"
  [Parameter(Mandatory=$true)][string]$MetricsGroupId,     # Workspace GUID of "Microsoft Fabric Capacity Metrics"
  [Parameter(Mandatory=$true)][string]$MetricsDatasetId,   # Dataset GUID from that app
  [int]$QuietMinutes = 90                                   # recommend 90 to cover telemetry lag
)

$ErrorActionPreference = "Stop"
$VerbosePreference     = "Continue"

Write-Output "=== Check-And-Pause-Fabric start $(Get-Date -Format o) ==="
Write-Output "Params: Sub=$SubscriptionId | RG=$ResourceGroup | Cap=$CapacityName | Quiet=$QuietMinutes"

# --- Auth
Connect-AzAccount -Identity | Out-Null
Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null
$ctx = Get-AzContext
Write-Output "Context: $($ctx.Account) / Sub=$($ctx.Subscription.Id)"

# --- Constants
$armBase    = "https://management.azure.com/"   # trailing slash important
$pbiRes     = "https://analysis.windows.net/powerbi/api"
$apiVersion = "2023-11-01"
$resId      = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Fabric/capacities/$CapacityName"

Write-Output "DEBUG: armBase=$armBase"
Write-Output "DEBUG: resId=$resId"
Write-Output "DEBUG: apiVersion=$apiVersion"

function Get-ArmToken { (Get-AzAccessToken -ResourceUrl $armBase).Token }
function Get-PbiToken { (Get-AzAccessToken -ResourceUrl $pbiRes).Token }

# --- Safe ARM URL builder
function New-ArmUri {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceId,   # starts with '/'
        [string]$Action = $null                            # 'suspend' | 'resume' | $null
    )
    $u = [System.Uri]::new($armBase)
    $b = [System.UriBuilder]$u
    $path = $b.Path.TrimEnd('/') + $ResourceId
    if (-not [string]::IsNullOrWhiteSpace($Action)) { $path += "/$Action" }
    $b.Path  = $path
    $b.Query = "api-version=$apiVersion"
    return $b.Uri.AbsoluteUri
}

# --- ARM calls
function Get-CapacityInfo {
    $uri = New-ArmUri -ResourceId $resId
    Write-Output "ARM GET: $uri"
    $tok = Get-ArmToken
    Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $tok" }
}
function Suspend-Capacity {
    $uri = New-ArmUri -ResourceId $resId -Action "suspend"
    Write-Output "ARM POST: $uri"
    $tok = Get-ArmToken
    Invoke-RestMethod -Method POST -Uri $uri -Headers @{ Authorization = "Bearer $tok" } | Out-Null
}

# --- Activity detection (robust) + debug summaries
function Has-Recent-Activity {
  param(
    [int]$WindowMinutes,
    [string]$CapacityNameFilter,
    [string]$GroupId,
    [string]$DatasetId
  )

  $pbiUrl = "https://api.powerbi.com/v1.0/myorg/groups/$GroupId/datasets/$DatasetId/executeQueries"
  Write-Verbose "PBI POST: $pbiUrl"
  $tok = Get-PbiToken

  # Helper: ExecuteQueries with full 400-body logging
  function Invoke-PbiQuery($dax, $label) {
    $body = @{ queries=@(@{ query=$dax }); serializerSettings=@{ includeNulls=$true } } | ConvertTo-Json -Depth 10
    try {
      return Invoke-RestMethod -Method POST -Uri $pbiUrl -Headers @{ Authorization="Bearer $tok" } -Body $body -ContentType "application/json"
    } catch {
      $resp = $_.Exception.Response
      if ($resp -and $resp.StatusCode -eq 400) {
        try {
          $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
          $errBody = $reader.ReadToEnd()
          Write-Warning "$label failed with 400. Body: $errBody"
        } catch {
          Write-Warning "$label failed with 400, but could not read error body."
        }
      } else {
        Write-Warning "$label failed: $($_.Exception.Message)"
      }
      throw
    }
  }

  # COUNT (using TimePoints[TimePoint]) — stable across tenants
  $daxCount = @"
DEFINE
  VAR NowUTC = NOW()
  VAR Cutoff = NowUTC - (($WindowMinutes + 0.0)/1440.0)
  VAR F_cap  = TREATAS({ "$CapacityNameFilter" }, 'Capacities'[capacityName])

  VAR Inter =
    CALCULATETABLE(
      'TimePointInteractiveDetail',
      F_cap,
      KEEPFILTERS('TimePoints'[TimePoint] >= Cutoff)
    )

  VAR Back =
    CALCULATETABLE(
      'TimePointBackgroundDetail',
      F_cap,
      KEEPFILTERS('TimePoints'[TimePoint] >= Cutoff)
    )

  VAR CountInteractive = COUNTROWS(Inter)
  VAR CountBackground  = COUNTROWS(Back)
  VAR AnyActivity      = CountInteractive + CountBackground

EVALUATE ROW(
  "InteractiveCount", CountInteractive,
  "BackgroundCount",  CountBackground,
  "AnyActivity",      AnyActivity
)
"@

  # SUMMARY by Type × Operation (what kinds of actions fired)
  $daxSummary = @"
DEFINE
  VAR NowUTC = NOW()
  VAR Cutoff = NowUTC - (($WindowMinutes + 0.0)/1440.0)
  VAR F_cap  = TREATAS({ "$CapacityNameFilter" }, 'Capacities'[capacityName])

  VAR Inter =
    CALCULATETABLE(
      'TimePointInteractiveDetail',
      F_cap,
      KEEPFILTERS('TimePoints'[TimePoint] >= Cutoff)
    )
  VAR Back =
    CALCULATETABLE(
      'TimePointBackgroundDetail',
      F_cap,
      KEEPFILTERS('TimePoints'[TimePoint] >= Cutoff)
    )

  VAR S1 = SUMMARIZE(Inter, 'TimePointInteractiveDetail'[Operation], "__Type", "Interactive", "__Count", COUNTROWS(Inter))
  VAR S2 = SUMMARIZE(Back,  'TimePointBackgroundDetail'[Operation], "__Type", "Background", "__Count", COUNTROWS(Back))
  VAR Combined = UNION(
    SELECTCOLUMNS(S1, "Type", [__Type], "Operation", 'TimePointInteractiveDetail'[Operation], "Count", [__Count]),
    SELECTCOLUMNS(S2, "Type", [__Type], "Operation", 'TimePointBackgroundDetail'[Operation], "Count", [__Count])
  )

EVALUATE
  TOPN(20, Combined, [Count], DESC)
"@

  # Details TOP-10: show representative rows (Type, Operation, Status, User/UPN, At)
  $daxDetails_user = @"
DEFINE
  VAR NowUTC = NOW()
  VAR Cutoff = NowUTC - (($WindowMinutes + 0.0)/1440.0)
  VAR F_cap  = TREATAS({ "$CapacityNameFilter" }, 'Capacities'[capacityName])

  VAR Inter =
    CALCULATETABLE('TimePointInteractiveDetail', F_cap, KEEPFILTERS('TimePoints'[TimePoint] >= Cutoff))
  VAR Back  =
    CALCULATETABLE('TimePointBackgroundDetail', F_cap, KEEPFILTERS('TimePoints'[TimePoint] >= Cutoff))

  VAR Combined =
    UNION(
      SELECTCOLUMNS(Inter,
        "Type","Interactive",
        "Operation",'TimePointInteractiveDetail'[Operation],
        "Status",'TimePointInteractiveDetail'[Status],
        "UserOrUPN",'TimePointInteractiveDetail'[User],
        "At",'TimePoints'[TimePoint]),
      SELECTCOLUMNS(Back,
        "Type","Background",
        "Operation",'TimePointBackgroundDetail'[Operation],
        "Status",'TimePointBackgroundDetail'[Status],
        "UserOrUPN",'TimePointBackgroundDetail'[User],
        "At",'TimePoints'[TimePoint])
    )
EVALUATE TOPN(10, Combined, [At], DESC)
"@

  $daxDetails_upn = $daxDetails_user -replace "\[User\]", "[UserPrincipalName]"

  try {
    # 1) Count
    $respCount = Invoke-PbiQuery $daxCount "CountQuery"
    $rows = $respCount.results[0].tables[0].rows
    if (-not $rows) {
      Write-Output "Metrics: Interactive=0, Background=0, Any=0"
      return $false
    }
    $int = [int]$rows[0].InteractiveCount
    $bg  = [int]$rows[0].BackgroundCount
    $any = [int]$rows[0].AnyActivity
    Write-Output ("Metrics: Interactive={0}, Background={1}, Any={2}" -f $int,$bg,$any)

    if ($any -gt 0) {
      # 2) Kind summary
      try {
        $sumResp = Invoke-PbiQuery $daxSummary "KindsSummary"
        $sumRows = $sumResp.results[0].tables[0].rows
        if ($sumRows -and $sumRows.Count -gt 0) {
          Write-Output "=== Activity kinds in window (Type × Operation → Count) ==="
          foreach ($r in $sumRows) {
            Write-Output ("{0} | {1} → {2}" -f $r.Type, $r.Operation, $r.Count)
          }
        }
      } catch { Write-Warning "Kinds summary failed; continuing." }

      # 3) Details (User vs UPN)
      try {
        $detail1 = Invoke-PbiQuery $daxDetails_user "Details(User)"
        $dRows = $detail1.results[0].tables[0].rows
      } catch {
        $detail2 = Invoke-PbiQuery $daxDetails_upn "Details(UserPrincipalName)"
        $dRows = $detail2.results[0].tables[0].rows
      }
      if ($dRows -and $dRows.Count -gt 0) {
        Write-Output "=== Recent activity details (top 10) ==="
        foreach ($d in $dRows) {
          Write-Output ("{0} | {1} | {2} | {3} | {4}" -f $d.Type,$d.Operation,$d.Status,$d.UserOrUPN,$d.At)
        }
      } else {
        Write-Output "No detail rows returned (Any>0)."
      }
    }

    return ($any -gt 0)

  } catch {
    # If counting itself fails, be conservative: treat as NO activity this run
    Write-Warning "Activity detection failed; treating as NO activity for this run."
    return $false
  }
}

# --- Main
try {
  $cap = Get-CapacityInfo
  if (-not $cap.properties) {
    Write-Warning "ARM response has no 'properties'. Raw JSON:"
    ($cap | ConvertTo-Json -Depth 10)
    throw "Unexpected ARM payload — verify ResourceGroup/CapacityName/API version."
  }

  $state = $cap.properties.state
  $sku   = $cap.sku.name
  $loc   = $cap.location
  Write-Output "Capacity: $CapacityName | State=$state | SKU=$sku | Loc=$loc"

  if ($state -ne "Active") {
    Write-Output "Capacity not Active -> nothing to do."
    return
  }

  $hasActivity = Has-Recent-Activity -WindowMinutes $QuietMinutes `
                  -CapacityNameFilter $CapacityName `
                  -GroupId $MetricsGroupId `
                  -DatasetId $MetricsDatasetId

  Write-Output "Recent activity (<= $QuietMinutes min): $hasActivity"

  if (-not $hasActivity) {
    Write-Output "No activity in last $QuietMinutes min -> suspending..."
    Suspend-Capacity
    Write-Output "Suspend requested."
  } else {
    Write-Output "Activity detected -> skip suspend."
  }

  Write-Output "=== Done ==="
}
catch {
  Write-Error "FAILED: $($_.Exception.Message)"
  throw
}
