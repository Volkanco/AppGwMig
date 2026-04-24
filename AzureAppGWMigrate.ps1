<#PSScriptInfo

.VERSION 1.0.0

.GUID 8f3a1d5c-4b2e-4f7a-9c1d-0e6f2a8b3c5d

.AUTHOR Microsoft Corporation

.COMPANYNAME Microsoft Corporation

.COPYRIGHT Microsoft Corporation. All rights reserved.

.TAGS Azure, Az, ApplicationGateway, AzNetworking, Migration

.RELEASENOTES
1.0.0
 -- Two-phase V1 to V2 Application Gateway migration (Backup & Deploy modes).
 -- Backup mode exports full V1 configuration to a portable JSON file.
 -- Deploy mode recreates the gateway as V2 in the exact same subnet used by V1.
#>

<#

.SYNOPSIS
AppGateway V1 -> V2 Two-Phase Migration (Backup & Deploy)

.DESCRIPTION
This script provides a two-phase approach to migrating an Azure Application Gateway from V1
(Standard/WAF) to V2 (Standard_v2/WAF_v2).

Phase 1 (Backup): Reads all configuration from an existing V1 Application Gateway and exports
it to a portable JSON backup file.

Phase 2 (Deploy): Reads the JSON backup file and deploys a new V2 Application Gateway into the
exact same subnet that was used by the V1 gateway. No new subnet is created. The V1 gateway
must be manually deleted between phases to free the subnet.

.PARAMETER Mode
Operation mode. Must be 'Backup' or 'Deploy'.

.PARAMETER ResourceId
(Backup mode) Full resource ID of the V1 Application Gateway.
Example: /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/applicationGateways/<name>

.PARAMETER BackupFile
Path to the JSON backup file. Written during Backup mode; read during Deploy mode.

.PARAMETER AppGwName
(Deploy mode) Name for the new V2 gateway. Defaults to <V1name>_v2.

.PARAMETER AppGwResourceGroupName
(Deploy mode) Resource group for the new V2 gateway. Defaults to the same RG as V1.

.PARAMETER PublicIpResourceId
(Deploy mode) Resource ID of an existing Public IP to attach. If omitted a new Standard
Static Public IP is created automatically.

.PARAMETER PrivateIpAddress
(Deploy mode) Private IP address for the V2 gateway frontend. If omitted a random address
within the subnet is chosen.

.PARAMETER ValidateBackendHealth
(Deploy mode) After deployment, compare V2 backend health against the backup metadata.

.PARAMETER DisableAutoscale
(Deploy mode) Provision a fixed-capacity gateway instead of using autoscale.

.PARAMETER WafPolicyName
(Deploy mode, WAF SKU only) Name for the WAF policy resource. Defaults to <AppGwName>_WAFPolicy.

.PARAMETER PrivateOnly
(Deploy mode) When specified, the V2 gateway is deployed with a private frontend IP only.
No public IP is created or attached. Use this when the gateway must not be internet-facing.
The private IP can be specified via -PrivateIpAddress, or one will be assigned dynamically from the subnet.

.EXAMPLE
# Step 1 – export V1 configuration
.\AzureAppGWMigrate.ps1 -Mode Backup `
    -ResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/applicationGateways/<v1name>" `
    -BackupFile "C:\backup\appgw-config.json"

# Step 2 – (manual) review backup; delete the V1 gateway in the portal / CLI.

# Step 3 – deploy V2 into the same subnet
.\AzureAppGWMigrate.ps1 -Mode Deploy `
    -BackupFile "C:\backup\appgw-config.json" `
    -AppGwName "mygateway-v2" `
    -AppGwResourceGroupName "my-rg"

# Deploy a private-only V2 gateway (no public IP)
.\AzureAppGWMigrate.ps1 -Mode Deploy `
    -BackupFile "C:\backup\appgw-config.json" `
    -AppGwName "mygateway-v2" `
    -AppGwResourceGroupName "my-rg" `
    -PrivateOnly

.INPUTS
String

.OUTPUTS
PSApplicationGateway (Deploy mode only)

.LINK
https://docs.microsoft.com/en-us/azure/application-gateway/
#>

#Requires -Module Az.Network
#Requires -Module Az.Compute
#Requires -Module Az.Resources

Param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Backup", "Deploy")]
    [string] $Mode,

    # --- Backup mode ---
    [Parameter(Mandatory = $false)]
    [string] $ResourceId,

    # --- Shared ---
    [Parameter(Mandatory = $true)]
    [string] $BackupFile,

    # --- Deploy mode ---
    [Parameter(Mandatory = $false)]
    [string] $AppGwName,

    [Parameter(Mandatory = $false)]
    [string] $AppGwResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string] $PublicIpResourceId,

    [Parameter(Mandatory = $false)]
    [string] $PrivateIpAddress,

    [Parameter(Mandatory = $false)]
    [switch] $ValidateBackendHealth,

    [Parameter(Mandatory = $false)]
    [switch] $DisableAutoscale,

    [Parameter(Mandatory = $false)]
    [string] $WafPolicyName,

    [Parameter(Mandatory = $false)]
    [switch] $PrivateOnly
)

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

Function Get-NameFromId {
    param([string] $Id)
    if ($Id) { return $Id.Split("/")[-1] } else { return $null }
}

Function Get-SubscriptionFromResourceId {
    param([string] $Id)
    if ($Id -match "/subscriptions/([^/]+)/") { return $matches[1] }
    return $null
}

Function Get-ResourceGroupFromResourceId {
    param([string] $Id)
    if ($Id -match "/resourceGroups/([^/]+)/") { return $matches[1] }
    return $null
}

Function GetApplicationGatewaySku {
    param([string] $GwSkuTier)
    if ($GwSkuTier -eq "Standard") {
        return New-AzApplicationGatewaySku -Name Standard_v2 -Tier Standard_v2
    }
    else {
        return New-AzApplicationGatewaySku -Name WAF_v2 -Tier WAF_v2
    }
}

Function GetCapacityUnits {
    param([object] $AppgwSku)
    $lowestPossibleCapacity = 2
    $highestPossibleCapacity = 125
    $minCapacity = 0
    $maxCapacity = 0
    $currentInstanceCount = [int]($AppgwSku.Capacity)

    switch ($AppgwSku.Name) {
        { $_ -in "Standard_Small" } {
            $minCapacity = [math]::floor($currentInstanceCount / 2)
            $maxCapacity = $currentInstanceCount
        }
        { $_ -in "WAF_Medium", "Standard_Medium" } {
            $minCapacity = $currentInstanceCount
            $maxCapacity = [math]::ceiling(1.5 * $currentInstanceCount)
        }
        { $_ -in "WAF_Large", "Standard_Large" } {
            $minCapacity = $currentInstanceCount
            $maxCapacity = [math]::ceiling(4.0 * $currentInstanceCount)
        }
    }

    if ($minCapacity -lt $lowestPossibleCapacity) { $minCapacity = $lowestPossibleCapacity }

    if ($maxCapacity -gt $highestPossibleCapacity) {
        Write-Warning ("Your current V1 gateway has too many instances to scale equivalently. " +
            "Please reduce V1 instance count or contact Azure Support to raise limits.")
        exit
    }
    elseif ($maxCapacity -lt $lowestPossibleCapacity) {
        $maxCapacity = $lowestPossibleCapacity
    }

    return $minCapacity, $maxCapacity
}

Function GetAvailabilityZoneMappings {
    param([string] $Subscription, [string] $Location)
    try {
        $response = Invoke-AzRestMethod -Method GET `
            -Path "/subscriptions/$Subscription/Providers/Microsoft.Compute?api-version=2017-08-01"
        if ($response.StatusCode -ne 200) {
            Write-Warning "Failed to retrieve availability zone mappings (HTTP $($response.StatusCode)). Zones will not be set."
            return $null
        }
        $data = ($response.Content | ConvertFrom-Json)
        $zoneMappings = $data.resourceTypes |
            Where-Object { $_.resourceType -eq "virtualMachineScaleSets" } |
            Select-Object -ExpandProperty zoneMappings
        $zoneMappingForLocation = $zoneMappings |
            Where-Object { $_.location.Replace(' ', '') -eq $Location }
        return $zoneMappingForLocation.zones
    }
    catch {
        Write-Warning "Failed to retrieve availability zone mappings. Zones will not be set."
        return $null
    }
}

# ---------------------------------------------------------------------------
# BACKUP MODE
# ---------------------------------------------------------------------------

Function Invoke-BackupMode {
    # 1. Validate ResourceId parameter
    if (-not $ResourceId) {
        Write-Error "Parameter -ResourceId is required when -Mode is 'Backup'."
        exit
    }

    # 2. Validate ResourceId format
    if ($ResourceId -notmatch "/subscriptions/(.*?)/resourceGroups/") {
        Write-Warning "Invalid ResourceId format: $ResourceId"
        exit
    }
    $subscription = $matches[1]

    # 3. Set Azure context
    $context = Set-AzContext -Subscription $subscription -ErrorVariable contextFailure -ErrorAction SilentlyContinue
    if ($contextFailure -or -not $context) {
        Write-Warning "Unable to set subscription '$subscription' in context. Please retry."
        exit
    }

    # 4. Get resource and gateway
    $resource = Get-AzResource -ResourceId $ResourceId -ErrorVariable getResourceFailure -ErrorAction SilentlyContinue
    if ($getResourceFailure -or -not $resource) {
        Write-Warning "Unable to get resource for '$ResourceId'. Please retry."
        exit
    }

    $resourceGroup = $resource.ResourceGroupName
    $location      = $resource.Location
    $v1Name        = $resource.Name

    $appGw = Get-AzApplicationGateway -Name $v1Name -ResourceGroupName $resourceGroup `
                 -ErrorVariable getGwFailure -ErrorAction SilentlyContinue
    if ($getGwFailure -or -not $appGw) {
        Write-Warning "Unable to retrieve Application Gateway '$v1Name'. Please retry."
        exit
    }

    # 5. Validate gateway
    if ($appGw.Sku.Tier -notin "Standard", "WAF") {
        Write-Warning "Gateway SKU tier '$($appGw.Sku.Tier)' is not a V1 tier (Standard or WAF). Aborting."
        exit
    }

    if ($appGw.ProvisioningState -ne "Succeeded") {
        Write-Warning "Application Gateway provisioning state is '$($appGw.ProvisioningState)'. Must be 'Succeeded'."
        exit
    }

    if ($appGw.WebApplicationFirewallConfiguration) {
        if ($appGw.WebApplicationFirewallConfiguration.RuleSetType -eq "OWASP" -and
            $appGw.WebApplicationFirewallConfiguration.RuleSetVersion -eq "2.2.9") {
            Write-Error ("The WAF V1 gateway uses CRS version 2.2.9, which is no longer supported for migration. " +
                "Upgrade to CRS 3.0 or later before migrating.")
            exit
        }
    }

    # 6. Extract networking information
    $gwIpConfig   = Get-AzApplicationGatewayIPConfiguration -ApplicationGateway $appGw
    $subnetId     = $gwIpConfig.Subnet.Id
    # /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>
    $null = $subnetId -match "/resourceGroups/([^/]+)/providers/Microsoft.Network/virtualNetworks/([^/]+)/subnets/([^/]+)"
    $vnetRg     = $matches[1]
    $vnetName   = $matches[2]
    $subnetName = $matches[3]

    $vnet   = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRg
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet

    $nsgId = $null
    if ($subnet.NetworkSecurityGroup) { $nsgId = $subnet.NetworkSecurityGroup.Id }

    # --- FrontendIPConfigurations ---
    $frontendIpConfigs = @()
    foreach ($fip in $appGw.FrontendIPConfigurations) {
        $isPublic = $null -ne $fip.PublicIPAddress
        $frontendIpConfigs += @{
            Name                    = $fip.Name
            IsPublic                = $isPublic
            PublicIPAddressId       = if ($fip.PublicIPAddress) { $fip.PublicIPAddress.Id } else { $null }
            PrivateIPAddress        = $fip.PrivateIPAddress
            PrivateIPAllocationMethod = $fip.PrivateIPAllocationMethod
        }
    }

    # --- FrontendPorts ---
    $frontendPorts = @()
    foreach ($fp in $appGw.FrontendPorts) {
        $frontendPorts += @{ Name = $fp.Name; Port = $fp.Port }
    }

    # --- BackendAddressPools ---
    $backendPools = @()
    foreach ($pool in $appGw.BackendAddressPools) {
        $addresses   = @()
        $nicIpConfigs = @()
        foreach ($addrObj in $pool.BackendAddresses) {
            if ($addrObj.IpAddress) { $addresses += $addrObj.IpAddress }
            elseif ($addrObj.Fqdn)  { $addresses += $addrObj.Fqdn }
        }
        foreach ($ipCfg in $pool.BackendIpConfigurations) {
            $nicIpConfigs += $ipCfg.Id
        }
        $backendPools += @{
            Name                       = $pool.Name
            Addresses                  = $addresses
            BackendIpConfigurationIds  = $nicIpConfigs
        }
    }

    # --- BackendHttpSettingsCollection ---
    $backendHttpSettings = @()
    foreach ($s in $appGw.BackendHttpSettingsCollection) {
        $drainEnabled  = $false
        $drainTimeout  = 0
        if ($s.ConnectionDraining) {
            $drainEnabled = $s.ConnectionDraining.Enabled
            $drainTimeout = $s.ConnectionDraining.DrainTimeoutInSec
        }
        $backendHttpSettings += @{
            Name                          = $s.Name
            Port                          = $s.Port
            Protocol                      = $s.Protocol
            CookieBasedAffinity           = $s.CookieBasedAffinity
            RequestTimeout                = $s.RequestTimeout
            ProbeName                     = if ($s.Probe) { Get-NameFromId $s.Probe.Id } else { $null }
            HostName                      = $s.HostName
            PickHostNameFromBackendAddress = $s.PickHostNameFromBackendAddress
            Path                          = $s.Path
            ConnectionDraining            = @{
                Enabled           = $drainEnabled
                DrainTimeoutInSec = $drainTimeout
            }
        }
    }

    # --- HealthProbes ---
    $healthProbes = @()
    foreach ($p in $appGw.Probes) {
        $matchObj = @{ StatusCodes = @("200-399"); Body = "" }
        if ($p.Match) {
            $matchObj.StatusCodes = if ($p.Match.StatusCodes) { @($p.Match.StatusCodes) } else { @("200-399") }
            $matchObj.Body        = if ($p.Match.Body) { $p.Match.Body } else { "" }
        }
        $healthProbes += @{
            Name                                = $p.Name
            Protocol                            = $p.Protocol
            Host                                = $p.Host
            Path                                = $p.Path
            Interval                            = $p.Interval
            Timeout                             = $p.Timeout
            UnhealthyThreshold                  = $p.UnhealthyThreshold
            PickHostNameFromBackendHttpSettings  = $p.PickHostNameFromBackendHttpSettings
            Match                               = $matchObj
        }
    }

    # --- SslCertificates ---
    $sslCertificates = @()
    foreach ($cert in $appGw.SslCertificates) {
        $sslCertificates += @{
            Name              = $cert.Name
            KeyVaultSecretId  = $cert.KeyVaultSecretId
            PublicCertData    = $cert.PublicCertData
        }
    }

    # --- HttpListeners ---
    $httpListeners = @()
    foreach ($l in $appGw.HttpListeners) {
        $customErrors = @()
        foreach ($ce in $l.CustomErrorConfigurations) {
            $customErrors += @{ StatusCode = $ce.StatusCode; CustomErrorPageUrl = $ce.CustomErrorPageUrl }
        }
        $httpListeners += @{
            Name                         = $l.Name
            Protocol                     = $l.Protocol
            FrontendIPConfigurationName  = Get-NameFromId $l.FrontendIpConfiguration.Id
            FrontendPortName             = Get-NameFromId $l.FrontendPort.Id
            HostName                     = $l.HostName
            RequireServerNameIndication  = $l.RequireServerNameIndication
            SslCertificateName           = if ($l.SslCertificate) { Get-NameFromId $l.SslCertificate.Id } else { $null }
            CustomErrorConfigurations    = $customErrors
        }
    }

    # --- RedirectConfigurations ---
    $redirectConfigs = @()
    foreach ($r in $appGw.RedirectConfigurations) {
        $redirectConfigs += @{
            Name                  = $r.Name
            RedirectType          = $r.RedirectType
            TargetListenerName    = if ($r.TargetListener)       { Get-NameFromId $r.TargetListener.Id }       else { $null }
            TargetUrl             = $r.TargetUrl
            IncludePath           = $r.IncludePath
            IncludeQueryString    = $r.IncludeQueryString
        }
    }

    # --- UrlPathMaps ---
    $urlPathMaps = @()
    foreach ($u in $appGw.UrlPathMaps) {
        $pathRules = @()
        foreach ($pr in $u.PathRules) {
            $pathRules += @{
                Name                       = $pr.Name
                Paths                      = @($pr.Paths)
                BackendAddressPoolName     = if ($pr.BackendAddressPool)    { Get-NameFromId $pr.BackendAddressPool.Id }    else { $null }
                BackendHttpSettingsName    = if ($pr.BackendHttpSettings)   { Get-NameFromId $pr.BackendHttpSettings.Id }   else { $null }
                RedirectConfigurationName  = if ($pr.RedirectConfiguration) { Get-NameFromId $pr.RedirectConfiguration.Id } else { $null }
            }
        }
        $urlPathMaps += @{
            Name                              = $u.Name
            DefaultBackendAddressPoolName     = if ($u.DefaultBackendAddressPool)    { Get-NameFromId $u.DefaultBackendAddressPool.Id }    else { $null }
            DefaultBackendHttpSettingsName    = if ($u.DefaultBackendHttpSettings)   { Get-NameFromId $u.DefaultBackendHttpSettings.Id }   else { $null }
            DefaultRedirectConfigurationName  = if ($u.DefaultRedirectConfiguration) { Get-NameFromId $u.DefaultRedirectConfiguration.Id } else { $null }
            PathRules                         = $pathRules
        }
    }

    # --- RequestRoutingRules ---
    $requestRoutingRules = @()
    foreach ($rule in $appGw.RequestRoutingRules) {
        $requestRoutingRules += @{
            Name                       = $rule.Name
            RuleType                   = $rule.RuleType
            HttpListenerName           = if ($rule.HttpListener)           { Get-NameFromId $rule.HttpListener.Id }           else { $null }
            BackendAddressPoolName     = if ($rule.BackendAddressPool)     { Get-NameFromId $rule.BackendAddressPool.Id }     else { $null }
            BackendHttpSettingsName    = if ($rule.BackendHttpSettings)    { Get-NameFromId $rule.BackendHttpSettings.Id }    else { $null }
            RedirectConfigurationName  = if ($rule.RedirectConfiguration)  { Get-NameFromId $rule.RedirectConfiguration.Id }  else { $null }
            UrlPathMapName             = if ($rule.UrlPathMap)             { Get-NameFromId $rule.UrlPathMap.Id }             else { $null }
        }
    }

    # --- SslPolicy ---
    $sslPolicyObj = $null
    $sslPolicy = Get-AzApplicationGatewaySslPolicy -ApplicationGateway $appGw -ErrorAction SilentlyContinue
    if ($sslPolicy) {
        $sslPolicyObj = @{
            PolicyType         = $sslPolicy.PolicyType
            PolicyName         = $sslPolicy.PolicyName
            MinProtocolVersion = $sslPolicy.MinProtocolVersion
            CipherSuites       = if ($sslPolicy.CipherSuites) { @($sslPolicy.CipherSuites) } else { @() }
        }
    }

    # --- WafConfiguration ---
    $wafConfigObj = $null
    if ($appGw.WebApplicationFirewallConfiguration) {
        $wafCfg = $appGw.WebApplicationFirewallConfiguration
        $disabledRuleGroups = @()
        foreach ($drg in $wafCfg.DisabledRuleGroups) {
            $disabledRuleGroups += @{
                RuleGroupName = $drg.RuleGroupName
                Rules         = if ($drg.Rules) { @($drg.Rules) } else { @() }
            }
        }
        $exclusions = @()
        foreach ($excl in $wafCfg.Exclusions) {
            $exclusions += @{
                MatchVariable         = $excl.MatchVariable
                SelectorMatchOperator = $excl.SelectorMatchOperator
                Selector              = $excl.Selector
            }
        }
        $wafConfigObj = @{
            Enabled                  = $wafCfg.Enabled
            FirewallMode             = $wafCfg.FirewallMode
            RuleSetType              = $wafCfg.RuleSetType
            RuleSetVersion           = $wafCfg.RuleSetVersion
            DisabledRuleGroups       = $disabledRuleGroups
            Exclusions               = $exclusions
            RequestBodyCheck         = $wafCfg.RequestBodyCheck
            MaxRequestBodySizeInKb   = $wafCfg.MaxRequestBodySizeInKb
            FileUploadLimitInMb      = $wafCfg.FileUploadLimitInMb
        }
    }

    # --- Global Custom Error Configurations ---
    $globalCustomErrors = @()
    foreach ($ce in $appGw.CustomErrorConfigurations) {
        $globalCustomErrors += @{ StatusCode = $ce.StatusCode; CustomErrorPageUrl = $ce.CustomErrorPageUrl }
    }

    # --- Tags ---
    $tagsObj = @{}
    if ($appGw.Tag) { $tagsObj = $appGw.Tag }

    # 6 (cont.) Build the backup hashtable
    $backupData = @{
        BackupMetadata = @{
            BackupDate          = (Get-Date -Format "o")
            ScriptVersion       = "1.0.0"
            SourceResourceId    = $ResourceId
            SourceGatewayName   = $v1Name
            SourceResourceGroup = $resourceGroup
            SourceLocation      = $location
            SourceSkuTier       = $appGw.Sku.Tier
            SourceSkuName       = $appGw.Sku.Name
            SourceSkuCapacity   = $appGw.Sku.Capacity
        }
        Networking = @{
            VnetName                 = $vnetName
            VnetResourceGroup        = $vnetRg
            SubnetName               = $subnetName
            SubnetAddressPrefix      = $subnet.AddressPrefix
            SubnetId                 = $subnetId
            NetworkSecurityGroupId   = $nsgId
        }
        FrontendIPConfigurations      = $frontendIpConfigs
        FrontendPorts                 = $frontendPorts
        BackendAddressPools           = $backendPools
        BackendHttpSettingsCollection = $backendHttpSettings
        HealthProbes                  = $healthProbes
        SslCertificates               = $sslCertificates
        HttpListeners                 = $httpListeners
        RedirectConfigurations        = $redirectConfigs
        UrlPathMaps                   = $urlPathMaps
        RequestRoutingRules           = $requestRoutingRules
        SslPolicy                     = $sslPolicyObj
        WafConfiguration              = $wafConfigObj
        CustomErrorConfigurations     = $globalCustomErrors
        EnableHttp2                   = $appGw.EnableHttp2
        Tags                          = $tagsObj
    }

    # 7. Write JSON to BackupFile
    $backupDir = Split-Path -Parent $BackupFile
    if ($backupDir -and -not (Test-Path $backupDir)) {
        $null = New-Item -ItemType Directory -Path $backupDir -Force
    }
    $backupData | ConvertTo-Json -Depth 20 | Set-Content -Path $BackupFile -Encoding UTF8

    # 8. Print summary
    Write-Host ""
    Write-Host "=== Backup Summary ===" -ForegroundColor Cyan
    Write-Host "  Gateway Name : $v1Name"
    Write-Host "  SKU          : $($appGw.Sku.Tier) / $($appGw.Sku.Name) (capacity $($appGw.Sku.Capacity))"
    Write-Host "  Location     : $location"
    Write-Host "  Listeners    : $($appGw.HttpListeners.Count)"
    Write-Host "  Rules        : $($appGw.RequestRoutingRules.Count)"
    Write-Host "  Backend pools: $($appGw.BackendAddressPools.Count)"
    Write-Host "  SSL certs    : $($appGw.SslCertificates.Count)"
    Write-Host "  Backup file  : $(Resolve-Path $BackupFile)" -ForegroundColor Green
    Write-Host ""

    # 9. Remind the user about manual steps
    Write-Warning @"
Next steps:
  1. Review the backup file: $BackupFile
  2. MANUALLY DELETE the V1 Application Gateway '$v1Name' in resource group '$resourceGroup'.
     The V2 gateway will be deployed into the same subnet; the subnet must be free.
  3. Run Deploy mode:
       .\AzureAppGWMigrate.ps1 -Mode Deploy -BackupFile "$BackupFile" -AppGwName "<new-v2-name>" -AppGwResourceGroupName "<rg>"

NOTE: SSL certificate private keys cannot be exported by this script.
      If you use PFX certificates, ensure you have them available for re-upload in Deploy mode.
"@
}

# ---------------------------------------------------------------------------
# DEPLOY MODE – WAF Policy helper
# ---------------------------------------------------------------------------

Function New-WafPolicyFromBackup {
    param(
        [hashtable]  $WafConfig,
        [string]     $PolicyName,
        [string]     $ResourceGroupName,
        [string]     $Location
    )

    $policySetting = New-AzApplicationGatewayFirewallPolicySetting `
        -MaxFileUploadInMb $WafConfig.FileUploadLimitInMb `
        -MaxRequestBodySizeInKb $WafConfig.MaxRequestBodySizeInKb `
        -Mode Detection -State Disabled

    if ($WafConfig.FirewallMode -eq "Prevention") { $policySetting.Mode = "Prevention" }
    if ($WafConfig.Enabled)                       { $policySetting.State = "Enabled" }
    $policySetting.RequestBodyCheck = $WafConfig.RequestBodyCheck

    # Build managed rule set
    $ruleGroupOverrides = [System.Collections.ArrayList]@()
    if ($WafConfig.DisabledRuleGroups -and $WafConfig.DisabledRuleGroups.Count -gt 0) {
        $availableWafRuleSets = Get-AzApplicationGatewayAvailableWafRuleSets
        $ruleSet = $availableWafRuleSets.Value |
            Where-Object { $_.RuleSetType -eq $WafConfig.RuleSetType -and $_.RuleSetVersion -eq $WafConfig.RuleSetVersion }

        foreach ($drg in $WafConfig.DisabledRuleGroups) {
            $rules = [System.Collections.ArrayList]@()
            if ($drg.Rules -and $drg.Rules.Count -gt 0) {
                foreach ($ruleId in $drg.Rules) {
                    $null = $rules.Add((New-AzApplicationGatewayFirewallPolicyManagedRuleOverride -RuleId $ruleId))
                }
            }
            else {
                # Entire rule group disabled – disable every rule in it
                $matchingGroup = $ruleSet.RuleGroups | Where-Object { $_.RuleGroupName -eq $drg.RuleGroupName }
                foreach ($ruleId in $matchingGroup.Rules.RuleId) {
                    $null = $rules.Add((New-AzApplicationGatewayFirewallPolicyManagedRuleOverride -RuleId $ruleId))
                }
            }
            $null = $ruleGroupOverrides.Add(
                (New-AzApplicationGatewayFirewallPolicyManagedRuleGroupOverride -RuleGroupName $drg.RuleGroupName -Rule $rules)
            )
        }
    }

    $managedRuleSetParams = @{
        RuleSetType    = $WafConfig.RuleSetType
        RuleSetVersion = $WafConfig.RuleSetVersion
    }
    if ($ruleGroupOverrides.Count -gt 0) {
        $managedRuleSetParams["RuleGroupOverride"] = $ruleGroupOverrides
    }
    $managedRuleSet = New-AzApplicationGatewayFirewallPolicyManagedRuleSet @managedRuleSetParams

    # Build exclusions
    $exclusions = [System.Collections.ArrayList]@()
    if ($WafConfig.Exclusions) {
        foreach ($excl in $WafConfig.Exclusions) {
            if ($excl.MatchVariable -and $excl.SelectorMatchOperator -and $excl.Selector) {
                $null = $exclusions.Add(
                    (New-AzApplicationGatewayFirewallPolicyExclusion `
                        -MatchVariable $excl.MatchVariable `
                        -SelectorMatchOperator $excl.SelectorMatchOperator `
                        -Selector $excl.Selector)
                )
            }
            elseif ($excl.MatchVariable -and -not $excl.SelectorMatchOperator -and -not $excl.Selector) {
                $null = $exclusions.Add(
                    (New-AzApplicationGatewayFirewallPolicyExclusion `
                        -MatchVariable $excl.MatchVariable `
                        -SelectorMatchOperator "EqualsAny" `
                        -Selector "*")
                )
            }
        }
    }

    $managedRuleParams = @{ ManagedRuleSet = $managedRuleSet }
    if ($exclusions.Count -gt 0) { $managedRuleParams["Exclusion"] = $exclusions }
    $managedRule = New-AzApplicationGatewayFirewallPolicyManagedRule @managedRuleParams

    $wafPolicy = New-AzApplicationGatewayFirewallPolicy `
        -Name $PolicyName `
        -ResourceGroupName $ResourceGroupName `
        -PolicySetting $policySetting `
        -ManagedRule $managedRule `
        -Location $Location

    if (-not $wafPolicy) {
        Write-Error "Failed to create WAF policy '$PolicyName'."
        exit
    }
    Write-Host "WAF Policy '$PolicyName' created successfully."
    return $wafPolicy
}

# ---------------------------------------------------------------------------
# DEPLOY MODE
# ---------------------------------------------------------------------------

Function Invoke-DeployMode {
    # 1. Validate BackupFile
    if (-not (Test-Path $BackupFile)) {
        Write-Error "Backup file not found: $BackupFile"
        exit
    }

    $rawJson = Get-Content -Path $BackupFile -Raw -Encoding UTF8
    try {
        $backup = $rawJson | ConvertFrom-Json
    }
    catch {
        Write-Error "Backup file is not valid JSON: $BackupFile"
        exit
    }

    if (-not $backup.BackupMetadata) {
        Write-Error "Backup file is missing the 'BackupMetadata' section. Was it created by this script?"
        exit
    }

    # 2. Read and parse backup
    $meta     = $backup.BackupMetadata
    $netInfo  = $backup.Networking

    # 3. Default AppGwName
    if (-not $AppGwName) {
        $AppGwName = $meta.SourceGatewayName + "_v2"
        Write-Host "AppGwName not specified. Using default: $AppGwName"
    }

    # 4. Set Azure context
    $subscription = Get-SubscriptionFromResourceId $meta.SourceResourceId
    if (-not $subscription) {
        Write-Error "Cannot determine subscription from SourceResourceId in backup metadata."
        exit
    }
    $context = Set-AzContext -Subscription $subscription -ErrorVariable ctxErr -ErrorAction SilentlyContinue
    if ($ctxErr -or -not $context) {
        Write-Warning "Unable to set subscription '$subscription'. Please retry."
        exit
    }

    $location = $meta.SourceLocation

    # Target resource group
    if (-not $AppGwResourceGroupName) {
        $AppGwResourceGroupName = $meta.SourceResourceGroup
    }

    # 5. Create resource group if needed
    $rg = Get-AzResourceGroup -Name $AppGwResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Host "Resource group '$AppGwResourceGroupName' does not exist. Creating..."
        $null = New-AzResourceGroup -Name $AppGwResourceGroupName -Location $location
    }

    # 6. Subnet handling – reuse the SAME subnet; no new subnet created
    $vnetName   = $netInfo.VnetName
    $vnetRg     = $netInfo.VnetResourceGroup
    $subnetName = $netInfo.SubnetName

    $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRg -ErrorAction SilentlyContinue
    if (-not $vnet) {
        Write-Error "Virtual network '$vnetName' not found in resource group '$vnetRg'."
        exit
    }

    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet -ErrorAction SilentlyContinue
    if (-not $subnet) {
        Write-Warning ("The subnet '$subnetName' was not found in VNet '$vnetName'. " +
            "If the V1 gateway still exists and is holding the subnet, please delete it first and retry.")
        exit
    }

    Write-Host "Using existing subnet: $subnetName ($($subnet.AddressPrefix))"

    # Availability zones
    $zones = GetAvailabilityZoneMappings -Subscription $subscription -Location $location

    # --- SKU & Capacity ---
    $sku = GetApplicationGatewaySku -GwSkuTier $meta.SourceSkuTier

    $capacityMin, $capacityMax = GetCapacityUnits -AppgwSku @{
        Name     = $meta.SourceSkuName
        Capacity = $meta.SourceSkuCapacity
    }

    $autoscaleConfig = $null
    if ($DisableAutoscale) {
        $sku.Capacity = $capacityMax
    }
    else {
        $autoscaleConfig = New-AzApplicationGatewayAutoscaleConfiguration -MinCapacity $capacityMin -MaxCapacity $capacityMax
    }

    # --- Gateway IP configuration ---
    $gwIPConfig = New-AzApplicationGatewayIPConfiguration -Name "gatewayIPConfig" -Subnet $subnet

    # --- Public IP ---
    $pip = $null
    $isNewIPCreated = $false
    $publicFipData = $backup.FrontendIPConfigurations | Where-Object { $_.IsPublic -eq $true }

    if ($PrivateOnly) {
        Write-Host "PrivateOnly mode: skipping public IP creation. Gateway will have private frontend only."
        $pip = $null
    }
    elseif ($PublicIpResourceId) {
        $pipResource = Get-AzResource -ResourceId $PublicIpResourceId -ErrorAction SilentlyContinue
        if (-not $pipResource) {
            Write-Warning "Public IP resource '$PublicIpResourceId' not found."
            exit
        }
        $pipRg   = Get-ResourceGroupFromResourceId $PublicIpResourceId
        $pipName = Get-NameFromId $PublicIpResourceId
        $pip     = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $pipRg -ErrorAction SilentlyContinue
        if (-not $pip) {
            Write-Warning "Failed to retrieve Public IP '$pipName' from '$pipRg'."
            exit
        }
    }
    elseif ($publicFipData) {
        $pipName = $AppGwName + "-IP"
        $existingPip = Get-AzPublicIpAddress -ResourceGroupName $AppGwResourceGroupName -Name $pipName -ErrorAction SilentlyContinue
        if ($existingPip) {
            Write-Warning "Public IP '$pipName' already exists in '$AppGwResourceGroupName'. Delete it or supply -PublicIpResourceId."
            exit
        }
        $pip = New-AzPublicIpAddress `
            -ResourceGroupName $AppGwResourceGroupName `
            -Name $pipName `
            -Location $location `
            -AllocationMethod Static `
            -Sku Standard `
            -Zone $zones `
            -Force
        $isNewIPCreated = $true
        Write-Host "Created Public IP: $pipName"
    }

    # --- Frontend IP configurations ---
    $fipList = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayFrontendIPConfiguration]
    $fipNameMap = @{}  # backup name -> new PSApplicationGatewayFrontendIPConfiguration

    foreach ($fipData in $backup.FrontendIPConfigurations) {
        if ($fipData.IsPublic) {
            if ($PrivateOnly) {
                Write-Host "PrivateOnly mode: skipping public frontend IP '$($fipData.Name)'."
                continue
            }
            if (-not $pip) {
                Write-Warning "Backup has a public frontend IP but no Public IP resource is available."
                exit
            }
            $newFip = New-AzApplicationGatewayFrontendIPConfig -Name $fipData.Name -PublicIPAddress $pip
        }
        else {
            $privateIp = $null
            if ($PrivateIpAddress) {
                $privateIp = $PrivateIpAddress
            }
            elseif ($fipData.PrivateIPAllocationMethod -eq "Static" -and $fipData.PrivateIPAddress) {
                $privateIp = $fipData.PrivateIPAddress
            }

            if ($privateIp) {
                $newFip = New-AzApplicationGatewayFrontendIPConfig -Name $fipData.Name -PrivateIPAddress $privateIp -Subnet $subnet
            }
            else {
                $newFip = New-AzApplicationGatewayFrontendIPConfig -Name $fipData.Name -Subnet $subnet
            }
        }
        $fipList.Add($newFip)
        $fipNameMap[$fipData.Name] = $newFip
    }

    # Auto-create private frontend IP when PrivateOnly mode has no private IPs in backup.
    if ($PrivateOnly -and $fipList.Count -eq 0) {
        Write-Host "PrivateOnly mode: backup had no private frontend IP. Creating one dynamically from subnet."
        $autoPrivateFipName = "appGatewayPrivateFrontendIP"
        $newFip = if ($PrivateIpAddress) {
            New-AzApplicationGatewayFrontendIPConfig -Name $autoPrivateFipName -PrivateIPAddress $PrivateIpAddress -Subnet $subnet
        } else {
            New-AzApplicationGatewayFrontendIPConfig -Name $autoPrivateFipName -Subnet $subnet
        }
        $fipList.Add($newFip)
        # Map all original public fip names to this new private fip so listeners still resolve
        foreach ($fipData in $backup.FrontendIPConfigurations) {
            $fipNameMap[$fipData.Name] = $newFip
        }
        Write-Host "Created private frontend IP: $autoPrivateFipName"
    }

    # --- Frontend ports ---
    $portList = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayFrontendPort]
    $portNameMap = @{}

    foreach ($portData in $backup.FrontendPorts) {
        $newPort = New-AzApplicationGatewayFrontendPort -Name $portData.Name -Port $portData.Port
        $portList.Add($newPort)
        $portNameMap[$portData.Name] = $newPort
    }

    # --- Backend address pools ---
    $poolList = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayBackendAddressPool]
    $poolNameMap = @{}

    foreach ($poolData in $backup.BackendAddressPools) {
        if ($poolData.Addresses -and $poolData.Addresses.Count -gt 0) {
            $newPool = New-AzApplicationGatewayBackendAddressPool -Name $poolData.Name -BackendIPAddresses $poolData.Addresses
        }
        else {
            $newPool = New-AzApplicationGatewayBackendAddressPool -Name $poolData.Name
        }
        $poolList.Add($newPool)
        $poolNameMap[$poolData.Name] = $newPool
    }

    # --- Health probes ---
    $probeList = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayProbe]
    $probeNameMap = @{}

    foreach ($probeData in $backup.HealthProbes) {
        $probeParams = @{
            Name               = $probeData.Name
            Protocol           = $probeData.Protocol
            Path               = $probeData.Path
            Interval           = $probeData.Interval
            Timeout            = $probeData.Timeout
            UnhealthyThreshold = $probeData.UnhealthyThreshold
        }
        if ($probeData.PickHostNameFromBackendHttpSettings) {
            $probeParams["PickHostNameFromBackendHttpSettings"] = $true
        }
        elseif ($probeData.Host) {
            $probeParams["HostName"] = $probeData.Host
        }

        if ($probeData.Match) {
            $statusCodes = if ($probeData.Match.StatusCodes) { @($probeData.Match.StatusCodes) } else { @("200-399") }
            $matchCfg    = New-AzApplicationGatewayProbeHealthResponseMatch -StatusCode $statusCodes
            if ($probeData.Match.Body) { $matchCfg.Body = $probeData.Match.Body }
            $probeParams["Match"] = $matchCfg
        }

        $newProbe = New-AzApplicationGatewayProbeConfig @probeParams
        $probeList.Add($newProbe)
        $probeNameMap[$probeData.Name] = $newProbe
    }

    # --- SSL certificates ---
    # NOTE: Only public cert data is backed up; PFX private keys cannot be exported.
    # Certificates with a KeyVaultSecretId are relinked; others are skipped with a warning.
    $sslCertList = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewaySslCertificate]
    $sslCertNameMap = @{}

    foreach ($certData in $backup.SslCertificates) {
        if ($certData.KeyVaultSecretId) {
            $newCert = New-AzApplicationGatewaySslCertificate -Name $certData.Name -KeyVaultSecretId $certData.KeyVaultSecretId
            $sslCertList.Add($newCert)
            $sslCertNameMap[$certData.Name] = $newCert
        }
        else {
            Write-Warning ("SSL certificate '$($certData.Name)' has no KeyVault secret ID. " +
                "PFX private keys cannot be migrated automatically. " +
                "This certificate will be skipped – manually add it after deployment.")
        }
    }

    # --- Backend HTTP settings ---
    $settingsList = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayBackendHttpSettings]
    $settingsNameMap = @{}
    $atleastOneHTTPSBackend = $false

    foreach ($s in $backup.BackendHttpSettingsCollection) {
        $settingParams = @{
            Name                = $s.Name
            Port                = $s.Port
            Protocol            = $s.Protocol
            CookieBasedAffinity = $s.CookieBasedAffinity
            RequestTimeout      = $s.RequestTimeout
        }
        if ($s.Protocol -eq "Https") { $atleastOneHTTPSBackend = $true }
        if ($s.PickHostNameFromBackendAddress) { $settingParams["PickHostNameFromBackendAddress"] = $true }
        elseif ($s.HostName) { $settingParams["HostName"] = $s.HostName }
        if ($s.Path) { $settingParams["Path"] = $s.Path }
        if ($s.ProbeName -and $probeNameMap.ContainsKey($s.ProbeName)) {
            $settingParams["Probe"] = $probeNameMap[$s.ProbeName]
        }
        if ($s.ConnectionDraining -and $s.ConnectionDraining.Enabled) {
            $settingParams["ConnectionDrainingTimeoutInSec"] = $s.ConnectionDraining.DrainTimeoutInSec
        }
        $newSetting = New-AzApplicationGatewayBackendHttpSetting @settingParams
        $settingsList.Add($newSetting)
        $settingsNameMap[$s.Name] = $newSetting
    }

    # --- HTTP Listeners ---
    $listenerList = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayHttpListener]
    $listenerNameMap = @{}
    $atleastOneHTTPSListener = $false

    foreach ($lData in $backup.HttpListeners) {
        if (-not $fipNameMap.ContainsKey($lData.FrontendIPConfigurationName)) {
            Write-Warning "Listener '$($lData.Name)': FrontendIPConfiguration '$($lData.FrontendIPConfigurationName)' not found. Skipping."
            continue
        }
        if (-not $portNameMap.ContainsKey($lData.FrontendPortName)) {
            Write-Warning "Listener '$($lData.Name)': FrontendPort '$($lData.FrontendPortName)' not found. Skipping."
            continue
        }

        $listenerParams = @{
            Name                        = $lData.Name
            Protocol                    = $lData.Protocol
            FrontendIPConfiguration     = $fipNameMap[$lData.FrontendIPConfigurationName]
            FrontendPort                = $portNameMap[$lData.FrontendPortName]
            RequireServerNameIndication = $lData.RequireServerNameIndication
        }
        if ($lData.HostName) { $listenerParams["HostName"] = $lData.HostName }

        if ($lData.Protocol -eq "Https") {
            $atleastOneHTTPSListener = $true
            if ($lData.SslCertificateName -and $sslCertNameMap.ContainsKey($lData.SslCertificateName)) {
                $listenerParams["SslCertificate"] = $sslCertNameMap[$lData.SslCertificateName]
            }
            elseif ($lData.SslCertificateName) {
                Write-Warning ("Listener '$($lData.Name)' references SSL cert '$($lData.SslCertificateName)' " +
                    "which was not migrated. The listener will be created without the certificate.")
            }
        }

        $newListener = New-AzApplicationGatewayHttpListener @listenerParams
        if ($lData.CustomErrorConfigurations -and $lData.CustomErrorConfigurations.Count -gt 0) {
            $newListener.CustomErrorConfigurations = $lData.CustomErrorConfigurations
        }
        $listenerList.Add($newListener)
        $listenerNameMap[$lData.Name] = $newListener
    }

    # --- Redirect configurations ---
    $redirectList = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayRedirectConfiguration]
    $redirectNameMap = @{}

    foreach ($rData in $backup.RedirectConfigurations) {
        $redirectParams = @{
            Name            = $rData.Name
            RedirectType    = $rData.RedirectType
            IncludePath     = $rData.IncludePath
            IncludeQueryString = $rData.IncludeQueryString
        }
        if ($rData.TargetListenerName -and $listenerNameMap.ContainsKey($rData.TargetListenerName)) {
            $redirectParams["TargetListener"] = $listenerNameMap[$rData.TargetListenerName]
        }
        elseif ($rData.TargetUrl) {
            $redirectParams["TargetUrl"] = $rData.TargetUrl
        }
        $newRedirect = New-AzApplicationGatewayRedirectConfiguration @redirectParams
        $redirectList.Add($newRedirect)
        $redirectNameMap[$rData.Name] = $newRedirect
    }

    # --- URL path maps ---
    $urlPathMapList = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayUrlPathMap]
    $urlPathMapNameMap = @{}

    foreach ($uData in $backup.UrlPathMaps) {
        $pathRules = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayPathRule]

        foreach ($prData in $uData.PathRules) {
            $pathRuleParams = @{
                Name  = $prData.Name
                Paths = @($prData.Paths)
            }
            if ($prData.BackendAddressPoolName -and $poolNameMap.ContainsKey($prData.BackendAddressPoolName)) {
                $pathRuleParams["BackendAddressPool"] = $poolNameMap[$prData.BackendAddressPoolName]
            }
            if ($prData.BackendHttpSettingsName -and $settingsNameMap.ContainsKey($prData.BackendHttpSettingsName)) {
                $pathRuleParams["BackendHttpSettings"] = $settingsNameMap[$prData.BackendHttpSettingsName]
            }
            if ($prData.RedirectConfigurationName -and $redirectNameMap.ContainsKey($prData.RedirectConfigurationName)) {
                $pathRuleParams["RedirectConfiguration"] = $redirectNameMap[$prData.RedirectConfigurationName]
            }
            $null = $pathRules.Add((New-AzApplicationGatewayPathRuleConfig @pathRuleParams))
        }

        $urlPathMapParams = @{
            Name      = $uData.Name
            PathRules = $pathRules
        }
        if ($uData.DefaultBackendAddressPoolName -and $poolNameMap.ContainsKey($uData.DefaultBackendAddressPoolName)) {
            $urlPathMapParams["DefaultBackendAddressPool"] = $poolNameMap[$uData.DefaultBackendAddressPoolName]
        }
        if ($uData.DefaultBackendHttpSettingsName -and $settingsNameMap.ContainsKey($uData.DefaultBackendHttpSettingsName)) {
            $urlPathMapParams["DefaultBackendHttpSettings"] = $settingsNameMap[$uData.DefaultBackendHttpSettingsName]
        }
        if ($uData.DefaultRedirectConfigurationName -and $redirectNameMap.ContainsKey($uData.DefaultRedirectConfigurationName)) {
            $urlPathMapParams["DefaultRedirectConfiguration"] = $redirectNameMap[$uData.DefaultRedirectConfigurationName]
        }
        $newUrlPathMap = New-AzApplicationGatewayUrlPathMapConfig @urlPathMapParams
        $urlPathMapList.Add($newUrlPathMap)
        $urlPathMapNameMap[$uData.Name] = $newUrlPathMap
    }

    # --- Request routing rules ---
    $ruleList = New-Object System.Collections.Generic.List[Microsoft.Azure.Commands.Network.Models.PSApplicationGatewayRequestRoutingRule]
    $priority = 100

    foreach ($ruleData in $backup.RequestRoutingRules) {
        if (-not $listenerNameMap.ContainsKey($ruleData.HttpListenerName)) {
            Write-Warning "Rule '$($ruleData.Name)': HttpListener '$($ruleData.HttpListenerName)' not found. Skipping rule."
            continue
        }
        $ruleParams = @{
            Name          = $ruleData.Name
            RuleType      = $ruleData.RuleType
            HttpListener  = $listenerNameMap[$ruleData.HttpListenerName]
            Priority      = $priority
        }
        if ($ruleData.BackendAddressPoolName -and $poolNameMap.ContainsKey($ruleData.BackendAddressPoolName) -and
            $ruleData.BackendHttpSettingsName -and $settingsNameMap.ContainsKey($ruleData.BackendHttpSettingsName)) {
            $ruleParams["BackendAddressPool"]     = $poolNameMap[$ruleData.BackendAddressPoolName]
            $ruleParams["BackendHttpSettings"]    = $settingsNameMap[$ruleData.BackendHttpSettingsName]
        }
        elseif ($ruleData.RedirectConfigurationName -and $redirectNameMap.ContainsKey($ruleData.RedirectConfigurationName)) {
            $ruleParams["RedirectConfiguration"] = $redirectNameMap[$ruleData.RedirectConfigurationName]
        }
        elseif ($ruleData.UrlPathMapName -and $urlPathMapNameMap.ContainsKey($ruleData.UrlPathMapName)) {
            $ruleParams["UrlPathMap"] = $urlPathMapNameMap[$ruleData.UrlPathMapName]
        }
        else {
            Write-Warning "Rule '$($ruleData.Name)': no backend, redirect or path map found. Skipping."
            continue
        }

        $null = $ruleList.Add((New-AzApplicationGatewayRequestRoutingRule @ruleParams))
        $priority += 50
    }

    # --- SSL Policy ---
    $sslPolicyObj = $null
    if ($backup.SslPolicy) {
        $sp = $backup.SslPolicy
        $sslPolicyParams = @{}
        if ($sp.PolicyType) { $sslPolicyParams["PolicyType"] = $sp.PolicyType }
        if ($sp.PolicyName) { $sslPolicyParams["PolicyName"] = $sp.PolicyName }
        if ($sp.MinProtocolVersion) { $sslPolicyParams["MinProtocolVersion"] = $sp.MinProtocolVersion }
        if ($sp.CipherSuites -and $sp.CipherSuites.Count -gt 0) {
            $sslPolicyParams["CipherSuite"] = @($sp.CipherSuites)
        }
        if ($sslPolicyParams.Count -gt 0) {
            $sslPolicyObj = New-AzApplicationGatewaySslPolicy @sslPolicyParams
        }
    }

    # --- Tags ---
    $tags = @{}
    if ($backup.Tags) {
        foreach ($key in $backup.Tags.PSObject.Properties.Name) {
            $tags[$key] = $backup.Tags.$key
        }
    }
    $tags["CreatedUsing"] = "AzureAppGWMigrateScript"
    if ($atleastOneHTTPSBackend)  { $tags["RelaxBackendSSLCertificateValidations"] = "true" }

    # --- WAF policy (WAF_v2 only) ---
    $wafPolicy       = $null
    $isWafCreated    = $false
    if ($meta.SourceSkuTier -eq "WAF") {
        if (-not $WafPolicyName) { $WafPolicyName = $AppGwName + "_WAFPolicy" }
        $existingWaf = Get-AzApplicationGatewayFirewallPolicy -ResourceGroupName $AppGwResourceGroupName -Name $WafPolicyName -ErrorAction SilentlyContinue
        if ($existingWaf) {
            Write-Warning "WAF Policy '$WafPolicyName' already exists. Delete it or supply a unique -WafPolicyName."
            exit
        }
        $wafCfgData = if ($backup.WafConfiguration) {
            @{
                Enabled                = $backup.WafConfiguration.Enabled
                FirewallMode           = $backup.WafConfiguration.FirewallMode
                RuleSetType            = $backup.WafConfiguration.RuleSetType
                RuleSetVersion         = $backup.WafConfiguration.RuleSetVersion
                DisabledRuleGroups     = if ($backup.WafConfiguration.DisabledRuleGroups) { @($backup.WafConfiguration.DisabledRuleGroups) } else { @() }
                Exclusions             = if ($backup.WafConfiguration.Exclusions) { @($backup.WafConfiguration.Exclusions) } else { @() }
                RequestBodyCheck       = $backup.WafConfiguration.RequestBodyCheck
                MaxRequestBodySizeInKb = $backup.WafConfiguration.MaxRequestBodySizeInKb
                FileUploadLimitInMb    = $backup.WafConfiguration.FileUploadLimitInMb
            }
        }
        else {
            @{
                Enabled                = $false
                FirewallMode           = "Detection"
                RuleSetType            = "Microsoft_DefaultRuleSet"
                RuleSetVersion         = "2.1"
                DisabledRuleGroups     = @()
                Exclusions             = @()
                RequestBodyCheck       = $true
                MaxRequestBodySizeInKb = 128
                FileUploadLimitInMb    = 100
            }
        }
        $wafPolicy    = New-WafPolicyFromBackup -WafConfig $wafCfgData -PolicyName $WafPolicyName -ResourceGroupName $AppGwResourceGroupName -Location $location
        $isWafCreated = $true
    }

    # --- Verify no gateway with the same name exists ---
    $existingGw = Get-AzApplicationGateway -Name $AppGwName -ResourceGroupName $AppGwResourceGroupName -ErrorAction SilentlyContinue
    if ($existingGw) {
        Write-Warning "Application Gateway '$AppGwName' already exists in '$AppGwResourceGroupName'. Provide a different -AppGwName."
        exit
    }

    # --- Build New-AzApplicationGateway params ---
    $newGwParams = @{
        Name                          = $AppGwName
        ResourceGroupName             = $AppGwResourceGroupName
        Location                      = $location
        Sku                           = $sku
        GatewayIPConfigurations       = $gwIPConfig
        FrontendIpConfigurations      = $fipList
        FrontendPorts                 = $portList
        BackendAddressPools           = $poolList
        BackendHttpSettingsCollection = $settingsList
        HttpListeners                 = $listenerList
        RequestRoutingRules           = $ruleList
        Tag                           = $tags
        Force                         = $true
    }

    if ($autoscaleConfig)         { $newGwParams["AutoScaleConfiguration"] = $autoscaleConfig }
    if ($backup.EnableHttp2)      { $newGwParams["EnableHttp2"] = $true }
    if ($probeList.Count -gt 0)   { $newGwParams["Probes"] = $probeList }
    if ($sslCertList.Count -gt 0) { $newGwParams["SslCertificates"] = $sslCertList }
    if ($redirectList.Count -gt 0){ $newGwParams["RedirectConfigurations"] = $redirectList }
    if ($urlPathMapList.Count -gt 0){ $newGwParams["UrlPathMaps"] = $urlPathMapList }
    if ($sslPolicyObj)            { $newGwParams["SslPolicy"] = $sslPolicyObj }
    if ($zones)                   { $newGwParams["Zone"] = $zones }
    if ($isWafCreated -and $wafPolicy) { $newGwParams["FirewallPolicyId"] = $wafPolicy.Id }
    if ($backup.CustomErrorConfigurations -and $backup.CustomErrorConfigurations.Count -gt 0) {
        $newGwParams["CustomErrorConfiguration"] = $backup.CustomErrorConfigurations
    }

    Write-Host "Creating new V2 Application Gateway '$AppGwName'. This may take ~7 minutes..." -ForegroundColor Yellow
    $newAppGw = New-AzApplicationGateway @newGwParams

    if (-not $newAppGw) {
        Write-Error "Creation of V2 Application Gateway failed. Please retry or contact Azure Support."
        exit
    }

    Write-Host ""
    Write-Host "=== Deploy Summary ===" -ForegroundColor Cyan
    Write-Host "  V2 Gateway Name : $($newAppGw.Name)"
    Write-Host "  Resource Group  : $AppGwResourceGroupName"
    Write-Host "  Location        : $location"
    Write-Host "  Subnet          : $subnetName ($($subnet.AddressPrefix))"
    if ($PrivateOnly) {
        Write-Host "  Mode            : Private Only (no public IP)"
    } elseif ($pip) {
        Write-Host "  Public IP       : $($pip.IpAddress)"
    }
    Write-Host ""

    # Post-deploy backend health validation
    if ($ValidateBackendHealth) {
        Write-Host "Validating backend health for V2 gateway..."
        $health = Get-AzApplicationGatewayBackendHealth -Name $AppGwName -ResourceGroupName $AppGwResourceGroupName
        foreach ($pool in $health.BackendAddressPools) {
            foreach ($httpSettingCollection in $pool.BackendHttpSettingsCollection) {
                foreach ($server in $httpSettingCollection.Servers) {
                    $status = $server.Health
                    if ($status -eq "Healthy") {
                        Write-Host "  [OK]      $($server.Address) - $status"
                    }
                    else {
                        Write-Warning "  [WARNING] $($server.Address) - $status"
                    }
                }
            }
        }
    }

    return $newAppGw
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if (!(Get-Module -ListAvailable -Name Az.Network)) {
    Write-Error ("Az module is required. Install it with: Install-Module Az")
    exit
}

switch ($Mode) {
    "Backup" { Invoke-BackupMode }
    "Deploy" { Invoke-DeployMode }
}
