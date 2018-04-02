Param(
    [Parameter(Mandatory=$True)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory=$True)]
    [bool]$Downscale
)

function ProcessWebApps {
    param ($webApps)

    $whatsProcessing = "Web app farms"
    Write-Host "Processing $whatsProcessing"
    $amount = ($webApps | Measure-Object).Count
    if ($amount -le 0) {
        Write-Host "No $whatsProcessing was retrieved for $ResourceGroupName"
        return;
    }

    Write-Verbose "There is $amount $whatsProcessing to be processed."

    foreach ($farm in $webApps) {
        $resourceId = $farm.ResourceId
        $webFarmResource = Get-AzureRmResource -ResourceId $resourceId -ExpandProperties
        $resourceName = $webFarmResource.Name
        Write-Host "Performing requested operation on $resourceName"
        #get existing tags
        $tags = $webFarmResource.Tags
        if ($tags.Count -eq 0)
        {
            #there is no tags defined
            $tags = @{}
        }

        $cheaperTiers = "Free","Shared"

        if ($Downscale) {
            #we need to store current web app sizes in tags
            $tags.costsSaverTier = $webFarmResource.Sku.tier
            $tags.costsSaverNumberofWorkers = $webFarmResource.Properties.numberOfWorkers
            $tags.costsSaverWorkerSize = $webFarmResource.Properties.workerSize
            #write tags to web app
            Set-AzureRmResource -ResourceId $resourceId -Tag $tags -Force
            (Get-AzureRmResource -ResourceId $resourceId).Tags

            #we shall proceed only if we are in more expensive tiers
            if ($cheaperTiers -notcontains $webFarmResource.Sku.tier) {
                Write-Verbose "Downscaling $resourceName to tier: Basic, workerSize: Small"
                Set-AzureRmAppServicePlan -Tier Basic -NumberofWorkers 1 -WorkerSize Small -ResourceGroupName $webFarmResource.ResourceGroupName -Name $webFarmResource.Name
            }
        }
        else {
            if ($cheaperTiers -notcontains $tags.costsSaverTier) {
                #we shall not try to set resource
                $targetTier = $tags.costsSaverTier
                $targetWorkerSize = $tags.costsSaverWorkerSize
                $targetAmountOfWorkers = $tags.costsSaverNumberofWorkers
                Write-Verbose "Upscaling $resourceName to tier: $targetTier, workerSize: $targetWorkerSize with $targetAmountOfWorkers workers"
                Set-AzureRmAppServicePlan -Tier $tags.costsSaverTier -NumberofWorkers $tags.costsSaverNumberofWorkers -WorkerSize $tags.costsSaverWorkerSize -ResourceGroupName $webFarmResource.ResourceGroupName -Name $webFarmResource.Name
            }
        }
    }
}

function ProcessVirtualMachines {
    param ($vms)

    $whatsProcessing = "Virual machines"
    Write-Host "Processing $whatsProcessing"
    $amount = ($vms | Measure-Object).Count
    if ($amount -le 0) {
        Write-Host "No $whatsProcessing was retrieved for $ResourceGroupName"
        return;
    }

    Write-Verbose "There is $amount $whatsProcessing to be processed."

    foreach ($vm in $vms) {
        $resourceName = $vm.Name
        if ($Downscale) {
            #Deprovision VMs
            Write-Verbose "Stopping and deprovisioning $resourceName"
            Stop-AzureRmVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force
        }
        else {
            #Start them up
            Write-Verbose "Starting $resourceName"
            Start-AzureRmVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
        }
    }
}

function ProcessSqlDatabases {
    param ($sqlServers)

    $whatsProcessing = "SQL servers"
    Write-Host "Processing $whatsProcessing"
    $amount = ($sqlServers | Measure-Object).Count
    if ($amount -le 0) {
        Write-Host "No $whatsProcessing was retrieved for $ResourceGroupName"
        return;
    }

    Write-Verbose "There is $amount $whatsProcessing to be processed."

    foreach ($sqlServer in $sqlServers) {
        $sqlServerResourceId = $sqlServer.ResourceId
        $sqlServerResource = Get-AzureRmResource -ResourceId $sqlServerResourceId -ExpandProperties

        $sqlDatabases = Get-AzureRmSqlDatabase -ResourceGroupName $sqlServerResource.ResourceGroupName -ServerName $sqlServerResource.Name

        foreach ($sqlDb in $sqlDatabases.where( {$_.DatabaseName -ne "master"}))
        {
            $resourceName = $sqlDb.DatabaseName
            $sqlServerName =  $sqlDb.ServerName
            Write-Host "Performing requested operation on $resourceName"
            $resourceId = $sqlDb.ResourceId
            #get existing tags
            $tags = (Get-AzureRmResource -ResourceId $resourceId).Tags
            if ($tags.Count -eq 0)
            {
                #there is no tags defined
                $tags = @{}
            }
            if ($Downscale) {
                #we need to store current sql server sizes in tags
                $tags.costsSaverId = $sqlDb.CurrentServiceObjectiveId.Guid
                $tags.costsSaverSku = $sqlDb.CurrentServiceObjectiveName
                $tags.costsSaverEdition = $sqlDb.Edition

                #write tags to web app
                Set-AzureRmResource -ResourceId $resourceId -Tag $tags -Force
                (Get-AzureRmResource -ResourceId $resourceId).Tags

                #proceed only in case we are not on Basic
                if ($sqlDb.Edition -ne "Basic")
                {
                    Write-Verbose "Downscaling $resourceName at server $sqlServerName to S0 size"
                    Set-AzureRmSqlDatabase -DatabaseName $resourceName -ResourceGroupName $sqlDb.ResourceGroupName -ServerName $sqlServerName -RequestedServiceObjectiveName S0 -Edition Standard
                }
            }
            else {
                if ($tags.costsSaverEdition -ne "Basic") {
                    $targetSize = $tags.costsSaverSku
                    Write-Verbose "Upscaling $resourceName at server $sqlServerName to $targetSize size"
                    Set-AzureRmSqlDatabase -DatabaseName $resourceName -ResourceGroupName $sqlDb.ResourceGroupName -ServerName $sqlServerName -RequestedServiceObjectiveName $targetSize -Edition $tags.costsSaverEdition
                }
            }
        }
    }
}

#Get all resources, which are in resource groups, which contains our name
$resources = Find-AzureRmResource -ResourceGroupNameContains $ResourceGroupName

if (($resources | Measure-Object).Count -le 0)
{
    Write-Host "No resources was retrieved for $ResourceGroupName"
    Exit $false
}

ProcessWebApps -webApps $resources.where( {$_.ResourceType -eq "Microsoft.Web/serverFarms" -And $_.ResourceGroupName -eq "$ResourceGroupName"})
ProcessSqlDatabases -sqlServers $resources.where( {$_.ResourceType -eq "Microsoft.Sql/servers" -And $_.ResourceGroupName -eq "$ResourceGroupName"})
ProcessVirtualMachines -vms $resources.where( {$_.ResourceType -eq "Microsoft.Compute/virtualMachines" -And $_.ResourceGroupName -eq "$ResourceGroupName"})