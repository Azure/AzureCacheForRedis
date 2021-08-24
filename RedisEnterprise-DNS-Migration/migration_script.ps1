###############################################################################
#### Redis Enterprise Tier - private endpoint DNS Migration Script         ####
####                                                                       ####
#### This script is written to help migrate from the old private dns zone  ####
#### to the newer one, while copying over all relevant A records and       ####
#### transferring vnet links, etc.                                         ####
####                                                                       ####
#### The old zone had the region as the first value (i.e.                  ####
#### westus.privatelink.redisenterprise.cache.azure.net) and this caused   ####
#### issues with automatic creation of A records during the private        ####
#### endpoint create flow. This script should resolve that.                ####
###############################################################################
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern("(^([0-9A-Fa-f]{8}[-][0-9A-Fa-f]{4}[-][0-9A-Fa-f]{4}[-][0-9A-Fa-f]{4}[-][0-9A-Fa-f]{12})$)")] # Sub ID needs to match guid regex
    [System.String]
    $SubscriptionId
)
$ErrorActionPreference = "Stop"
$OLD_DNS_ZONE_PATTERN = '^[\w\d]+\.privatelink\..*redisenterprise.*$'
$NEW_DNS_ZONE_PATTERN = '^privatelink\..*redisenterprise.*$'
# Function definitions
function Login($SubscriptionId) {
    $context = Get-AzContext

    if (!$context -or ($context.Subscription.Id -ne $SubscriptionId)) {
        Write-Host "Connecting to Azure..."
        Connect-AzAccount -Subscription $SubscriptionId
    } 
    else {
        Write-Host "Context set to: SubscriptionId '$SubscriptionId'"
    }
}

# This function is meant to avoid making assumptions about what resource group the user wants to create their private dns zone in. 
# It suggests a default and error checks for user so they can pick a correct value
function PromptForInputs-New-AzPrivateDnsZone {
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Name,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ResourceGroupName,
        [bool] $IncludeDefault = $true
    )
    $rgNames = (Get-AzResourceGroup).ResourceGroupName 
    $lowerRgNames = $rgNames | ForEach-Object { $_.ToLower() }

    $default = $ResourceGroupName
    if($IncludeDefault) {
        Write-Host "Enter the resource group name for '$Name' (default: [$default])" -ForegroundColor Blue
    } else {
        Write-Host "Enter the resource group name for '$Name'" -ForegroundColor Blue
    }
    if (!($value = Read-Host )) { 
        if($IncludeDefault) {
            $value = $default 
        } else {
            $value = $null
        }
    }
    if ($null -eq $value -or !($lowerRgNames -contains $value.ToLower())) {
        Write-Host "'$value' is not an existing resource group. Resource group must be one of the following: $($rgNames -join ", ")" -ForegroundColor Blue
        return PromptForInputs-New-AzPrivateDnsZone $Name $ResourceGroupName $IncludeDefault
    }
    # Determine if one already in this resource group
    $existingZone = $null
    try {
        $existingZone = Get-AzPrivateDnsZone -ResourceGroupName $value -Name $Name -ErrorAction SilentlyContinue
    } catch {}
    if (!($null -eq $existingZone)) {
        $existingLinks = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $existingZone.ResourceGroupName -ZoneName $existingZone.Name 
        if($null -eq $existingLinks) {
            Write-Host "An existing zone with the name '$Name' was already found in the resource group '$value', but it has no existing network links. Using that one instead." -ForegroundColor Yellow
            return $existingZone
        } else {
            Write-Host "An existing zone with the name '$Name' was already found in the reosurce group '$value' and is linked to VNet $($existingLinks.VirtualNetworkId)." -ForegroundColor Yellow
            Write-Host "This zone can be linked to multiple VNets if there is no cache that needs to be accessed from more than one of the VNets. This limitation is because otherwise the DNS A records will clash." -ForegroundColor Yellow
            $shouldUseExisting = AskForConfirmation "Do you want to use the existing zone? (If 'No', the new zone will need to be created in another resource group)"
            if($shouldUseExisting) {
                return $existingZone
            } else {
                return PromptForInputs-New-AzPrivateDnsZone $Name $ResourceGroupName $false
            }
        }

    }

    return New-AzPrivateDnsZone -ResourceGroupName $value -Name $Name
}

# Filters private DNS zones by a regex
function Get-PrivateDNSZonesMatchingPattern([System.String]$Pattern, $PrivateDnsZones = $(Get-AzPrivateDnsZone) ) {
    return $PrivateDnsZones | Where-Object Name -imatch $Pattern
}

# This should return a map that maps between a virtual network and all of its associated private endpoints
function Initialize-PrivateLinkMap() {
    $map = @{};

    $redisEnterprisePrivateEndpoints = Get-AzPrivateEndpoint | Where-Object {
        $connections = $_.PrivateLinkServiceConnections | Where-Object {
            return $_.GroupIds[0] -eq "redisEnterprise"
        };
        if($null -ne $connections) {
            return $true;
        } else {
            return $false
        }
    }

    foreach($redisPrivateLink in $redisEnterprisePrivateEndpoints) {
        $vnetId = ($redisPrivateLink.Subnet.Id -Split "/subnet")[0]
        if($null -eq $map[$vnetId]) {
            $map[$vnetId] = @() # Create a new list

        }
        $map[$vnetId] = $map[$vnetId] + $redisPrivateLink # Append link to list of link associated with this virtual network
    }

    return $map
}

# Returns a map between virtual networks and the associated private dns zones
function Initialize-PrivateDnsZoneMap() {
    $map = @{};
    foreach($zone in $(Get-AzPrivateDnsZone)) {
        foreach($link in $(Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $zone.ResourceGroupName -ZoneName $zone.Name))
        {
            if($null -eq $map[$link.VirtualNetworkId]) {
                $map[$link.VirtualNetworkId] = @() # Create a new list

            }
            $map[$link.VirtualNetworkId] = $map[$link.VirtualNetworkId] + $zone # Append zone to list of zones associated with this virtual network
        }
    }

    return $map
}

# This function loops through each VNet, 
# extracts the correct zone name from the resoruces attached to private endpoints (which are enterprise caches), 
# creates or confirms the zones exist, 
# Links the zones to their VNets
# and then ensures the zones have the correct Dns zone groups (A records)
function Migrate-Vnets($PrivateLinkMap, $PrivateDnsZonesMap) {
    foreach ($vnet in $PrivateLinkMap.GetEnumerator()) {
        $vnetResource = Get-AzResource -ResourceId $vnet.Name
        $zones = $PrivateDnsZonesMap[$vnet.Name]
        $privateLinks = $PrivateLinkMap[$vnet.Name]
        # If there are no private endpoints, there's nothing to migrate.
        if($null -ne $privateLinks) {
            Write-Host "Starting migration process for VNet: $($vnet.Name). See section 'How to migrate to the new private DNS zone' in the migration document for more context." -ForegroundColor Yellow
            $oldZones = $zones | Where-Object Name -imatch $OLD_DNS_ZONE_PATTERN
            if($null -ne $oldZones) {
                Write-Host "Found old zones with names [$($oldZones.Name -join ",")] linked to this VNet. They need to be unlinked in a later step." -ForegroundColor Yellow
            }
            $newZone = $null
            if($null -eq ($zones | Where-Object Name -imatch $NEW_DNS_ZONE_PATTERN)) {
                # We don't currently have a private DNS zone with the new pattern for this VNet... time to create one
                $newName = $null
                for($i = 0; $i -lt $privateLinks.Count; $i++) {
                    $newName = ExtractPrivateDnsZoneNameFromPrivateLink $privateLinks[$i]
                    if($null -eq $newName) {
                        continue;
                    }
                    break;
                }
                if ($null -eq $newName) {
                    Write-Host "None of the private endpoints for virtual network $($vnet.Name) have an existing cache attached to them. Cannot infer private dns zone name and thus cannot continue. Moving on to next vnet" -ForegroundColor Red
                    continue
                }
                
                Write-Host "[Steps 2 and 3 under section 'How to migrate to the new private DNS zone' in migration document]" -ForegroundColor Yellow
                $shouldContinue = AskForConfirmation "Private dns zones with the new pattern weren't found connected to the VNet... Do you want to create one and link it to the VNet $($vnet.Name)?"

                if($shouldContinue -eq $false) {
                    Write-Host "Moving on to next VNet."
                        continue
                }
                $newZone = PromptForInputs-New-AzPrivateDnsZone -ResourceGroupName $vnetResource.ResourceGroupName -Name $newName
                New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $newZone.ResourceGroupName -ZoneName $newName -Name (New-Guid).Guid -VirtualNetworkId $vnetResource.ResourceId
            } else {
                # If any of the zones already are of the new pattern we'll be using that zone to transfer all of the old records to. 
                # If there is one, it will always be the only one due to limiation on linking zones with the same name
                $newZone = $zones | Where-Object Name -imatch $NEW_DNS_ZONE_PATTERN
            }
            Write-Host "Finished confirming VNet $($vnet.Name) has the correct private DNS Zone linked." -ForegroundColor Yellow
            Write-Host "Confirming zone has the correct A records added..." -ForegroundColor Yellow
            foreach ($privateLink in $privateLinks) {
                $privateDnsZoneConfig = New-AzPrivateDnsZoneConfig -Name ($newZone.Name -Replace "\.", "-") -PrivateDnsZoneId $newZone.ResourceId
                $shouldProceed = $false
                $isDisconnected = $privateLink.PrivateLinkServiceConnections.PrivateLinkServiceConnectionState.Status.ToLower() -eq 'disconnected'
                if(!$isDisconnected) {
                    $existingGroup = Get-AzPrivateDnsZoneGroup -ResourceGroupName $privateLink.ResourceGroupName -PrivateEndpointName $privateLink.Name
                    if($null -ne $existingGroup -and $existingGroup.Count -gt 0) {
                        
                        $shouldProceed = ShouldRemovePrivateDnsZoneGroup $existingGroup $privateLink $newZone
                        if ($shouldProceed) {
                            Write-Host "Removing old Dns zone group (A record) for private endpoint '$($privateLink.Name)'" -ForegroundColor Yellow
                            Remove-AzPrivateDnsZoneGroup -PrivateEndpointName $privateLink.Name -Name $existingGroup.Name -ResourceGroupName $privateLink.ResourceGroupName -Force
                        } 
                    } else {
                        
                        Write-Host "[Step 4 under section 'How to migrate to the new private DNS zone' in migration document]" -ForegroundColor Yellow
                        $shouldProceed = AskForConfirmation "Private endpoint '$($privateLink.Name)' has no associated Dns zone group. These groups automatically manage the A records creation and deletion for the private endpoint. Do you want to create a new one?"
                    }
                    if($shouldProceed) {
                            Write-Host "Creating new Dns zone group (A record) for private endpoint '$($privateLink.Name)'" -ForegroundColor Yellow
                            New-AzPrivateDnsZoneGroup -ResourceGroupName $privateLink.ResourceGroupName -PrivateEndpointName $privateLink.Name -Name ($privateLink.Name + "-" + $privateDnsZoneConfig.Name) -PrivateDnsZoneConfig $privateDnsZoneConfig
                    }
                }
            }
            Write-Host "Finished migration process for VNet: $($vnet.Name)." -ForegroundColor Green
        }
    }
    Write-Host "Finished configuring VNets with correct private DNS zones." -ForegroundColor Green
}

function ShouldRemovePrivateDnsZoneGroup($existingGroup, $privateLink, $newZone) {
    if ( $null -eq $existingGroup.PrivateDnsZoneConfigs) {
                            
        Write-Host "[Step 4 under section 'How to migrate to the new private DNS zone' in migration document]" -ForegroundColor Yellow
        return AskForConfirmation "Private endpoint '$($privateLink.Name)' is already tied to a Dns zone group (A record) which has no associated DNS zones. Do you want to remove the existing group and add a new one?"
    }
    if (!($existingGroup.PrivateDnsZoneConfigs.PrivateDnsZoneId.ToLower() -contains $newZone.ResourceId.ToLower())) {
        
        Write-Host "[Step 4 under section 'How to migrate to the new private DNS zone' in migration document]" -ForegroundColor Yellow
        return AskForConfirmation "Private endpoint '$($privateLink.Name)' is already tied to a Dns zone group (A record) that is not associated with this DNS Zone. Do you want to remove the existing group and add a new one?"
    }
    $peIpAddresses = ((Get-AzNetworkInterface -ResourceId $privateLink.NetworkInterfaces.Id).IpConfigurations.PrivateIPAddress)
    $zoneARecordIpAddresses = ($newZone | Get-AzPrivateDnsRecordSet | Where-Object RecordType -eq A).Records.Ipv4Address
    if (!($zoneARecordIpAddresses -contains $peIpAddresses)) {
        
        Write-Host "[Step 4 under section 'How to migrate to the new private DNS zone' in migration document]" -ForegroundColor Yellow
        return AskForConfirmation "Private endpoint '$($privateLink.Name)' has an IP address of $($peIpAddresses) which is not contained in the private DNS zones list of A records which include [$($zoneARecordIpAddresses -join ", ")]? Do you want to and add a new one Dns zone group to fix this?"
    }
    return $false
}
function AskForConfirmation($confirmationMessage) {
    Write-Host $confirmationMessage" [yYnN]" -ForegroundColor Cyan
    $preference = Read-Host
    if ($preference -imatch "^y(es)?") {
        return $true
    } elseif ($preference -imatch "^n(o)?") {
        return $false
    } else {
        Write-Host "Your choice must either be 'y' for yes or 'n' for no"
        return AskForConfirmation $confirmationMessage
    }
}

function ExtractPrivateDnsZoneNameFromPrivateLink($privateLink) {
    Write-Host "Extracting zone name from private endpoint $($privateLink.Name)" -ForegroundColor Yellow
    $serviceConnection = $privateLink.PrivateLinkServiceConnections[0]
    $cacheResourceId = $serviceConnection.PrivateLinkServiceId;
    try {
        $reCacheArmResource = Get-AzResource -ResourceId $cacheResourceId;
        $name = $reCacheArmResource.Name;
        $resourceGroup = $reCacheArmResource.ResourceGroupName;

        $reCache = Get-AzRedisEnterpriseCache -Name $name -ResourceGroupName $resourceGroup;

        $hostname = $reCache.HostName;

        # Hostname will always be {section}.{region}.{suffix}, and this extracts just the suffix
        $hostname -Match '^[^\.]+\.[^\.]+\.(.*)' | Out-Null
        $suffix = $Matches[1]
        $newZoneName = "privatelink.${suffix}"
        Write-Host "Determined new zone name should be $newZoneName" -ForegroundColor Yellow
        return $newZoneName
    } catch {
        # If we get here, the cache likely doesn't exist anymore and the private endpoint we're querying is in a disconnected state
        Write-Host "The Cache $(($cacheResourceId -split "/")[-1]) doesn't exist. The private endpoint $($privateLink.Name) linked to it is in a $($serviceConnection.PrivateLinkServiceConnectionState.Status) connection state. Cannot set up private dns zones for this private endpoint. Please attach an existing cache." -ForegroundColor Red
        $deletePrivateEndpoint = AskForConfirmation "Would you like to delete this private endpoint?"
        if( $deletePrivateEndpoint ) {
            $privateLink | Remove-AzPrivateEndpoint -Force | Out-Null
        }
        return $null
    }
}

function TagAndRemoveLinksFromOldZones($vnetToZoneMap) {
    Write-Host "Now that new zones are set up, the final step is to disconnect old zones. See step 'Testing your migration' in the migration document." -ForegroundColor Yellow 
    Write-Host "As the old zones are disconnected they will be 'tagged' with old VNet they were attached to. The tag helps if you need to troubleshoot. For more information, see the Troubleshooting section of the migration document." -ForegroundColor Yellow
    foreach ($vnet in $vnetToZoneMap.GetEnumerator()) {
        $zones = $vnetToZoneMap[$vnet.Name]
        $oldZones = Get-PrivateDNSZonesMatchingPattern $OLD_DNS_ZONE_PATTERN $zones
        if($null -eq $oldZones) {
            Write-Host "No old zones exist in VNet $($vnet.Name)" -ForegroundColor Yellow
        } else {
            foreach($zone in $oldZones) {
                
                $links = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $zone.ResourceGroupName -ZoneName $zone.Name
                foreach($link in $links) {
                    if($link.VirtualNetworkId.ToLower() -eq $vnet.Name.ToLower()) {
                        $shouldContinue = AskForConfirmation "Deleting VNet link from $($zone.Name) to $($vnet.Name). Continue?"
                        if ($shouldContinue) {
                            Remove-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $zone.ResourceGroupName -ZoneName $zone.Name -Name $link.Name | Out-Null
                            Write-Host "Tagging old zone with information about the vnet is was linked to. It can be reconnected if needed" -ForegroundColor Yellow
                            $oldTags = Get-AzTag -ResourceId $zone.ResourceId
                            $oldValue = $oldTags.Properties.TagsProperty.OldVnetLink -split ","
                            $oldValue = $oldValue + $vnet.Name # Append new vnet name to list
                            $oldValue = @($oldValue | Where-Object { $_ } | Sort-Object | Select-Object -Unique) # Make sure new list values are non-empty and unique
                            $Tags = @{"OldVnetLink" = $oldValue -join ","}
                            New-AzTag -ResourceId $zone.ResourceId -Tag $Tags
                        }
                    }
                }
            }
        }
    }
}

# Begin script
Login $SubscriptionId

$plinkMap = Initialize-PrivateLinkMap
$vnetMap = Initialize-PrivateDnsZoneMap

Migrate-Vnets $plinkMap $vnetMap

TagAndRemoveLinksFromOldZones $vnetMap

Write-Host "Migration Complete. Please test that your application works. See step 'Testing the Migration' in the migration document for more information." -ForegroundColor Green