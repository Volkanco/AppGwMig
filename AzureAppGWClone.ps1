<#PSScriptInfo

.VERSION 1.0.1

.GUID 2ea868dc-27b4-4803-aefa-0c152256a639

.AUTHOR Microsoft Corporation

.COMPANYNAME Microsoft Corporation

.COPYRIGHT Microsoft Corporation. All rights reserved.

.TAGS Azure, Az, ApplicationGateway, AzNetworking

.RELEASENOTES 
1.0.1
 -- Minor logging improvements.

1.0.0
 -- Create a v2 application gateway from a v1 application gateway
 -- If the v1 gateway has SSL backend, the backend SSL validations will be relaxed
 -- If the v1 gateway has SSL listeners, the certificates will be copied over from v1 gateway to v2 gateway given user has read permissions on the v1 gateway.
#>

<#

.SYNOPSIS
AppGateway v1 -> v2 Clone

.DESCRIPTION
This script will help you create a V2 sku application gateway with the same configuration as your V1 sku application gateway. The script will also add user tags to copy listener SSL Certificates and Relax HTTPS Backend Validations.

.PARAMETER ResourceId
Application Gateway ResourceId, like "/subscriptions/<your-subscriptionId>/resourceGroups/<v1-app-gw-rgname>/providers/Microsoft.Network/applicationGateways/<v1-app-gw-name>"
.PARAMETER SubnetAddressRange
The subnet address in CIDR notation, where you want to deploy v2 application gateway (Make sure the subnet is empty or contains only application gateway standard_v2/waf_v2 sku resources). 
.PARAMETER AppGwName
Name of v2 app gateway, default will be <v1-app-gw-name>_migrated
.PARAMETER AppGwResourceGroupName
Name of resource group where you want v2 application gateway resources to be created (default value will be <v1-app-gw-rgname>)
.PARAMETER PrivateIpAddress
Private Ip address to be assigned to v2 app gateway.
.PARAMETER ValidateBackendHealth
Post migration validation by comparing ApplicationGatewayBackendHealth response.
.PARAMETER PublicIpResourceId
Public Ip Address resourceId (if already exists) can be attached to application gateway. If no input is given script will create a public ip resource for you in the same resource group
.PARAMETER DisableAutoscale
Disable autoscale configuration for app gateway v2 instances
.PARAMETER WafPolicyName
Name of the waf policy, that will be created from WAF V1 Configuration and will be attached to WAF v2 gateway.

.EXAMPLE
.\clone.ps1 -ResourceId "/subscriptions/<your-sub-id>/resourceGroups/<your-rg>/providers/Microsoft.Network/applicationGateways/<v1AppGatewayName>" -SubnetAddressRange <CIDR like 10.0.3.0/24>

.INPUTS
String

.OUTPUTS
PSApplicationGateway

.LINK
https://aka.ms/appgwcloningdoc
https://docs.microsoft.com/en-us/azure/application-gateway/
#>

#Requires -Module Az.Network
#Requires -Module Az.Compute
#Requires -Module Az.Resources
Param([Parameter(Mandatory = $True)][string] $ResourceId,
[Parameter(Mandatory = $True)][string] $SubnetAddressRange,
[string] $AppGwName,
[string] $AppGwResourceGroupName,
[string] $PublicIpResourceId,
[string] $PrivateIpAddress,
[switch] $ValidateBackendHealth,
[switch] $DisableAutoscale,
[string] $WafPolicyName
)

if (!(Get-Module -ListAvailable -Name Az.Network)) 
{
    Write-Error ("You need 'Az' module to proceed. Az is a new cross-platform PowerShell module that will replace AzureRM. You can install this module by running 'Install-Module Az' in an elevated PowerShell prompt.")
    Write-Warning ("If you see error 'AzureRM.Profile already loaded. Az and AzureRM modules cannot be imported in the same session', You would need to close the current session and start new one.")
    exit
}

Function Private:ScriptVersionCheck()
{
    $InstalledScriptVersion = (Get-InstalledScript -Name 'AzureAppGWClone' -ErrorAction SilentlyContinue).Version
    $LatestScriptVersion = (Find-Script -Name 'AzureAppGWClone'-ErrorAction SilentlyContinue).Version

    if(!$InstalledScriptVersion)
    {
        Write-Warning("You have manually downloaded the clone script. The stable version of this script is $LatestScriptVersion, which contains critical fixes and bugs that may not be present in the version you have installed. It is recommended to use the stable version. You can find more information about the currently installed version and how to download the stable version at https://aka.ms/cloningscriptdownload")

        $confirmation = Read-Host "Are you sure you want to proceed? Press 'y' to continue, any other key for exiting"

        if ($confirmation -ne 'y')
        {
            exit;
        }
    }
    else
    {
        if($InstalledScriptVersion -ne $LatestScriptVersion)
        {
            Write-Warning("You have installed the clone script version : $InstalledScriptVersion. It is recommended to use the stable version of the script : $LatestScriptVersion. This version contains critical bug fixes that may not be present in the version you are currently using. You can install the stable version by running 'UnInstall-Script -Name 'AzureAppGWClone' -Force; Install-Script -Name 'AzureAppGWClone' -RequiredVersion $LatestScriptVersion -Force'")

            $confirmation = Read-Host "Are you sure you want to proceed? Press 'y' to continue, any other key for exiting"

            if ($confirmation -ne 'y')
            {
                exit;
            }
        }
    }
}

ScriptVersionCheck

$sw = [Diagnostics.Stopwatch]::StartNew()

#Validating resourceId
$matchResponse = $resourceId -match "/subscriptions/(.*?)/resourceGroups/"
if(!$matchResponse)
{
    Write-Warning("Invalid ResourceId format $resourceId.")
    exit
}

#Validating set-context succeess
$subscription = $matches[1]
$context = Set-AzContext -Subscription $subscription -ErrorVariable contextFailure
if ($contextFailure)
{
    Write-Warning("Unable to set subscription $subscription in context. Please retry again")
    exit
}

$resource = Get-AzResource -ResourceId $resourceId -ErrorVariable getResourceFailure -ErrorAction SilentlyContinue

# Validating Get-Resource
if($getResourceFailure -or !$resource)
{
    Write-Warning("Unable to get resource for $resourceId. Please retry again")
    exit
}

$resourcegroup = $resource.ResourceGroupName
$location = $resource.Location
$V1AppGwName = $resource.Name
$appendString = "_migrated"
$existingResourceIdFormat = "/resourceGroups/$resourcegroup/providers/Microsoft.Network/applicationGateways/$V1AppGwName/"
$newResourceIdFormat = "/resourceGroups/ResourceGroupNotSet/providers/Microsoft.Network/applicationGateways/ApplicationGatewayNameNotSet/"
$dict = @{}
$migrationCompleted = $false
$isNewSubnetCreated = $false
$isNewIPCreated = $false
$isWafPolicyCreated = $false
$isNewResourceGroupCreated = $false
$pip = $null
if ( !$AppGwName )
{ 
    $AppGwName = $V1AppGwName + $appendString
}

if ( !$AppGwResourceGroupName )
{
    $AppGwResourceGroupName = $resourcegroup
}
else
{
    # Create resource group if doesn't exist
    Get-AzResourceGroup -Name $AppGwResourceGroupName -ErrorVariable notPresent -ErrorAction SilentlyContinue
    if ($notPresent)
    {
        $isNewResourceGroupCreated = $true
        New-AzResourceGroup -Name $AppGwResourceGroupName -Location $location
    }
}

$AppGw = Get-AzApplicationGateway -Name $V1AppGwName -ResourceGroupName $resourcegroup -ErrorVariable getAppGwResourceFailure -ErrorAction SilentlyContinue

# Validating Get-AppGwResource Failure
if($getAppGwResourceFailure -or !$AppGw)
{
    Write-Warning("Unable to get application gateway resource for $resourceId. Please retry again")
    exit
}

if ($AppGw.ProvisioningState -ne "Succeeded")
{
    Write-Warning ("Application gateway provisioning state should be Succeeded to run this operation")
    exit
}

Write-Host "Creating AppGw with Name $AppGwName . . ."

# cleanup resources
Function Private:Cleanup()
{
    if ($newAppGw)
    {
        $AppGwName = $newAppGw.Name
        Write-Host ("Removing AppGw $AppGwName")
        Remove-AzApplicationGateway -Name $newAppGw.Name -ResourceGroupName $AppGwResourceGroupName -Force
    }
    if ($isNewIPCreated)
    {
        Write-Host ("Removing IP $PublicIpResourceName")
        Remove-AzPublicIpAddress -Name $PublicIpResourceName -ResourceGroupName $AppGwResourceGroupName -Force -ErrorAction SilentlyContinue
    }
    if ($isWafPolicyCreated)
    {
        Write-Host ("Removing WAF Policy $WafPolicyName")
        Remove-AzApplicationGatewayFirewallPolicy -Name $WafPolicyName -ResourceGroupName $AppGwResourceGroupName -Force -ErrorAction SilentlyContinue
    }
    if($isNewResourceGroupCreated)
    {
        Write-Host ("ResourceGroup $AppGwResourceGroupName is not deleted. Please clean up the resource group after verifying that resources inside resouce group are not used or not needed.")
    }
    if ($isNewSubnetCreated)
    {
        Write-Host ("Removing subnet $subnetname")
        $vnet = Remove-AzVirtualNetworkSubnetConfig -Name $subnetname -VirtualNetwork $vnet | Set-AzVirtualNetwork
    }

    Write-Host ("Resource Cleanup Finished")
    exit
}

Function Private:GetPrivateFrontendIp()
{
    if (!$PrivateIpAddress)
    {
        $SubnetStartAddress = [ipaddress]$SubnetAddressRange.Split("/")[0]
        # select an ip address beyond reserved Ip address range
        $SubnetSize = [int][math]::pow( 2, (32 - [int]$SubnetAddressRange.Split("/")[1]))
        $AddressOffset = (Get-Random -Minimum 4 -Maximum ($SubnetSize - 2))
        $IpAddressRangeToAdd = [ipaddress]"$AddressOffset"
        return New-Object System.Net.IPAddress($SubnetStartAddress.Address + $IpAddressRangeToAdd.Address)
    }
    else 
    {
        return [ipaddress]$PrivateIPAddress
    }
}

Function Private:ValidateInput()
{
    if (!$appgw -or !($appgw.sku.Tier -in "Standard","WAF"))
    {
        Write-Warning("Could not detect any V1 ('Standard' or 'WAF') resource as per your input parameters. Please double check input parameters.")
        exit
    }

    #check if gateway WebApplicationFirewallConfiguration is having owasp rule set version 2.2.9
    if ($appgw.WebApplicationFirewallConfiguration)
    {
        if ($appgw.WebApplicationFirewallConfiguration.RuleSetType -eq "OWASP" -and $appgw.WebApplicationFirewallConfiguration.RuleSetVersion -eq "2.2.9")
        {
            Write-Error ("The WAF V1 gateway you're attempting to migrate currently uses CRS version 2.2.9, which is no longer supported. To proceed with the migration, upgrade your WAF gateway to CRS version 3.0 or later.")
            exit
        }
    }

}

Function Private:GetApplicationGatewaySku($gwSkuTier)
{
    if ($gwSkuTier -EQ "Standard")
    { 
        return New-AzApplicationGatewaySku -Name Standard_v2 -Tier Standard_v2
    }
    else
    {
        return New-AzApplicationGatewaySku -Name WAF_v2 -Tier WAF_v2
    }
}

Function Private:GetCapacityUnits($AppgwSku)
{
    # Min/Max Max Capacity for Autoscale
    $LowestPossibleCapacity = 2
    $HighestPossibleCapacity = 125
    $MinCapacity = 0
    $MaxCapacity = 0
    $currentInstanceCount = [int]($AppgwSku.Capacity)

    switch($AppgwSku.Name)
    {
        {$_ -in "Standard_Small"} { 
            $MinCapacity = [math]::floor($currentInstanceCount/2); 
            $MaxCapacity = $currentInstanceCount; 
        }
        {$_ -in "WAF_Medium","Standard_Medium"} { 
            $MinCapacity = $currentInstanceCount; 
            $MaxCapacity = [math]::ceiling(1.5*$currentInstanceCount); 
        }
        {$_ -in "WAF_Large","Standard_Large"} { 
            $MinCapacity = $currentInstanceCount; 
            $MaxCapacity = [math]::ceiling(4.0*$currentInstanceCount); 
        }
        {$_ -in "Standard_Small_V2"} { 
            $MinCapacity = $currentInstanceCount; 
            $MaxCapacity = $currentInstanceCount; 
        }
        {$_ -in "WAF_Medium_V2","Standard_Medium_V2"} { 
            $MinCapacity = $currentInstanceCount;
            $MaxCapacity = [math]::ceiling(2.0*$currentInstanceCount); 
        }
        {$_ -in "WAF_Large_V2","Standard_Large_V2"} { 
            $MinCapacity = $currentInstanceCount; 
            $MaxCapacity = [math]::ceiling(4.0*$currentInstanceCount); 
        }
    }

    if ($MinCapacity -LT $LowestPossibleCapacity)
    {
        $MinCapacity = $LowestPossibleCapacity
    }

    if ($MaxCapacity -GT $HighestPossibleCapacity)
    {
        Write-Warning ("Your current V1 ('Standard' or 'WAF') has a large number of instances that exceed the limit for provisioning equivalently scaled V2 instances using our V1->V2 SKU conversion factors. Please consider reducing the number of instances for your V1 Application Gateway/WAF resource, or contact Azure Support to increase your subscription limits.")
        exit
    }
    elseif ($MaxCapacity -LT $LowestPossibleCapacity)
    {
        $MaxCapacity = $LowestPossibleCapacity
    }

    return 0, $MaxCapacity
}

$AttachVmNetworkInterface = {
    param($nicName, $rgname, $BackendPoolsToAdd)
    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $rgname -ErrorAction SilentlyContinue
    if ($nic)
    {
        $nicipconfig = Get-AzNetworkInterfaceIpConfig -NetworkInterface $nic | Where-Object { $_.Primary -eq $True }
        foreach($backendPool in $BackendPoolsToAdd){
            $BackendPoolToAdd = New-AzApplicationGatewayBackendAddressPool -Name $backendPool.Name
            $BackendPoolToAdd.Id = $backendPool.id
            $nicipconfig | ForEach-Object { if(!$_.ApplicationGatewayBackendAddressPools.id.Contains($BackendPoolToAdd.id)) {
                $_.ApplicationGatewayBackendAddressPools.Add($BackendPoolToAdd) 
            } }
        }
        $retryCount = 0
        do
        {
            Start-Sleep -s ($retryCount*5)
            $newnic = Set-AzNetworkInterface -NetworkInterface $nic
            $retryCount++
        }while(($retryCount -LT 3) -and !$newnic)

        if($newnic)
        {
            Write-Host("VM Nic '$($nicName)' was added to backend pool.")
            return $true
        }
    }
    Write-Error("VM Nic '$($nicName)' could not be successfully added to the backend pool. Please retry the script after some time")
    return $false
}

$AttachVmssNetworkInterface = {
    param($vmssName, $nicList, $rgname, $Instances)
    $Instances = $Instances | Select-Object -Unique
    $vmss = Get-AzVmss -VMScaleSetName $vmssName -ResourceGroupName $rgname
    
    foreach ($nic in $nicList.Keys) {
        $backendPoolsToAdd = $nicList[$nic]
        $nicipconfig = $vmss.VirtualMachineProfile.NetworkProfile.NetworkInterfaceConfigurations `
        | Where-Object { $_.Name -eq $nic } `
        | Select-Object -ExpandProperty IpConfigurations | Where-Object { $_.Primary -eq $True }
        $nicipconfig | ForEach-Object {
            foreach ($backendPool in $backendPoolsToAdd) {
                if (!$_.ApplicationGatewayBackendAddressPools.id.Contains($backendPool.id)) {
                    $_.ApplicationGatewayBackendAddressPools.Add($backendPool.id)
                }
            }
        }
    }
    
    Update-AzVmss -VirtualMachineScaleSet $vmss -Name $vmssName -ResourceGroupName $rgname -ErrorVariable errorDetails
    if ($errorDetails) {
        Write-Error ("Failed to migrate backend pool(s) associated to vmss '$($vmssName)'")
        return $false
    }

    Write-Host("Virtual machine scale set '$($vmssName)' was added to backend pool.")
    if (!$errorDetails -and ($vmss.UpgradePolicy.Mode -EQ "Manual") )
    {
        Write-Host ("Upgrading all the instances of '$($vmssName)' for this change to work.")
        foreach($instance in $Instances){
            $updateStatus = Update-AzVmssInstance -ResourceGroupName $rgname -VMScaleSetName $vmssName -InstanceId $instance
            if($updateStatus.Error)
            {
                Write-Warning "Failed to update instance : ", $instance, "in vmss : ", $vmssName, ". Users will need to manually upgrade their vmss instances, or as per their vmss upgrade policy"
            }
        }
        return $true
    }
    return $true
}

Function Private:GetAvailabilityZoneMappings {
    try 
    {
        $response = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$subscription/Providers/Microsoft.Compute?api-version=2017-08-01" 
        # Check if the response contains an error
        if ($response.StatusCode -ne 200) {
            Write-Error "Failed to retrieve availability zone mappings, statuscode is $($response.StatusCode). Please try again later."
            exit
        } else {
            $data = ($response.Content | ConvertFrom-Json)
            # Get zoneMappings for virtualMachineScaleSets
            $zoneMappings = $data.resourceTypes | Where-Object { $_.resourceType -eq "virtualMachineScaleSets" } | Select-Object -ExpandProperty zoneMappings
            $zoneMappingForLocation = $zoneMappings | Where-Object { $_.location.Replace(' ','') -eq $location }
            $logicalZones = $zoneMappingForLocation.zones
            return $logicalZones
        }
    }
    catch
    {
        Write-Error "Failed to retrieve availability zone mappings. Please try again later."
        exit
    }
}

Function GetMatchingApplicationGatewayWAFRuleSet {
    param (
        [array]$availableWAFRuleSets,
        [string]$appgwRuleSetType,
        [string]$appgwRuleSetVersion
    )

    $matchingRuleSet = $availableWAFRuleSets.Value | Where-Object { $_.RuleSetType -eq $appgwRuleSetType -and $_.RuleSetVersion -eq $appgwRuleSetVersion }
    return $matchingRuleSet
}

Function GetRuleGroupRuleIdsFromWAFRuleSet {
    param (
        [object]$wafRuleSet,
        [string]$ruleGroupName
    )

    $matchingRuleGroup = $wafRuleSet.RuleGroups | Where-Object { $_.RuleGroupName -eq $ruleGroupName }
    return $matchingRuleGroup.Rules.RuleId
}

Function Private:CreateNewWAFPolicy () {
    #used in case of disabled RuleGroup case
    $avalilableWAFRuleSets = Get-AzApplicationGatewayAvailableWafRuleSets
    $appgwRuleSetType = $appgw.WebApplicationFirewallConfiguration.RuleSetType
    $appgwRuleSetVersion = $appgw.WebApplicationFirewallConfiguration.RuleSetVersion
    $ruleSet = GetMatchingApplicationGatewayWAFRuleSet $avalilableWAFRuleSets $appgwRuleSetType $appgwRuleSetVersion

    # Get the managedRule and PolicySettings
    $managedRule = New-AzApplicationGatewayFirewallPolicyManagedRule
    $policySetting = New-AzApplicationGatewayFirewallPolicySetting
    if ($appgw.WebApplicationFirewallConfiguration) {
        $ruleGroupOverrides = [System.Collections.ArrayList]@()
        if ($appgw.WebApplicationFirewallConfiguration.DisabledRuleGroups) {
            foreach ($disabled in $appgw.WebApplicationFirewallConfiguration.DisabledRuleGroups) {
                $rules = [System.Collections.ArrayList]@()
                if ($disabled.Rules.Count -gt 0) {
                    foreach ($rule in $disabled.Rules) {
                        $ruleOverride = New-AzApplicationGatewayFirewallPolicyManagedRuleOverride -RuleId $rule
                        $_ = $rules.Add($ruleOverride)
                    }
                }
                #Disabled RuleGroup case
                elseif ($disabled.Rules.Count -eq 0)
                {
                    $disabledRuleGroupRuleId = GetRuleGroupRuleIdsFromWAFRuleSet $ruleSet $disabled.RuleGroupName
                    foreach ($ruleId in $disabledRuleGroupRuleId) {
                        $ruleOverride = New-AzApplicationGatewayFirewallPolicyManagedRuleOverride -RuleId $ruleId
                        $_ = $rules.Add($ruleOverride)
                    }
                }
                $ruleGroupOverride = New-AzApplicationGatewayFirewallPolicyManagedRuleGroupOverride -RuleGroupName $disabled.RuleGroupName -Rule $rules
                $_ = $ruleGroupOverrides.Add($ruleGroupOverride)
            }
        }

        $managedRuleSet = New-AzApplicationGatewayFirewallPolicyManagedRuleSet -RuleSetType $appgw.WebApplicationFirewallConfiguration.RuleSetType -RuleSetVersion $appgw.WebApplicationFirewallConfiguration.RuleSetVersion 
        if ($ruleGroupOverrides.Count -ne 0) {
            $managedRuleSet = New-AzApplicationGatewayFirewallPolicyManagedRuleSet -RuleSetType $appgw.WebApplicationFirewallConfiguration.RuleSetType -RuleSetVersion $appgw.WebApplicationFirewallConfiguration.RuleSetVersion -RuleGroupOverride $ruleGroupOverrides
        }
    
        $exclusions = [System.Collections.ArrayList]@()  
        if ($appgw.WebApplicationFirewallConfiguration.Exclusions) {
            foreach ($excl in $appgw.WebApplicationFirewallConfiguration.Exclusions) {
                if ($excl.MatchVariable -and $excl.SelectorMatchOperator -and $excl.Selector) {
                    $exclusionEntry = New-AzApplicationGatewayFirewallPolicyExclusion -MatchVariable  $excl.MatchVariable -SelectorMatchOperator $excl.SelectorMatchOperator -Selector $excl.Selector
                    $_ = $exclusions.Add($exclusionEntry)
                }

                if ($excl.MatchVariable -and !$excl.SelectorMatchOperator -and !$excl.Selector) {
                    # Equals Any exclusion
                    $exclusionEntry = New-AzApplicationGatewayFirewallPolicyExclusion -MatchVariable  $excl.MatchVariable -SelectorMatchOperator "EqualsAny" -Selector "*"
                    $_ = $exclusions.Add($exclusionEntry)
                }
            }
        }
    
        $managedRule = New-AzApplicationGatewayFirewallPolicyManagedRule -ManagedRuleSet $managedRuleSet
        $exclCount = $exclusions.Count
        if ($exclCount -ne 0) {
            $managedRule = New-AzApplicationGatewayFirewallPolicyManagedRule -ManagedRuleSet $managedRuleSet -Exclusion $exclusions
        }

        $policySetting = New-AzApplicationGatewayFirewallPolicySetting -MaxFileUploadInMb $appgw.WebApplicationFirewallConfiguration.FileUploadLimitInMb -MaxRequestBodySizeInKb $appgw.WebApplicationFirewallConfiguration.MaxRequestBodySizeInKb -Mode Detection -State Disabled
        if ($appgw.WebApplicationFirewallConfiguration.FirewallMode -eq "Prevention") {
            $policySetting.Mode = "Prevention"
        }

        if ($appgw.WebApplicationFirewallConfiguration.Enabled) {
            $policySetting.State = "Enabled"
        }

        $policySetting.RequestBodyCheck = $appgw.WebApplicationFirewallConfiguration.RequestBodyCheck;
    }
    else
    {
        Write-Warning "This Application Gateway V1 does not have a Web Application Firewall (WAF) configuration attached. A WAF policy with default properties will be created and attached to the V2 application gateway, and its state will be set to disabled."
        $policySetting = New-AzApplicationGatewayFirewallPolicySetting -MaxFileUploadInMb 100 -MaxRequestBodySizeInKb 128 -Mode Detection -State Disabled
        $policySetting.RequestBodyCheck = $true
        $policySetting.RequestBodyInspectLimitInKB = 128
        $policySetting.FileUploadEnforcement = $true
        $policySetting.RequestBodyEnforcement = $true

        $managedRuleSet = New-AzApplicationGatewayFirewallPolicyManagedRuleSet -RuleSetType "Microsoft_DefaultRuleSet" -RuleSetVersion "2.1"
        $managedRule = New-AzApplicationGatewayFirewallPolicyManagedRule -ManagedRuleSet $managedRuleSet
    }

    $wafPolicy = New-AzApplicationGatewayFirewallPolicy -Name $wafPolicyName -ResourceGroupName $AppGwResourceGroupName -PolicySetting $policySetting -ManagedRule $managedRule -Location $appgw.Location
    

    if (!$wafPolicy) {
        exit;
    }
    Write-Host "firewallPolicy: $wafPolicyName has been created successfully"
    return $wafPolicy
}

ValidateInput

# Get Availability Zones
$AvailabilityZones = GetAvailabilityZoneMappings
# Deploy AppGw in all zones supported by the region. $AvailabilityZones will be null be region does not support AZs
$appgwDeploymentZones = $AvailabilityZones
# Deploy Public IP in all zones supported by the region. $AvailabilityZones will be null be region does not support AZs
$publicIpDeploymentZones = $AvailabilityZones

try{
    #define sku & autoscale
    $sku = GetApplicationGatewaySku($AppGw.Sku.Tier)

    $capacity = GetCapacityUnits($AppGw.Sku)
    if ($disableAutoscale)
    {   
        $sku.Capacity = $capacity[1]
    }
    else
    {
        $autoscaleConfig = New-AzApplicationGatewayAutoscaleConfiguration -MinCapacity $capacity[0] -MaxCapacity $capacity[1]
    }
    
    # create subnet with appropiate nsg
    $GatewayConfig = Get-AzApplicationGatewayIPConfiguration -ApplicationGateway $AppGw
    $matchResponse = $GatewayConfig.subnet.id -match "/resourceGroups/(.*?)/.*/virtualNetworks/(.*?)/subnets/(.*)"

    $vnetname = $matches[2]
    $vnet = Get-AzvirtualNetwork -Name $vnetname -ResourceGroupName $matches[1]

    if(!$vnet)
    {
        Write-Warning ("Vnet $vnetname associated with $resourceId is not found. This is not expected. Please try again later.")
        return
    }

    $V1Subnet = Get-AzVirtualNetworkSubnetConfig -Name $matches[3] -VirtualNetwork $vnet

    if(!$V1Subnet)
    {
        Write-Warning ("Subnet associated with $resourceId is not found. This is not expected. Please try again later.")
        return
    }

    $agv2Subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet | Where-Object { $_.AddressPrefix -Match $SubnetAddressRange }

    if( $null -eq $agv2Subnet )
    {
        $subnetname = $AppGwName + "Subnet"

        $isNetworkIsolationFlagRegistered = Get-AzProviderFeature -ProviderNamespace "Microsoft.Network" -FeatureName "EnableApplicationGatewayNetworkIsolation" | Where-Object { $_.RegistrationState -eq "Registered" }

        if($isNetworkIsolationFlagRegistered)
        {
            Write-Host ("Network isolation is enabled. Creating a new subnet with delegation to Application Gateway.")
            $delegation = New-AzDelegation -Name "delegation" -ServiceName "Microsoft.Network/applicationGateways"
            $vnet = Add-AzVirtualNetworkSubnetConfig -Name $subnetname -AddressPrefix $SubnetAddressRange -VirtualNetwork $vnet -NetworkSecurityGroupId $V1Subnet.NetworkSecurityGroup.Id -Delegation $delegation
        }
        else
        {
            Write-Host ("Network Isolation Flag is Not enabled. Creating Non Delegated Subnet.")
            $vnet = Add-AzVirtualNetworkSubnetConfig -Name $subnetname -AddressPrefix $SubnetAddressRange -VirtualNetwork $vnet -NetworkSecurityGroupId $V1Subnet.NetworkSecurityGroup.Id
        }
        
        $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
        
        if (!$vnet)
        {
            Write-Warning ("Please check if you have provided the correct SubnetAddressRange")
            return
        }

        $agv2Subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetname -VirtualNetwork $vnet
        $isNewSubnetCreated = $true
        Write-Host ("Created Subnet $($agv2Subnet.Name) for V2 Application Gateway. Address Prefix : $SubnetAddressRange")
    }
    elseif ($agv2Subnet.AddressPrefix -eq $V1Subnet.AddressPrefix)
    {
        Write-Warning ("Provided SubnetAddressRange matches with V1 Application Gateway Subnet. Please provide a different SubnetAddressRange and retry.")
        return
    }

    if (!$agv2Subnet)
    {
        Write-Warning ("Failed to create Subnet. This might happen if VNet resource is in failed state. Please correct that and retry execution")
        return
    }
    else
    {
        Write-Host ("Using Subnet: $($agv2Subnet.Name)")
    }

    # Create FrontendIpConfig
    if ($PublicIpResourceId)
    {
        $PublicIpResource = Get-AzResource -ResourceId $PublicIpResourceId -ErrorAction SilentlyContinue
        if($PublicIpResource)
        {
            $PublicIpResourceName = $PublicIpResource.Name
            $matchResponse = $PublicIpResourceId -match "/resourceGroups/(.*?)/providers"
            $pip = Get-AzPublicIpAddress -Name $PublicIpResourceName -ResourceGroupName $matches[1] -ErrorAction SilentlyContinue

            if(!$pip)
            {
                Write-Warning ("Failed to get Public Ip Resource with name $PublicIpResourceName. Please ensure that provided Public Ip resource exists")
                return
            }
        }
        else
        {
            Write-Warning ("Failed to get Public Ip Resource with Id $PublicIpResourceId. Please ensure that provided Public Ip resource exists")
            return
        }
    }

    # Only create public IP if needed
    $fip = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayFrontendIPConfiguration]

    # Check frontend IP configs on v1 App Gateway
    $publicFp  = Get-AzApplicationGatewayFrontendIPConfig -ApplicationGateway $AppGw | Where-Object { $_.PublicIPAddress -ne $null }
    $privateFp = Get-AzApplicationGatewayFrontendIPConfig -ApplicationGateway $AppGw | Where-Object { $_.PublicIPAddress -eq $null }

    # Create Public IP if needed ---
    if ($publicFp -and (-not $pip)) {
        $PublicIpResourceName = $AppGwName + "-IP"
        $getPip = Get-AzPublicIpAddress -ResourceGroupName $AppGwResourceGroupName -name $PublicIpResourceName -ErrorAction SilentlyContinue

        if($getPip)
        {
            Write-Warning ("Public Ip Resource $($getPip.Id) already exists. Please delete it or specify a PublicIpResourceId.")
            return
        }

        $pip = New-AzPublicIpAddress -ResourceGroupName $AppGwResourceGroupName -name $PublicIpResourceName -location $location -AllocationMethod "Static" -Sku Standard -Zone $publicIpDeploymentZones -Force
        $isNewIPCreated = $true
    }

    # Add Public Frontend IP Config
    if ($publicFp) {
        if ($publicFp.Count -ne 1) {
            Write-Error ("Multiple Public FrontendIP are not supported for AppGw v2.")
            exit
        }

        $fipName = $publicFp.Name
        $fip.Add((New-AzApplicationGatewayFrontendIPConfig -Name $fipName -PublicIPAddress $pip))
        $publicFp | ForEach-Object { $dict[$_.Id] = $fip[-1] }
    }

    # Add Private Frontend IP Config
    if ($privateFp) {
        $privateIp = (GetPrivateFrontendIp).IPAddressToString
        $fip.Add((New-AzApplicationGatewayFrontendIPConfig -Name $privateFp.Name -PrivateIPAddress $privateIp -Subnet $agv2Subnet))
        $privateFp | ForEach-Object { $dict[$_.Id] = $fip[-1] }
    }

    if (!$fip -or $fip.Count -eq 0) {
        Write-Warning ("Failed to create FrontendIpConfig. This should not have happened ideally. Please retry execution after sometime.")
        return
    }
    else {
        Write-Host ("Created FrontendIpConfiguration(s)")
    }

    # Create Frontend ports
    $FrontEndPorts = Get-AzApplicationGatewayFrontendPort -ApplicationGateway $AppGw 
    $FrontEndPorts | ForEach-Object {$dict[$_.Id] = $_;$_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat); }

    # Create gatewayIpConfig
    $GatewayConfig = Get-AzApplicationGatewayIPConfiguration -ApplicationGateway $AppGw
    $gwIPconfig = New-AzApplicationGatewayIPConfiguration -Name $GatewayConfig.Name -Subnet $agv2Subnet
    if (!$gwIPconfig)
    {
        Write-Warning ("Failed to create GatewayIpConfig. This should not have happened ideally. Please retry execution after sometime.")
        return
    }
    else
    {
        Write-Host ("Created GatewayIpConfiguration")
    }

    # Create probes
    $probes = Get-AzApplicationGatewayProbeConfig -ApplicationGateway $appgw
    $probes | ForEach-Object { $dict[$_.Id] = $_; $_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat); }
    Write-Host ("Created Health Probes")

    # Create BackendPools
    $BackendPools = Get-AzApplicationGatewayBackendAddressPool -ApplicationGateway $AppGw
    $BackendPools | ForEach-Object {$dict[$_.Id] = $_; $_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat); }
    Write-Host ("Created Backend Pool")
    
    if (!$appgw.Tag) { $appgw.Tag = @{} }

    # Backend http settings
    $atleastOneHTTPSBackend = $false;
    $SettingsList  = Get-AzApplicationGatewayBackendHttpSetting -ApplicationGateway $AppGw
    $SettingsList | ForEach-Object { 
        $_.AuthenticationCertificates = $null
        if ($_.Protocol -EQ "https")
        {
            $atleastOneHTTPSBackend = $true
            # do nothing if protocol is https, user tag will be added and NRP with set the right properties based on it
        }
        if($_.Probe -and $dict.ContainsKey($_.Probe.Id)) { $_.Probe = $dict[$_.Probe.Id]; }
        $dict[$_.Id] = $_;
        $_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat);
    }
    Write-Host ("Created Backend HttpSettings")
    if ($atleastOneHTTPSBackend) 
    { 
        Write-Host ("Added RelaxBackendSSLCertificateValidations tag since atleast one Http Backend setting with HTTPS Protocol exist.")
        $appgw.Tag.Add("RelaxBackendSSLCertificateValidations", "true")
    }

    $SslCertificates = Get-AzApplicationGatewaySslCertificate -ApplicationGateway $appgw
    $SslCertificates | ForEach-Object {
        $_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat);
    }

    # Create Listeners
    $atleastOneHTTPSListener = $false
    $v2listener = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayHttpListener]
    $Listeners = Get-AzApplicationGatewayHttpListener -ApplicationGateway $Appgw
    $Listeners | ForEach-Object {
        $command = "New-AzApplicationGatewayHttpListener -Name $($_.Name) -Protocol $($_.Protocol) -FrontendPortId $($dict[$_.FrontendPort.Id].id) -FrontendIpConfigurationId $($dict[$_.FrontendIpConfiguration.Id].id) -RequireServerNameIndication $($_.RequireServerNameIndication) ";`
        if ($_.HostName)
        {
            $command += " -Hostname $($_.HostName)"
        }
        if ($_.Protocol -EQ "https")
        {
            $atleastOneHTTPSListener = $true

            $_.SslCertificate.Id = $_.SslCertificate.Id.Replace($existingResourceIdFormat,$newResourceIdFormat);
            $command = $command + " -SslCertificateId $($_.SslCertificate.Id)"
        }
        $z = Invoke-Expression $command;
        if ($z)
        {
            $customError = Get-AzApplicationGatewayHttpListenerCustomError -HttpListener $_ 
            if ($customError)
            {
                $z.CustomErrorConfigurations = $customError
            }

            $v2listener.Add($z);
            $dict[$_.id] = $z;
        }
    }
    if ($atleastOneHTTPSListener) 
    { 
        Write-Host ("Added CopyListenerSSLCertificatesFromV1Gateway tag since atleast one HTTPS Listener exist.")
        $appgw.Tag.Add("CopyListenerSSLCertificatesFromV1Gateway", $resourceId) 
    }

    if ($v2listener.count -NE $listeners.count )
    {
        Write-Warning ("Failed to create Listeners. Please check you have given correct inputs and retry.")
        return
    }
    else
    {
        Write-Host ("Created Listeners")
    }

    # RedirectionConfig
    $RedirectConfig = Get-AzApplicationGatewayRedirectConfiguration -ApplicationGateway $AppGw;
    $RedirectConfig | ForEach-Object { 
        if ($_.TargetListener)
        {
            $_.TargetListener.Id = $dict[$_.TargetListener.Id].id
        }
        $dict[$_.id] = $_;
        $_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat);
    }

    # Url path maps
    $urlpath = Get-AzApplicationGatewayUrlPathMapConfig -ApplicationGateway $appgw
    $urlpath | ForEach-Object { 
        $_.PathRules | ForEach-Object {
            if ($_.BackendAddressPool)
            {
                $_.BackendAddressPool.id = $dict[$_.BackendAddressPool.id].id;
            }
            if ($_.RedirectConfiguration)
            {
                $_.RedirectConfiguration.id = $dict[$_.RedirectConfiguration.id].id;
            }
            if ($_.BackendHttpSettings)
            {
                $_.BackendHttpSettings.id = $dict[$_.BackendHttpSettings.id].id;
            }
        }
        
        if ($_.DefaultBackendAddressPool)
        {
            $_.DefaultBackendAddressPool.Id = $dict[$_.DefaultBackendAddressPool.Id].id
        }
        if ($_.DefaultBackendHttpSettings)
        {
            $_.DefaultBackendHttpSettings.Id = $dict[$_.DefaultBackendHttpSettings.Id].id
        }
        if($_.DefaultRedirectConfiguration)
        {
            $_.DefaultRedirectConfiguration.Id = $dict[$_.DefaultRedirectConfiguration.Id].id
        }
        $dict[$_.Id] = $_;
        $_.Id = $_.Id.Replace($existingResourceIdFormat,$newResourceIdFormat);
    }

    # Request Routing Rules
    $Rules = Get-AzApplicationGatewayRequestRoutingRule -ApplicationGateway $AppGW
    $v2Rules = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayRequestRoutingRule]
    $priority = 100
    $Rules | ForEach-Object {
        if($dict.ContainsKey($_.HttpListener.Id))
        {
            $command = "New-AzApplicationGatewayRequestRoutingRule -Name $($_.Name) -RuleType $($_.RuleType) -HttpListenerId $($dict[$_.HttpListener.Id].id) -Priority $($priority)";
            if ($_.BackendHttpSettings -and $dict.ContainsKey($_.BackendHttpSettings.Id))
            {
                $command += " -BackendHttpSettingsId $($dict[$_.BackendHttpSettings.Id].id) -backendAddressPoolId $($dict[$_.BackendAddressPool.Id].id)";
            }
            elseif ($_.RedirectConfiguration.Id -and $dict.ContainsKey($_.RedirectConfiguration.Id))
            {
                $command += " -RedirectConfigurationId $($dict[$_.RedirectConfiguration.Id].id)"
            }  
            elseif ($_.UrlPathMap.Id -and $dict.ContainsKey($_.UrlPathMap.Id))
            {
                $command += " -UrlPathMapId $($dict[$_.UrlPathMap.Id].id)"
            }
            else {Write-Error "No rule can be created for", $_.Name;}
            $z = Invoke-Expression ($command);
            if ($z)
            {
                $v2rules.Add($z);

                # Updating Rule Priority
                $priority += 50
            }
        }
    }

    if ($v2Rules.count -NE $rules.count )
    {
        Write-Warning ("Failed to create Request routing rules. Please check you have given correct input and retry. Please report if the problem continues.")
        return
    }
    else
    {
        Write-Host ("Created Request Routing Rules")
    }

    # AppGateway Custom Error Config
    $customError = Get-AzApplicationGatewayCustomError -ApplicationGateway $appgw

    $sslpolicy = Get-AzApplicationGatewaySslPolicy -ApplicationGateway $AppGw
    $wafConfig = Get-AzApplicationGatewayWebApplicationFirewallConfiguration -ApplicationGateway $AppGw
    $appgw.Tag.Add("CreatedUsing", "AzureAppGWPrepareScript")

    #Verify that AppGw of same name doesn't exist
    $getAppGw = Get-AzApplicationGateway -Name $appgwname -ResourceGroupName $AppGwResourceGroupName -ErrorAction SilentlyContinue

    if($getAppGw)
    {
        Write-Warning ("AppGw with name $appgwname and resource group name $AppGwResourceGroupName already exists. Please provide correct parameters to the script.")
        return
    }

    # create a waf policy based on the WebApplicationFirewallConfiguration  if it is a WAF V1 gateway
    if ($appgw.sku.Tier -eq "WAF")
    {
        if ( !$WafPolicyName )
        { 
            $WafPolicyName = $AppGwName + "_WAFPolicy"
        }
        #Verify that waf policy doesn't exist
        $getWAFPolicy = Get-AzApplicationGatewayFirewallPolicy -ResourceGroupName $AppGwResourceGroupName -name $WafPolicyName -ErrorAction SilentlyContinue

        if($getWAFPolicy)
        {
            Write-Warning ("WAF Policy with WAF ID $($getWAFPolicy.Id) already exists. Please try again after deleting this WAF policy or providing a unique WAF Policy Name using WafPolicyName parameter")
            return
        }
        # create a waf policy based on the appgw v1 waf configuration
        $waf = CreateNewWAFPolicy

        if($waf)
        {
            $isWafPolicyCreated = $true
        }
    }

    # create app gateway
    $command = 'New-AzApplicationGateway -Name $appgwname -ResourceGroupName $AppGwResourceGroupName -Location $location -Sku $(Select-Object -InputObject $sku) -GatewayIPConfigurations $(Select-Object -InputObject $gwipconfig) -FrontendIpConfigurations $(Select-Object -InputObject $fip) '
    $command += ' -FrontendPorts $(Select-Object -InputObject $FrontEndPorts) -BackendAddressPools $(Select-Object -InputObject $BackendPools) -BackendHttpSettingsCollection $(Select-Object -InputObject $SettingsList) -HttpListeners $(Select-Object -InputObject $v2listener) -RequestRoutingRules $(Select-Object -InputObject $v2rules) '
    $command += ' -Tag $appgw.Tag -Force'
    if (!$disableAutoscale)
    { $command += ' -AutoScaleConfiguration $(Select-Object -InputObject $autoscaleConfig)' }
    if ($appgw.EnableHttp2)
    { $command += ' -EnableHttp2 ' }
    if($urlpath.Count -gt 0)
    { $command += ' -UrlPathMaps $($urlpath)' }
    if($probes.Count -gt 0)
    { $command += ' -Probes $(Select-Object -InputObject $probes)' }
    if($RedirectConfig.Count -gt 0)
    { $command += ' -RedirectConfigurations $(Select-Object -InputObject $RedirectConfig)' }
    if ($SslCertificates.Count -gt 0 )
    { $command += ' -SslCertificates $(Select-Object -InputObject $SslCertificates)' }
    if ($sslpolicy)
    {   $command += ' -SslPolicy $(Select-Object -InputObject $sslpolicy) ' }
    if ($customError)
    {   $command += ' -CustomErrorConfiguration $customError' }
    if ($appgwDeploymentZones)
    {   $command += ' -Zone $appgwDeploymentZones'  }
    if ($appgw.sku.Tier -eq "WAF" -and $isWafPolicyCreated)
    {
        $command += ' -FirewallPolicyId    $waf.Id'
    }
    Write-Host "Creating new V2 Application Gateway / WAF may take up to ~7mins. Please wait for the command to complete." -ForegroundColor Yellow
    $newAppGw = Invoke-Expression ($command)

    if ( $newAppGw )
    {
        Write-Host ("Successfully created V2 Application Gateway / WAF")
        Write-Host ("Name : $($newAppGw.Name)")
        Write-Host ("PublicIPAddress : $($pip.IpAddress)") 
        Write-Host ("Subnet Name (Prefix) : $($agv2Subnet.Name) ( $($agv2Subnet.AddressPrefix) )") 
    }
    else
    {
        Write-Error ("Creation of V2 Application Gateway / WAF failed. Please retry after sometime. Please contact Azure Support if error persists after several retries.")
        return
    }

    # For Virtual Machine (VM) / Virtual Machine Scale Set (VMSS) as backend,
    # set VM/VMSS NIC to point to application gateway backend pool
    $ListOfNicsToAttachToV2 = @{}
    $BackendPools | ForEach-Object {
        if ($_.BackendIpConfigurations)
        {
            $BackendPoolToAdd = Get-AzApplicationGatewayBackendAddressPool -Name $_.Name -ApplicationGateway $newAppGw
            $_.BackendIpConfigurations | ForEach-Object {
                if ($_.Id -match "/resourceGroups/(.*?)/providers/Microsoft.Network/networkInterfaces/(.*?)/ipconfigurations/" )
                {
                    $key = "VM/$($matches[1])/$($matches[2])"
                    if(!$ListOfNicsToAttachToV2.ContainsKey($key)){
                            $obj = @{
                            type = "VM"
                            resourceGroup = $matches[1]
                            nicname = $matches[2]
                            BackendPool = @($BackendPoolToAdd)	
                        }
                        $ListOfNicsToAttachToV2[$key] = $obj
                    }
                    else{
                        $ListOfNicsToAttachToV2[$key].BackendPool += $BackendPoolToAdd
                    }
                }
                elseif ($_.Id -match "/resourceGroups/(.*?)/providers/Microsoft.Compute/virtualMachineScaleSets/(.*?)/virtualMachines/(.*?)/networkInterfaces/(.*?)/ipConfigurations/")
                {
                    $key = "VMSS/$($matches[1])/$($matches[2])"
                    if(!$ListOfNicsToAttachToV2.ContainsKey($key))
                    {
                        $obj = @{
                            type = "VMSS"
                            resourceGroup = $matches[1]
                            vmssname = $matches[2]
                            nicList = @{}
                            instances = @($matches[3])
                        }
                        $obj.nicList[$matches[4]] = @($BackendPoolToAdd)
                        $ListOfNicsToAttachToV2[$key] = $obj
                    }
                    else
                    {
                        $ListOfNicsToAttachToV2[$key].instances += $matches[3]
                        
                        if(!$ListOfNicsToAttachToV2[$key].nicList.ContainsKey($matches[4]))
                        {
                            $ListOfNicsToAttachToV2[$key].nicList[$matches[4]] = @($BackendPoolToAdd)
                        }
                        else
                        {
                            $containsBackendPool = $false
                            foreach ($pool in $ListOfNicsToAttachToV2[$key].nicList[$matches[4]]) {
                                if ($pool.Id -eq $BackendPoolToAdd.Id) {
                                    $containsBackendPool = $true
                                    break
                                }
                            }

                            if (-not $containsBackendPool)
                            {
                                $ListOfNicsToAttachToV2[$key].nicList[$matches[4]] += $BackendPoolToAdd
                            }
                        }
                    }
                }
                else
                {
                    Write-Error ("Unsupported backend address pool config for '$($BackendPoolToAdd.Name)', could not be migrated.")
                }
            }
        }
    }

    $jobs = @()
    $ListOfNicsToAttachToV2.Values | ForEach-Object { 
        if ($_.type -eq "VM")
        {
            $jobs += Start-Job -ScriptBlock $AttachVmNetworkInterface -ArgumentList ($_.nicname, $_.resourceGroup, $_.backendpool)
        }
        else
        {
            $jobs += Start-Job -ScriptBlock $AttachVmssNetworkInterface -ArgumentList @($_.vmssname, $_.nicList, $_.resourceGroup, $_.instances)
        }
    }
    if ($jobs)
    {
        Write-Host "Attaching backend pool VM/VMSS NICs to v2 application gateway"
        Wait-Job -Job $jobs | Out-Null
        $jobResponses = Receive-Job -Job $jobs
        if (($jobResponses | Where-Object { $_ -eq $false }).count -NE 0)
        {
            Write-Error ("Could not sucessfully configure VM/VMSS in backend pool. Please retry the script after some time.") 
            exit
        }
    }

    $sw.Stop()
    $migrationCompleted = $true
    if ($validateBackendHealth)
    {
        # compare backend health for v1 and v2 app gateway
        $x = Get-AzApplicationGatewayBackendHealth -Name $V1AppGwName -ResourceGroupName $resourcegroup
        $y = Get-AzApplicationGatewayBackendHealth -Name $AppGwName -ResourceGroupName $AppGwResourceGroupName
        for ($i = 0; $i -lt $x.BackendAddressPools.Count; $i++) {
            $x1 = $x.BackendAddressPools[$i].BackendHttpSettingsCollection
            $y1 = $y.BackendAddressPools[$i].BackendHttpSettingsCollection
            $dict = @{}
            for ($j = 0; $j -lt $x1.Count; $j++) {
                $x1[$j].Servers | ForEach-Object { $dict[$_.Address] = $_.Health }
                $y1[$j].Servers | ForEach-Object { 
                    if ($_.Health -EQ $dict[$_.Address]) {
                        Write-Host ("Backend Health reported equal for - $($_.Address) ")
                    }
                    else {
                        Write-Warning ("Backend Health reported difference for - $($_.Address), v1 - $($dict[$_.Address]), v2 - $($_.health)")
                    }
                }
            }
        }
    }
    
    return $newAppGw
}
catch [Exception]
{
    Write-Output $_.Exception | format-list -force
}
finally
{
    if ($migrationCompleted -EQ $false)
    {
        cleanup
    }
    else 
    {
        Write-Host ("V2 AppGw creation complete. TimeTaken : $($sw.Elapsed.TotalSeconds) seconds")
    }
}
# SIG # Begin signature block
# MIIsAAYJKoZIhvcNAQcCoIIr8TCCK+0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDa8r+Zyqj6Ktx0
# 77mccbRDC4+bUpbqrbYiH2S6R7af5qCCEW4wggh+MIIHZqADAgECAhM2AAACAO38
# jbec3qFIAAIAAAIAMA0GCSqGSIb3DQEBCwUAMEExEzARBgoJkiaJk/IsZAEZFgNH
# QkwxEzARBgoJkiaJk/IsZAEZFgNBTUUxFTATBgNVBAMTDEFNRSBDUyBDQSAwMTAe
# Fw0yNDExMDgxMjQzMjhaFw0yNTExMDgxMjQzMjhaMCQxIjAgBgNVBAMTGU1pY3Jv
# c29mdCBBenVyZSBDb2RlIFNpZ24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
# AoIBAQC5L/UPrOpwYjxcoZC0TqqvMF1WUELvwXN+k27SrA5rohJknn7Cgbxg4hGT
# XKqpcdbtsVTN3ZY896SJ20uQ+INL5OVLzpW408nCNTPYg2LtGJbqHUjpNm0hLCJ+
# gO5Jn2T8DDzIJoUijGXj1m+hRLKb2nOIicCED2GuYBmuWXnaY7INmVEaU3peryty
# ZjDuxdyGDuiPURz8lW1SUiDzoszNp1oswVr+WjDvLDUx4HlxPsG8zUjIst0NnJ6o
# z4tNFKaUBDCetcMjQxpCETn29a1CuRddxZLjPHZHfcotr5sh1S6bNQdzVaMNsxV8
# L3wjHb7XJ6ZVm662mHEiPgpyNcLhAgMBAAGjggWKMIIFhjApBgkrBgEEAYI3FQoE
# HDAaMAwGCisGAQQBgjdbAQEwCgYIKwYBBQUHAwMwPQYJKwYBBAGCNxUHBDAwLgYm
# KwYBBAGCNxUIhpDjDYTVtHiE8Ys+hZvdFs6dEoFgg93NZoaUjDICAWQCAQ4wggJ2
# BggrBgEFBQcBAQSCAmgwggJkMGIGCCsGAQUFBzAChlZodHRwOi8vY3JsLm1pY3Jv
# c29mdC5jb20vcGtpaW5mcmEvQ2VydHMvQlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1F
# JTIwQ1MlMjBDQSUyMDAxKDIpLmNydDBSBggrBgEFBQcwAoZGaHR0cDovL2NybDEu
# YW1lLmdibC9haWEvQlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1FJTIwQ1MlMjBDQSUy
# MDAxKDIpLmNydDBSBggrBgEFBQcwAoZGaHR0cDovL2NybDIuYW1lLmdibC9haWEv
# QlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1FJTIwQ1MlMjBDQSUyMDAxKDIpLmNydDBS
# BggrBgEFBQcwAoZGaHR0cDovL2NybDMuYW1lLmdibC9haWEvQlkyUEtJQ1NDQTAx
# LkFNRS5HQkxfQU1FJTIwQ1MlMjBDQSUyMDAxKDIpLmNydDBSBggrBgEFBQcwAoZG
# aHR0cDovL2NybDQuYW1lLmdibC9haWEvQlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1F
# JTIwQ1MlMjBDQSUyMDAxKDIpLmNydDCBrQYIKwYBBQUHMAKGgaBsZGFwOi8vL0NO
# PUFNRSUyMENTJTIwQ0ElMjAwMSxDTj1BSUEsQ049UHVibGljJTIwS2V5JTIwU2Vy
# dmljZXMsQ049U2VydmljZXMsQ049Q29uZmlndXJhdGlvbixEQz1BTUUsREM9R0JM
# P2NBQ2VydGlmaWNhdGU/YmFzZT9vYmplY3RDbGFzcz1jZXJ0aWZpY2F0aW9uQXV0
# aG9yaXR5MB0GA1UdDgQWBBST/HE52ZUlmsYqZcZBdrXZ5u4ZnzAOBgNVHQ8BAf8E
# BAMCB4AwRQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEWMBQGA1UEBRMNMjM2MTY3KzUwMzE1NTCCAeYGA1UdHwSCAd0wggHZMIIB
# 1aCCAdGgggHNhj9odHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpaW5mcmEvQ1JM
# L0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGMWh0dHA6Ly9jcmwxLmFtZS5nYmwv
# Y3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGMWh0dHA6Ly9jcmwyLmFtZS5n
# YmwvY3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGMWh0dHA6Ly9jcmwzLmFt
# ZS5nYmwvY3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGMWh0dHA6Ly9jcmw0
# LmFtZS5nYmwvY3JsL0FNRSUyMENTJTIwQ0ElMjAwMSgyKS5jcmyGgb1sZGFwOi8v
# L0NOPUFNRSUyMENTJTIwQ0ElMjAwMSgyKSxDTj1CWTJQS0lDU0NBMDEsQ049Q0RQ
# LENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZp
# Z3VyYXRpb24sREM9QU1FLERDPUdCTD9jZXJ0aWZpY2F0ZVJldm9jYXRpb25MaXN0
# P2Jhc2U/b2JqZWN0Q2xhc3M9Y1JMRGlzdHJpYnV0aW9uUG9pbnQwHwYDVR0jBBgw
# FoAUllGE4Gtve/7YBqvD8oXmKa5q+dQwHwYDVR0lBBgwFgYKKwYBBAGCN1sBAQYI
# KwYBBQUHAwMwDQYJKoZIhvcNAQELBQADggEBAEDd8Wf5RkHsB64vgn2slxDtHzSo
# It9xN/Dm3RdFjNZ0diTUPMgSPYQlSk8nIAfudnB9FLavGlvZLlyUpfrPSuikepj3
# i3pqNEFn6fNdNFv/wHMxv7hQTIDCmuoR1v1rX+w3oeleBPMnN3QmH4ff1NsynyV4
# dZdYgN9Cw9sC/S3pWZpJrbOs7YOM3vqyU6DciHhC4D9i2zByHCF2pu9nYfiQf5A2
# iUZenRvyo1E5rC+UP2VZXa4k7g66W20+zAajIKKIqEmRtWahekMkCcOIHFBY4RDA
# ybgPRSGur4VDAiZPjTXS90wQXrX9CwU20cfiCC6e76F4H95KtQjKYpzuNVAwggjo
# MIIG0KADAgECAhMfAAAAUeqP9pxzDKg7AAAAAABRMA0GCSqGSIb3DQEBCwUAMDwx
# EzARBgoJkiaJk/IsZAEZFgNHQkwxEzARBgoJkiaJk/IsZAEZFgNBTUUxEDAOBgNV
# BAMTB2FtZXJvb3QwHhcNMjEwNTIxMTg0NDE0WhcNMjYwNTIxMTg1NDE0WjBBMRMw
# EQYKCZImiZPyLGQBGRYDR0JMMRMwEQYKCZImiZPyLGQBGRYDQU1FMRUwEwYDVQQD
# EwxBTUUgQ1MgQ0EgMDEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDJ
# mlIJfQGejVbXKpcyFPoFSUllalrinfEV6JMc7i+bZDoL9rNHnHDGfJgeuRIYO1LY
# /1f4oMTrhXbSaYRCS5vGc8145WcTZG908bGDCWr4GFLc411WxA+Pv2rteAcz0eHM
# H36qTQ8L0o3XOb2n+x7KJFLokXV1s6pF/WlSXsUBXGaCIIWBXyEchv+sM9eKDsUO
# LdLTITHYJQNWkiryMSEbxqdQUTVZjEz6eLRLkofDAo8pXirIYOgM770CYOiZrcKH
# K7lYOVblx22pdNawY8Te6a2dfoCaWV1QUuazg5VHiC4p/6fksgEILptOKhx9c+ia
# piNhMrHsAYx9pUtppeaFAgMBAAGjggTcMIIE2DASBgkrBgEEAYI3FQEEBQIDAgAC
# MCMGCSsGAQQBgjcVAgQWBBQSaCRCIUfL1Gu+Mc8gpMALI38/RzAdBgNVHQ4EFgQU
# llGE4Gtve/7YBqvD8oXmKa5q+dQwggEEBgNVHSUEgfwwgfkGBysGAQUCAwUGCCsG
# AQUFBwMBBggrBgEFBQcDAgYKKwYBBAGCNxQCAQYJKwYBBAGCNxUGBgorBgEEAYI3
# CgMMBgkrBgEEAYI3FQYGCCsGAQUFBwMJBggrBgEFBQgCAgYKKwYBBAGCN0ABAQYL
# KwYBBAGCNwoDBAEGCisGAQQBgjcKAwQGCSsGAQQBgjcVBQYKKwYBBAGCNxQCAgYK
# KwYBBAGCNxQCAwYIKwYBBQUHAwMGCisGAQQBgjdbAQEGCisGAQQBgjdbAgEGCisG
# AQQBgjdbAwEGCisGAQQBgjdbBQEGCisGAQQBgjdbBAEGCisGAQQBgjdbBAIwGQYJ
# KwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwHwYDVR0jBBgwFoAUKV5RXmSuNLnrrJwNp4x1AdEJCygwggFoBgNV
# HR8EggFfMIIBWzCCAVegggFToIIBT4YxaHR0cDovL2NybC5taWNyb3NvZnQuY29t
# L3BraWluZnJhL2NybC9hbWVyb290LmNybIYjaHR0cDovL2NybDIuYW1lLmdibC9j
# cmwvYW1lcm9vdC5jcmyGI2h0dHA6Ly9jcmwzLmFtZS5nYmwvY3JsL2FtZXJvb3Qu
# Y3JshiNodHRwOi8vY3JsMS5hbWUuZ2JsL2NybC9hbWVyb290LmNybIaBqmxkYXA6
# Ly8vQ049YW1lcm9vdCxDTj1BTUVSb290LENOPUNEUCxDTj1QdWJsaWMlMjBLZXkl
# MjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxDTj1Db25maWd1cmF0aW9uLERDPUFNRSxE
# Qz1HQkw/Y2VydGlmaWNhdGVSZXZvY2F0aW9uTGlzdD9iYXNlP29iamVjdENsYXNz
# PWNSTERpc3RyaWJ1dGlvblBvaW50MIIBqwYIKwYBBQUHAQEEggGdMIIBmTBHBggr
# BgEFBQcwAoY7aHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraWluZnJhL2NlcnRz
# L0FNRVJvb3RfYW1lcm9vdC5jcnQwNwYIKwYBBQUHMAKGK2h0dHA6Ly9jcmwyLmFt
# ZS5nYmwvYWlhL0FNRVJvb3RfYW1lcm9vdC5jcnQwNwYIKwYBBQUHMAKGK2h0dHA6
# Ly9jcmwzLmFtZS5nYmwvYWlhL0FNRVJvb3RfYW1lcm9vdC5jcnQwNwYIKwYBBQUH
# MAKGK2h0dHA6Ly9jcmwxLmFtZS5nYmwvYWlhL0FNRVJvb3RfYW1lcm9vdC5jcnQw
# gaIGCCsGAQUFBzAChoGVbGRhcDovLy9DTj1hbWVyb290LENOPUFJQSxDTj1QdWJs
# aWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxDTj1Db25maWd1cmF0aW9u
# LERDPUFNRSxEQz1HQkw/Y0FDZXJ0aWZpY2F0ZT9iYXNlP29iamVjdENsYXNzPWNl
# cnRpZmljYXRpb25BdXRob3JpdHkwDQYJKoZIhvcNAQELBQADggIBAFAQI7dPD+jf
# XtGt3vJp2pyzA/HUu8hjKaRpM3opya5G3ocprRd7vdTHb8BDfRN+AD0YEmeDB5HK
# QoG6xHPI5TXuIi5sm/LeADbV3C2q0HQOygS/VT+m1W7a/752hMIn+L4ZuyxVeSBp
# fwf7oQ4YSZPh6+ngZvBHgfBaVz4O9/wcfw91QDZnTgK9zAh9yRKKls2bziPEnxeO
# ZMVNaxyV0v152PY2xjqIafIkUjK6vY9LtVFjJXenVUAmn3WCPWNFC1YTIIHw/mD2
# cTfPy7QA1pT+GPARAKt0bKtq9aCd/Ym0b5tPbpgCiRtzyb7fbNS1dE740re0COE6
# 7YV2wbeo2sXixzvLftH8L7s9xv9wV+G22qyKt6lmKLjFK1yMw4Ni5fMabcgmzRvS
# jAcbqgp3tk4a8emaaH0rz8MuuIP+yrxtREPXSqL/C5bzMzsikuDW9xH10graZzSm
# PjilzpRfRdu20/9UQmC7eVPZ4j1WNa1oqPHfzET3ChIzJ6Q9G3NPCB+7KwX0OQmK
# yv7IDimj8U/GlsHD1z+EF/fYMf8YXG15LamaOAohsw/ywO6SYSreVW+5Y0mzJutn
# BC9Cm9ozj1+/4kqksrlhZgR/CSxhFH3BTweH8gP2FEISRtShDZbuYymynY1un+Ry
# fiK9+iVTLdD1h/SxyxDpZMtimb4CgJQlMYIZ6DCCGeQCAQEwWDBBMRMwEQYKCZIm
# iZPyLGQBGRYDR0JMMRMwEQYKCZImiZPyLGQBGRYDQU1FMRUwEwYDVQQDEwxBTUUg
# Q1MgQ0EgMDECEzYAAAIA7fyNt5zeoUgAAgAAAgAwDQYJYIZIAWUDBAIBBQCgga4w
# GQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisG
# AQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIK5OhjTnVIiuf+FR5zqcflLNaLru9FI8
# LCaeMPKqg6wnMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYA
# dKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEA
# CGi4nZrf4rQwoXte7y/JU9wc7Kc844X9sdXRGYqbTiRpmdKyJjZvFEsprQj0B0Uv
# BvEMa8xQkNna086+a5dopWpzuQ1d4zYVqRpyk2j7hbWMFgC9tXgHIN8BY98xvpXo
# 6NTY5HyVeUQ2+MVKExtNwoXpx2/6kCCX9Ljy6MSwtaA4EEKVbmn02rIBY09gU1FC
# vD+Huc1XiY1SPztVOlwCMqAjfwwKSnNfgH4mbZraFKH1nU19ypeM2dJkdJuU4/hS
# 7IUppnwyzbnj4qrAH6CS9272Lq5qEDxYoJ4Ha+Wz/iLjsKYWkl5Ax3T2G4y3j9Iq
# aVkmSAQuVlvlpxU+fXzLgqGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqG
# SIb3DQEHAqCCF4kwgheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0B
# CRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUA
# BCDYVRmfAcZuaCxaJ/I+bO5YltYGhR3p/IPjw8oYBKr6OwIGaKSkKpA7GBMyMDI1
# MDkyMjA2MDA1Ny45MDJaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBP
# cGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2RjFB
# LTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vydmlj
# ZaCCEf4wggcoMIIFEKADAgECAhMzAAAB/Bigr8xpWoc6AAEAAAH8MA0GCSqGSIb3
# DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAk
# BgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI0MDcyNTE4
# MzExNFoXDTI1MTAyMjE4MzExNFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlv
# bnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjZGMUEtMDVFMC1E
# OTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAp1DAKLxpbQcPVYPHlJHyW7W5lBZj
# JWWDjMfl5WyhuAylP/LDm2hb4ymUmSymV0EFRQcmM8BypwjhWP8F7x4iO88d+9GZ
# 9MQmNh3jSDohhXXgf8rONEAyfCPVmJzM7ytsurZ9xocbuEL7+P7EkIwoOuMFlTF2
# G/zuqx1E+wANslpPqPpb8PC56BQxgJCI1LOF5lk3AePJ78OL3aw/NdlkvdVl3VgB
# SPX4Nawt3UgUofuPn/cp9vwKKBwuIWQEFZ837GXXITshd2Mfs6oYfxXEtmj2SBGE
# hxVs7xERuWGb0cK6afy7naKkbZI2v1UqsxuZt94rn/ey2ynvunlx0R6/b6nNkC1r
# OTAfWlpsAj/QlzyM6uYTSxYZC2YWzLbbRl0lRtSz+4TdpUU/oAZSB+Y+s12Rqmgz
# i7RVxNcI2lm//sCEm6A63nCJCgYtM+LLe9pTshl/Wf8OOuPQRiA+stTsg89BOG9t
# blaz2kfeOkYf5hdH8phAbuOuDQfr6s5Ya6W+vZz6E0Zsenzi0OtMf5RCa2hADYVg
# UxD+grC8EptfWeVAWgYCaQFheNN/ZGNQMkk78V63yoPBffJEAu+B5xlTPYoijUdo
# 9NXovJmoGXj6R8Tgso+QPaAGHKxCbHa1QL9ASMF3Os1jrogCHGiykfp1dKGnmA5w
# JT6Nx7BedlSDsAkCAwEAAaOCAUkwggFFMB0GA1UdDgQWBBSY8aUrsUazhxByH79d
# hiQCL/7QdjAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8E
# WDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9N
# aWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYB
# BQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEw
# KDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4G
# A1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAT7ss/ZAZ0bTaFsrsiJYd
# //LQ6ImKb9JZSKiRw9xs8hwk5Y/7zign9gGtweRChC2lJ8GVRHgrFkBxACjuuPpr
# Sz/UYX7n522JKcudnWuIeE1p30BZrqPTOnscD98DZi6WNTAymnaS7it5qAgNInre
# AJbTU2cAosJoeXAHr50YgSGlmJM+cN6mYLAL6TTFMtFYJrpK9TM5Ryh5eZmm6UTJ
# nGg0jt1pF/2u8PSdz3dDy7DF7KDJad2qHxZORvM3k9V8Yn3JI5YLPuLso2J5s3fp
# XyCVgR/hq86g5zjd9bRRyyiC8iLIm/N95q6HWVsCeySetrqfsDyYWStwL96hy7DI
# yLL5ih8YFMd0AdmvTRoylmADuKwE2TQCTvPnjnLk7ypJW29t17Yya4V+Jlz54sBn
# PU7kIeYZsvUT+YKgykP1QB+p+uUdRH6e79Vaiz+iewWrIJZ4tXkDMmL21nh0j+58
# E1ecAYDvT6B4yFIeonxA/6Gl9Xs7JLciPCIC6hGdliiEBpyYeUF0ohZFn7NKQu80
# IZ0jd511WA2bq6x9aUq/zFyf8Egw+dunUj1KtNoWpq7VuJqapckYsmvmmYHZXCjK
# 1Eus7V1I+aXjrBYuqyM9QpeFZU4U01YG15uWwUCaj0uZlah/RGSYMd84y9DCqOpf
# eKE6PLMk7hLnhvcOQrnxP6kwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAA
# AAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBB
# dXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YB
# f2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKD
# RLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus
# 9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTj
# kY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56
# KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39
# IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHo
# vwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJo
# LhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMh
# XV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREd
# cu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEA
# AaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqn
# Uv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnp
# cjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0w
# EwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEw
# CwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/o
# olxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNy
# b3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYt
# MjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5j
# cnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+
# TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2Y
# urYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4
# U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJ
# w7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb
# 30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ
# /gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGO
# WhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFE
# fnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJ
# jXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rR
# nj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUz
# WLOhcGbyoYIDWTCCAkECAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBP
# cGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2RjFB
# LTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vydmlj
# ZaIjCgEBMAcGBSsOAwIaAxUATkEpJXOaqI2wfqBsw4NLVwqYqqqggYMwgYCkfjB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAOx7
# SbkwIhgPMjAyNTA5MjIwNDA2MTdaGA8yMDI1MDkyMzA0MDYxN1owdzA9BgorBgEE
# AYRZCgQBMS8wLTAKAgUA7HtJuQIBADAKAgEAAgIVTAIB/zAHAgEAAgITPzAKAgUA
# 7HybOQIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAID
# B6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQC7ECIPJGMY/e0MZfVS
# CARZ4RkAd5S5uYkTxaAaNZKGO9xAnDRVCw15JZ41x1ZiuC8dN3SLdRkAN79UC71D
# VWlSqByExUA5iaDuXJ2RXTm2flR4wt2DFRsAN1mIswypC11IlV7Wn2j8EqfSXxkw
# Y9AFgpSPZoee73/fxWvkwhXF/5pOM4G6sWWuycSvvrhHL8ih/5J3srrTPVe3W98L
# wkzHM/qOB8MKanHaOc3+9LD/7aj12rUpqF0OkDwPoByJH/Q6iiDRcVgIw7SFwEe8
# KtwgeHnvL4/h+jYKDf677gLfchWTjVPIldkQplYD5Y3U4KPsfUXgHfeBqvnVbLPy
# xSYJMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAH8GKCvzGlahzoAAQAAAfwwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgl9nhxstFfaGWieqG
# /iUb0uon5VLvGJjbAb/cnAnelfgwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9
# BCCVQq+Qu+/h/BOVP4wweUwbHuCUhh+T7hq3d5MCaNEtYjCBmDCBgKR+MHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAAB/Bigr8xpWoc6AAEAAAH8MCIE
# ID28vsZOtRPvJW2vmZDxFeoeoNOjFR2A92+5RS6ZYvIcMA0GCSqGSIb3DQEBCwUA
# BIICAIGGdWpfeKh5tPxlrGpf1PM6p5dpQcjeD/zTNmVVGsG0YChxTLqZHvmhFQo5
# SOz2//9EfTu5GSa9LEp+bq6R+oS2ayR2lUl2UUnRF4wzARCgws2uSItJckgp/kz8
# CwHqHyqBqdvKFDNJQV06/G6djM7CB/Xro5XVKW1JAa21Z1IODec+4y2Wg9nP7583
# HnFIFK/4a/YyO7mBCdJtLBQNgKjr2RjzcIC4UDpGeTxdAIj7EUyfdz9jCl8OAzZZ
# B/qnqpT9MIU1OiSz+h7OusFGktC//4VWwRrlBsudxgDzdvlPAt8NnFKhgNM+0inB
# SYhR+fg7qV9QjM4tiThvVKO5P0VvqdSzGZprk12hchPI0SZhk5fNrwcGd5TTeG8i
# DkxXtYFzAqRYBHcjRWPNSg1Sc2roInljCKNOG2DDA3RODK05iwfHbGxpBLaxpvji
# a0WAQn2OBvlc47VbuQUuveJF1pOgEU/79Lt6o9xQwbF8bFoilxITh/AFwPDVwDWg
# UyQwrLwBhCOPeNn4DhHXwhFOzak5BzxLn/4q6fkuzBB5oE3d3IKnVMpo2zeqjPik
# dCtBBYVKnW0Vrx+R7eI9oP99T6B5UZ2m4xAQeUxAEWT5vs13hvwpKjusu2p8QlT5
# R/Rl7pewpftZ9bGrUmv8meNAznkm04GDiIMt+gxyMZRV527C
# SIG # End signature block
