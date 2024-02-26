[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $Location,
    [Parameter(Mandatory = $true)]
    [string]
    $ResourceGroupName,
    [Parameter(Mandatory = $false)]
    [string]
    $SubscriptionId = ""
)

# Check subscription
if ($SubscriptionId -ne "") {
    az account set --subscription $SubscriptionId
    if (!$?) { 
        Write-Error "Unable to select $SubscriptionId as the active subscription."
        exit 1
    }
    Write-Host "Active Subscription set to $SubscriptionId"
} else {
    $Subscription = az account show | ConvertFrom-Json
    $SubscriptionId = $Subscription.id
    $SubscriptionName = $Subscription.name
    Write-Host "Active Subscription is $SubscriptionId ($SubscriptionName)"
}

Write-Host "Validating deployment location"
$ValidateLocation = az account list-locations --query "[?name=='$Location']" | ConvertFrom-Json
if ($ValidateLocation.Count -eq 0) {
    Write-Error "The location provided is not valid, the available locations for your account are:"
    az account list-locations --query [].name -o table
    exit 1
}

Write-Host "Creating Resource Group"
$ResourceGroup = az group create `
    --name $ResourceGroupName `
    --location $Location

$me = az ad signed-in-user show | ConvertFrom-Json
$roleAssignments = az role assignment list --all --assignee $me.id --query "[?resourceGroup=='$ResourceGroupName' && roleDefinitionName=='Contributor'].roleDefinitionName" | ConvertFrom-Json
if ($roleAssignments.Count -eq 0) {
    Write-Host "Current user does not have contributor permissions to $ResourceGroupName resource group, attempting to assign contributor permissions"
    az role assignment create --assignee $me.id --role contributor --resource-group $ResourceGroupName
}

$DeployTimestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdTHmZ")
# Deploy
az deployment group create `
    --name "DeployLinkedTemplate-$DeployTimestamp" `
    --resource-group $ResourceGroupName `
    --template-file ../"Monitor your Microsoft 365 licenses with Logic Apps"/Bicep/MonitorLicense-root.bicep `
    --verbose

if (!$?) { 
        Write-Error "An error occured during the ARM deployment."
        exit 1
    }
    
Write-Host "Azure Logic App deployed, granting permissions to Managed Identity"

# get the Managed Identity principal ID
$ManagedIdentity = az identity show --name MonitorLicense-ManagedIdentity --resource-group $ResourceGroupName | ConvertFrom-Json

$principalId = $ManagedIdentity.principalId
# Get current role assignments
$currentRoles = (az rest `
    --method get `
    --uri https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments `
    | ConvertFrom-Json).value `
    | ForEach-Object { $_.appRoleId }

# Get Microsoft Graph ObjectId
$graphId = "00000003-0000-0000-c000-000000000000"

$graphversion = "v1.0"
$url = "https://graph.microsoft.com"
$endpoint = "servicePrincipals?`$filter="
$filter = "appId eq '$graphId'"

$uri = "$url/$graphversion/$endpoint$filter"

$graphResource = (az rest `
    --method get `
    --uri $uri `
   | ConvertFrom-Json).value

$graphResourceId = $graphResource.Id

#Get appRoleIds
$orgReadAll = az ad sp show --id $graphId --query "appRoles[?value=='Organization.Read.All'].id | [0]" -o tsv
 
$appRoleIds = $orgReadAll
#Loop over all appRoleIds
foreach ($appRoleId in $appRoleIds) {
    $roleMatch = $currentRoles -match $appRoleId
    if ($roleMatch.Length -eq 0) {
        # Add the role assignment to the principal
        $body = "{'principalId':'$principalId','resourceId':'$graphResourceId','appRoleId':'$appRoleId'}";
        az rest `
            --method post `
            --uri https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments `
            --body $body `
            --headers Content-Type=application/json 
    }
}
Write-Host "Deployment completed"
