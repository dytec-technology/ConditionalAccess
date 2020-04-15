<#    
.SYNOPSIS
    Script for automatic creation and update of Conditoinal Access Policies based on JSON representations

.DESCRIPTION
    Connects to Microsoft Graph via device code flow
    Connects to Azure AD via AzureAD module, normal user login

    Creates AAD group for AADC synchronization service accounts
    Creates AAD group for AAD emergency access accounts
    Creates dynamic AAD group for AADP2 user

    Imports JSON representations  of conditional access policies from a policy folder
    Creates a AAD group for each conditional access policy which will be used for exclusions
    Either creates a new conditional access policy for each JSON representation or updates an existing policy. Updating / matching existing policies is based on the DisplayName.

.PARAMETER Prefix
    The prefix will be used to replace the <PREFIX> placeholder which is part of the displayName in the JSON representation
    Additionally, it is used as a prefix for all groups that are created if no explicit group name is provided

.PARAMETER ClientId
    The Application (client) ID of the created app registration 

.PARAMETER TenantName
    The .onmicrosoft.com tenant name e.g. company.onmicrosoft.com

.PARAMETER PoliciesFolder
    Path of the folder where the templates are located e.g. C:\Repos\ConditionalAccess\Policies

.PARAMETER ExclusionGroupsPrefix
    Prefix of the exclusion group that is created for each policy, if no value is specified, the prefix value is used
    If no value is provided: $Prefix + "_Exclusion_ + $Prefix + ("{0:00}" -f $Counter) e.g CA_Exclusion_CA01, CA_Exclusion_CA02, ...
    If value (e.g. "CAE_" ) is provided: $ExclusionGroupsPrefix + $Prefix + ("{0:00}" -f $Counter) e.g. CAE_CA01, CAE_CA02, ...
    If a group with that name already exists, it will be used

.PARAMETER AADP2Group
    Name of the dynamic group of users licensed with Azure AD Premium P2
    If no value is provided: $Prefix + "_AADP2", e.g. CA_AADP2
    If a group with that name already exists, it will be used

.PARAMETER SynchronizationServiceAccountsGroup
    Name of the group for the Azure AD Connect service accounts which are excluded from policies. (On-Premises Directory Synchronization Service Account)
    If no value is provided: $Prefix + "_Exclusion_SynchronizationServiceAccounts", e.g. CA_Exclusion_SynchronizationServiceAccounts
    If a group with that name already exists, it will be used

.PARAMETER EmergencyAccessAccountsGroup
    Name of the group for the emergency access accounts which are excluded from policies
    If no value is provided: $Prefix + "_Exclusion_EmergencyAccessAccounts", e.g. CA_Exclusion_EmergencyAccessAccounts
    If a group with that name already exists, it will be used

.NOTES
    Version:        1.0
    Author:         Alexander Filipin
    Creation date:  2020-04-09
    Last modified:  2020-04-10

    Many thanks to the two Microsoft MVPs whose publications served as a basis for this script:
        Jan Vidar Elven's work https://github.com/JanVidarElven/MicrosoftGraph-ConditionalAccess
        Daniel Chronlund's work https://danielchronlund.com/2019/11/07/automatic-deployment-of-conditional-access-with-powershell-and-microsoft-graph/
  
.EXAMPLE 
    .\Deploy-Policies.ps1 -Prefix "CA" -ClientId "a4a0356b-69a5-4b85-9545-f64459010333" -TenantName "company.onmicrosoft.com" -PoliciesFolder "C:\Repos\ConditionalAccess\Policies" 

.EXAMPLE
    .\Deploy-Policies.ps1 -Prefix "CA" -ClientId "a4a0356b-69a5-4b85-9545-f64459010333" -TenantName "company.onmicrosoft.com" -PoliciesFolder "C:\Repos\ConditionalAccess\Policies" -ExclusionGroupsPrefix "CA_Exclusion_" -AADP2Group "AADP2" -SynchronizationServiceAccountsGroup "SyncAccounts" -EmergencyAccessAccountsGroup "BreakGlassAccounts"
#>
Param(
    [Parameter(Mandatory=$True)]
    [System.String]$Prefix
    ,
    [Parameter(Mandatory=$True)]
    [System.String]$ClientId
    ,
    [Parameter(Mandatory=$True)]
    [System.String]$TenantName
    ,
    [Parameter(Mandatory=$True)]
    [System.String]$PoliciesFolder
    ,
    [Parameter(Mandatory=$False)]
    [System.String]$ExclusionGroupsPrefix
    ,   
    [Parameter(Mandatory=$False)]
    [System.String]$AADP2Group
    ,    
    [Parameter(Mandatory=$False)]
    [System.String]$SynchronizationServiceAccountsGroup
    ,
    [Parameter(Mandatory=$False)]
    [System.String]$EmergencyAccessAccountsGroup
)

#region parameters
if(-not $ExclusionGroupsPrefix){$ExclusionGroupsPrefix = $Prefix + "_Exclusion_"}
if(-not $AADP2Group){$AADP2Group = $Prefix + "_AADP2"}
if(-not $SynchronizationServiceAccountsGroup){$SynchronizationServiceAccountsGroup = $Prefix + "_Exclusion_SynchronizationServiceAccounts"}
if(-not $EmergencyAccessAccountsGroup){$EmergencyAccessAccountsGroup = $Prefix + "_Exclusion_EmergencyAccessAccounts"}
#endregion

#region development
<#
$DebugMode = $True
$Prefix = "CA"
$ClientId = "a4a0356b-69a5-4b85-9545-f64459010333"
$TenantName = "filipinlabs.onmicrosoft.com"
$PoliciesFolder = "C:\AF\Repos\ConditionalAccess\Policies"
#>
#endregion

#region functions
function New-AFAzureADGroup($Name){
    $Group = Get-AzureADGroup -SearchString $Name
    if(-not $Group){
        New-AzureADGroup -DisplayName $Name -MailEnabled $false -SecurityEnabled $true -MailNickName "NotSet" 
    }
}

function New-GraphConditionalAccessPolicy{
    [cmdletbinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        $requestBody,
        [Parameter(Mandatory = $true)]
        $accessToken 
    )
    $conditionalAccessURI = "https://graph.microsoft.com/beta/conditionalAccess/policies"
    $conditionalAccessPolicyResponse = Invoke-RestMethod -Method Post -Uri $conditionalAccessURI -Headers @{"Authorization"="Bearer $accessToken"} -Body $requestBody -ContentType "application/json"
    $conditionalAccessPolicyResponse     
}

function Remove-GraphConditionalAccessPolicy{
    [cmdletbinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        $Id,
        [Parameter(Mandatory = $true)]
        $accessToken 
    )
    $conditionalAccessURI = "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/{$Id}"
    $conditionalAccessPolicyResponse = Invoke-RestMethod -Method Delete -Uri $conditionalAccessURI -Headers @{"Authorization"="Bearer $accessToken"}
    $conditionalAccessPolicyResponse     
}

function Get-GraphConditionalAccessPolicy{
    [cmdletbinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        $accessToken,
        [Parameter(Mandatory = $false)]
        $All, 
        [Parameter(Mandatory = $false)]
        $DisplayName,
        [Parameter(Mandatory = $false)]
        $Id 
    )
    if($DisplayName){
        #$conditionalAccessURI = "https://graph.microsoft.com/beta/identity/conditionalAccess/policies?`$filter=displayName eq '$DisplayName'"
        $conditionalAccessURI = "https://graph.microsoft.com/beta/identity/conditionalAccess/policies?`$filter=endswith(displayName, '$DisplayName')"
    }
    if($Id){
        $conditionalAccessURI = "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/{$Id}"
    }
    if($All -eq $true){
        $conditionalAccessURI = "https://graph.microsoft.com/beta/identity/conditionalAccess/policies"
    }
    $conditionalAccessPolicyResponse = Invoke-RestMethod -Method Get -Uri $conditionalAccessURI -Headers @{"Authorization"="Bearer $accessToken"}
    $conditionalAccessPolicyResponse     
}

function Set-GraphConditionalAccessPolicy{
    [cmdletbinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        $requestBody,
        [Parameter(Mandatory = $true)]
        $accessToken,
        [Parameter(Mandatory = $false)]
        $Id
    )
    $conditionalAccessURI = "https://graph.microsoft.com/beta/identity/conditionalAccess/policies/{$Id}"
    $conditionalAccessPolicyResponse = Invoke-RestMethod -Method Patch -Uri $conditionalAccessURI -Headers @{"Authorization"="Bearer $accessToken"} -Body $requestBody -ContentType "application/json"
    $conditionalAccessPolicyResponse     
}
#endregion

#region connect
if(-not $DebugMode){
    #Connect to Graph
    $resource = "https://graph.microsoft.com/"
    $authUrl = "https://login.microsoftonline.com/$TenantName"

    #Using Device Code Flow that support Modern Authentication for Delegated User
    $postParams = @{ resource = "$resource"; client_id = "$ClientId" }
    $response = Invoke-RestMethod -Method POST -Uri "$authurl/oauth2/devicecode" -Body $postParams
    Write-Host $response.message
    #HALT: Go to Browser logged in as User with access to Azure AD Conditional Access and tenant and paste in Device Code

    $Confirmation = ""
    while ($Confirmation -notmatch "[y|n]"){
        $Confirmation = Read-Host "Did you complete the device code flow login? (Y/N)"
    }
    if ($Confirmation -eq "y"){
        $tokenParams = @{ grant_type = "device_code"; resource = "$resource"; client_id = "$ClientId"; code = "$($response.device_code)" }
        $tokenResponse = $null
        # Provided Successful Authentication, the following should return Access and Refresh Tokens: 
        $tokenResponse = Invoke-RestMethod -Method POST -Uri "$authurl/oauth2/token" -Body $tokenParams
        # Save Access Token and Refresh Token for later use
        $accessToken = $tokenResponse.access_token
        #$refreshToken = $tokenResponse.refresh_token

        #Connect-AzureAD -AadAccessToken $accessToken -AccountId $AdminUPN
    }else{
        Write-Host "Script stopped, device code flow login not completed"
        Exit
    }

    Connect-AzureAD
}
#endregion

#region create groups
New-AFAzureADGroup -Name $SynchronizationServiceAccountsGroup
New-AFAzureADGroup -Name $EmergencyAccessAccountsGroup
#create dynamic group if not yet existing
$Group_AADP2 = Get-AzureADGroup -SearchString $AADP2Group
if(-not $Group_AADP2){
    $MembershipRule = 'user.assignedPlans -any (assignedPlan.servicePlanId -eq "eec0eb4f-6444-4f95-aba0-50c24d67f998" -and assignedPlan.capabilityStatus -eq "Enabled")'
    New-AzureADMSGroup -DisplayName $AADP2Group -MailEnabled $False -MailNickName "NotSet" -SecurityEnabled $True -GroupTypes "DynamicMembership" -MembershipRule $MembershipRule -MembershipRuleProcessingState "On"
}
#endregion

#region get group ObjectIds
$Group_SynchronizationServiceAccounts = Get-AzureADGroup -SearchString $SynchronizationServiceAccountsGroup
$Group_EmergencyAccessAccounts = Get-AzureADGroup -SearchString $EmergencyAccessAccountsGroup
$Group_AADP2 = Get-AzureADGroup -SearchString $AADP2Group

$ObjectID_SynchronizationServiceAccounts = $Group_SynchronizationServiceAccounts.ObjectId
$ObjectID_EmergencyAccessAccounts = $Group_EmergencyAccessAccounts.ObjectID
$ObjectID_AADP2 = $Group_AADP2.ObjectID
#endregion

#region import policy templates
$Templates = Get-ChildItem -Path $PoliciesFolder
$Policies = foreach($Item in $Templates){
    $Policy = Get-Content -Raw -Path $Item.FullName | ConvertFrom-Json
    $Policy
}
#endregion

#region create or update policies
$Counter = 1
foreach($Policy in $Policies){
    $PrefixAndNumber = $Prefix + ("{0:00}" -f $Counter)

    #Create exlusion group
    $DisplayName_Exclusion = $ExclusionGroupsPrefix + $PrefixAndNumber
    $Group = Get-AzureADGroup -SearchString $DisplayName_Exclusion
    if(-not $Group){
        New-AzureADGroup -DisplayName $DisplayName_Exclusion -MailEnabled $false -SecurityEnabled $true -MailNickName "NotSet" 
    }

    #Get exclusion group ObjectId
    $Group_Exclusion = Get-AzureADGroup -SearchString $DisplayName_Exclusion
    $ObjectID_Exclusion = $Group_Exclusion.ObjectId

    #REPLACEMENTS
    #Add prefix to DisplayName
    $Policy.displayName = $Policy.displayName.Replace("<PREFIX>",$PrefixAndNumber)

    if($Policy.conditions.users.includeGroups){
        [System.Collections.ArrayList]$includeGroups = $Policy.conditions.users.includeGroups
        
        #Replace Conditional_Access_AADP2
        if($includeGroups.Contains("<AADP2Group>")){
            $includeGroups.Add($ObjectID_AADP2)
            $includeGroups.Remove("<AADP2Group>")
        }

        $Policy.conditions.users.includeGroups = $includeGroups
    }

    if($Policy.conditions.users.excludeGroups){
        [System.Collections.ArrayList]$excludeGroups = $Policy.conditions.users.excludeGroups

        #Replace Conditional_Access_Exclusion
        if($excludeGroups.Contains("<ExclusionGroup>")){
            $excludeGroups.Add($ObjectID_Exclusion)
            $excludeGroups.Remove("<ExclusionGroup>")
        }
        #Replace Conditional_Access_Exclusion_SynchronizationServiceAccounts
        if($excludeGroups.Contains("<SynchronizationServiceAccountsGroup>")){
            $excludeGroups.Add($ObjectID_SynchronizationServiceAccounts)
            $excludeGroups.Remove("<SynchronizationServiceAccountsGroup>")
        }
        #Replace Conditional_Access_Exclusion_EmergencyAccessAccounts
        if($excludeGroups.Contains("<EmergencyAccessAccountsGroup>")){
            $excludeGroups.Add($ObjectID_EmergencyAccessAccounts)
            $excludeGroups.Remove("<EmergencyAccessAccountsGroup>")
        }

        $Policy.conditions.users.excludeGroups = $excludeGroups
    }

    $requestBody = $Policy | ConvertTo-Json -Depth 3

    #Decide if update or create
    $DisplayName = $Policy.displayName.Split("-",2)[1].Trim()
    $Result = Get-GraphConditionalAccessPolicy -accessToken $accessToken -DisplayName $DisplayName
    if($Result.value.Count -eq 1){
        Write-Host "Update $DisplayName" -ForegroundColor Blue
        Set-GraphConditionalAccessPolicy -requestBody $requestBody -accessToken $accessToken -Id $Result.value[0].id
    }else{
        Write-Host "Creating $DisplayName" -ForegroundColor Green
        New-GraphConditionalAccessPolicy -requestBody $requestBody -accessToken $accessToken
    }

    Start-Sleep -Seconds 2
    
    $Counter ++
}
#endregion