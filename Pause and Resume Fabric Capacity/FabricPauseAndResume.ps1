Param(
    [Parameter(Mandatory=$true, HelpMessage="Full Azure Resource ID for the Fabric capacity. Format: /subscriptions/{subscription-id}/resourceGroups/{resource-group}/providers/Microsoft.Fabric/capacities/{capacity-name}")]
    [string]$ResourceID,
    
    [Parameter(Mandatory=$true, HelpMessage="Operation to perform. To Suspend type one of these: suspend | stop | pause | 0  --OR-- To Resume: resume | start | run | 1 ")]
    [ValidateSet("suspend", "resume", "stop", "start", "pause", "run", "0", "1", IgnoreCase=$true)]
    [string]$operation
)

# Function to normalize operation input to Azure API operations
function Get-NormalizedOperation {
    param([string]$inputOperation)
    
    $normalizedInput = $inputOperation.ToLower().Trim()
    
    switch ($normalizedInput) {
        "suspend" { return "suspend" }
        "stop" { return "suspend" }
        "pause" { return "suspend" }
        "0" { return "suspend" }
        
        "resume" { return "resume" }
        "start" { return "resume" }
        "run" { return "resume" }
        "1" { return "resume" }
        
        default { 
            Write-Warning "Unrecognized operation: '$inputOperation'. Valid options are: suspend, stop, pause, 0 (for suspend) or resume, start, run, 1 (for resume)"
            return $inputOperation 
        }
    }
}

if ([string]::IsNullOrWhiteSpace($operation)) {
    Write-Error "Operation parameter is required. Valid options are: suspend, stop, pause, 0 (for suspend) or resume, start, run, 1 (for resume)"
    exit 1
}

$normalizedOperation = Get-NormalizedOperation -inputOperation $operation
Write-Output "Input operation: '$operation' -> Normalized to: '$normalizedOperation'"

if ([string]::IsNullOrWhiteSpace($ResourceID)) {
    Write-Error "ResourceID parameter is required."
    exit 1
}

try {
    # Connect using Managed Identity
    Write-Output "Connecting to Azure using Managed Identity..."
    Connect-AzAccount -Identity
    
    # Get access token for Azure Resource Manager
    Write-Output "Acquiring access token..."
    $tokenObject = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
    $token = $tokenObject.Token

    # Construct the API URL
    $url = "https://management.azure.com$ResourceID/$normalizedOperation" + "?api-version=2022-07-01-preview"
    Write-Output "API URL: $url"
    
    # Prepare headers
    $headers = @{
        'Content-Type' = 'application/json'
        'Authorization' = "Bearer $token"
    }
    
    # Make the API call
    Write-Output "Executing $normalizedOperation operation on Fabric capacity..."
    $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers
    
    # Output the response
    Write-Output "Operation completed successfully!"
    $response
    
    # Additional status information
    if ($normalizedOperation -eq "suspend") {
        Write-Output "Fabric capacity has been suspended/stopped."
    } elseif ($normalizedOperation -eq "resume") {
        Write-Output "Fabric capacity has been resumed/started."
    }
    
} catch {
    Write-Error "Failed to execute operation: $($_.Exception.Message)"
    Write-Error "Full error details: $($_.Exception)"
    exit 1
}
