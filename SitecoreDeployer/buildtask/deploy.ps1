#getting data from task
$ArmTemplatePath = Get-VstsInput -Name armTemplatePath -Require
$ArmParametersPath = Get-VstsInput -Name armParametersPath -Require
$RgName = Get-VstsInput -Name resourceGroupName -Require
$location = Get-VstsInput -Name location -Require
$DeploymentType = Get-VstsInput -Name deploymentType -Require
#get input for generate SAS
$generateSasInput = Get-VstsInput -Name generateSas -Require
#convert it to Boolean
$GenerateSas = [System.Convert]::ToBoolean($generateSasInput)
#get license location
$licenseLocation = Get-VstsInput -Name licenseLocation -Require
#get additional parameters
$additionalArmParams = Get-VstsInput -Name additionalArmParams;

#get input for security features
#PRC role
$limitPrcAccessInput = Get-VstsInput -Name limitAccesToPrc -Require
$limitPrcAccess = [System.Convert]::ToBoolean($limitPrcAccessInput)
$instanceNamePrc = Get-VstsInput -Name prcInstanceName;
#REP role
$limitRepAccessInput = Get-VstsInput -Name limitAccesToRep -Require
$instanceNameRep = Get-VstsInput -Name repInstanceName;
#CM role
$limitCmAccessInput = Get-VstsInput -Name limitAccesToCm -Require
$instanceNameCm = Get-VstsInput -Name cmInstanceName;

#users IP/Mask list as string
$ipList = Get-VstsInput -Name ipMaskCollection;


Import-Module $PSScriptRoot\ps_modules\TlsHelper_
Add-Tls12InSession
Import-Module $PSScriptRoot\ps_modules\VstsAzureHelpers_
Initialize-Azure

Import-Module $PSScriptRoot\functions-module-v1.psm1

Write-Host "Validating Resource Group Name..."
if(!($RgName -cmatch '^(?!.*--)[a-z0-9]{2}(|([a-z0-9\-]{0,37})[a-z0-9])$'))
{
    Write-Error "Name should only contain lowercase letters, digits or dashes,
                 dash cannot be used in the first two or final character,
                 it cannot contain consecutive dashes and is limited between 2 and 40 characters in length!"
    Break;
}

#region Create Params Object
# license file needs to be secure string and adding the params as a hashtable is the only way to do it
$additionalParams = New-Object -TypeName Hashtable;

$params = Get-Content $ArmParametersPath -Raw | ConvertFrom-Json;

#check template - what parameter is used to limit access to CM and PRC role in template
if ($limitPrcAccess) {
    $clientIpString = "security_clientIp"
    $clientMaskString = "security_clientIpMask"
    #parse template - which parameter is used for ip security
    if (Select-String -Path $ArmTemplatePath -Pattern $clientIpString -SimpleMatch -Quiet) {
        #do nothing, we are OK
    } elseif (Select-String -Path $ArmTemplatePath -Pattern "securityClientIp" -SimpleMatch -Quiet) {
        $clientIpString = "securityClientIp"
        $clientMaskString = "securityClientIpMask"
    } else {
        #we are not finding known strings for limiting PRC access
        $limitPrcAccess = $False
        Write-Host "##vso[task.logissue type=warning;] LimitAccessToInstance: Access to PRC role shall not be limited by task, as we could not figure out template parameter for this"
    }
}

$ipSecuritySetInTemplateParams = $False

foreach($p in $params | Get-Member -MemberType *Property) {
    #if we need to limit access to processing - we need to check, if it is not limited already at template parameters
    if ($limitPrcAccess) {
        if ($p.Name.ToLower() -eq $clientIpString.ToLower()) {
            Write-Host "##vso[task.logissue type=warning;] LimitAccessToInstance: Access to PRC role shall not be limited by task - it is limited in template"
            $ipSecuritySetInTemplateParams = $True
        }
    }
	# Check if the parameter is a reference to a Key Vault secret
	if (($params.$($p.Name).reference) -and
		($params.$($p.Name).reference.keyVault) -and
		($params.$($p.Name).reference.keyVault.id) -and
		($params.$($p.Name).reference.secretName)){
        $vaultName = Split-Path $params.$($p.Name).reference.keyVault.id -Leaf
        $secretName = $params.$($p.Name).reference.secretName

        Write-Verbose "Trying to get secret $secretName from Azure keyvault $vaultName"

        if (CheckIfPossiblyUriAndIfNeedToGenerateSas -name $p.Name -generate $GenerateSas) {
            #if parameter name contains msdeploy or url - it is great point of deal that we have URL to our package here
            $secret = TryGenerateSas -maybeStorageUri (Get-AzureKeyVaultSecret -VaultName $vaultName -Name $secretName).SecretValueText
            Write-Verbose "URI text is $secret"
        } else {
            $secret = (Get-AzureKeyVaultSecret -VaultName $vaultName -Name $secretName).SecretValue
        }

        Write-Verbose "Received secret $secretName from Azure keyvault $vaultName with value $secret"

		$additionalParams.Add($p.Name, $secret);
	} else {
        # or a normal plain text parameter
        if (CheckIfPossiblyUriAndIfNeedToGenerateSas -name $p.Name -generate $GenerateSas) {
            $tempUrlForMessage = $params.$($p.Name).value
            Write-Verbose "We are going to generate SAS for $tempUrlForMessage"
            #process replacement here
            $valueToAdd = TryGenerateSas -maybeStorageUri $params.$($p.Name).value
            $additionalParams.Add($p.Name, $valueToAdd);
            Write-Verbose "URI text is $valueToAdd"
        } else {
            $additionalParams.Add($p.Name, $params.$($p.Name).value);
        }
	}
}

if ($limitPrcAccess -And !$ipSecuritySetInTemplateParams) {
    #ip security is not set in parameters file and we will add it here (due to configuration of PRC SCWDP packages in SC 8.2.*-9.0.1 - we can really set only one IP allowed for PRC, which shall be 127.0.0.1 to allow KeepAlive and startup app init work correctly). Word of warning though - this means, that CM package will be deployed _initially_ with same limitation, so you shall ensure that you are deploying web.config with your own ipSecurity as well
    $additionalParams.Add($clientIpString, "127.0.0.1");
    $additionalParams.Add($clientMaskString, "255.255.255.255");
}

Write-Verbose "Do we need to generate SAS? $GenerateSas"
ListArmParameters -inputMessage "Listing keys before filling up by extension:" -armParamatersHashTable $additionalParams

$deploymentIdkey = "deploymentId";
$locationKey = "location"

if ($DeploymentType -eq "infra") {
    #this set of check is added specifically for those who forget that parameters file values will ALWAYS override parameters in template, even if set to empty
    #first - check, if there is such a key - who knows, maybe future versions of templates or your adopted templates does not use it
    if ($additionalParams.ContainsKey($deploymentIdkey)) {
        Write-Verbose "There is a parameter $deploymentIdkey key defined"
        #if deploymentId key is set in parameters - we shall not override it
        if ([string]::IsNullOrWhiteSpace($additionalParams[$deploymentIdkey])) {
            Write-Verbose "$deploymentIdkey key is empty, setting it to $RgName"
            $additionalParams.Set_Item($deploymentIdkey, $RgName);
        } else {
            Write-Verbose "$deploymentIdkey key is set in template"
        }
    } else {
        Write-Verbose "$deploymentIdkey key is not defined in parameter file"
    }

    if ($additionalParams.ContainsKey($locationKey)) {
        Write-Verbose "There is a parameter $locationKey key defined"
        #if deploymentId key is set in parameters - we shall not override it
        if ([string]::IsNullOrWhiteSpace($additionalParams[$locationKey])) {
            Write-Verbose "$locationKey key is empty, setting it to $location"
            $additionalParams.Set_Item($locationKey, $location);
        } else {
            Write-Verbose "$locationKey key is set in template"
        }
    } else {
        Write-Verbose "$locationKey key is not defined in parameter file"
    }
}

$licenseXmlKey = "licenseXml";
#if our parameters contains licenseXml - we need to populate it with data (even if it is infra deployment)
if ($additionalParams.ContainsKey($licenseXmlKey)) {
    #now, tricky part = get license.xml content
    if ($licenseLocation -ne "none") {
        #license file is not defined in template
        if ($licenseLocation -eq "inline") {
            #license is added to VSTS release settings
            $licenseFileContent = Get-VstsInput -Name inlineLicense -Require
        }
        if ($licenseLocation -eq "filesystem") {
                # read the contents of your Sitecore license file
                $licenseFsPath = Get-VstsInput -Name pathToLicense -Require
                $licenseFileContent = Get-Content -Raw -Encoding UTF8 -Path $licenseFsPath | Out-String;
        }
        if ($licenseLocation -eq "url") {
            #read license from URL
            $licenseUriInput = Get-VstsInput -Name urlToLicense -Require
            if ($GenerateSas) {
                #trying to generate SAS
                $licenseUri = TryGenerateSas -maybeStorageUri $licenseUriInput
            } else {
                $licenseUri = $licenseUriInput
            }
            Write-Verbose "We are going to download license from $licenseUri"
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $licenseFileContent =  $wc.DownloadString($licenseUri)
        }
        #we shall update ARM template parameters only in case it is defined on VSTS level
        $additionalParams.Set_Item($licenseXmlKey, $licenseFileContent);
    }
}

if (-not [string]::IsNullOrWhiteSpace($additionalArmParams)) {
    $additionalArmParamsHashtable = @{};
    #process additional params from release settings
    if ($additionalArmParams.contains('=') -and (-not $additionalArmParams.StartsWith("-"))) {
        #we can proceed only in case we have seems to be correct params
        if ($additionalArmParams.contains(' \n ')) {
            #replace line end symbole with leading and traling space characters to powershell specific line ending character
            $additionalArmParamsHashtable = ConvertFrom-StringData -StringData $additionalArmParams.Replace(" \n ", " `n ");
        } else {
            $additionalArmParamsHashtable = ConvertFrom-StringData -StringData $additionalArmParams;
        }
    } elseif ($additionalArmParams.StartsWith("-")) {
        $overridingDataArray = $additionalArmParams.Split(" ",[System.StringSplitOptions]::RemoveEmptyEntries);
        for ( $i = 0; $i -lt $overridingDataArray.Length; $i+=2 ) {
            $additionalArmParamsHashtable.Add($overridingDataArray[$i].substring(1), $overridingDataArray[$i+1]);
          }
    } else {
        Write-Host "##vso[task.logissue type=warning;] additionalArmParams field does not contains = (equal) sign, so it could not be converted to hashtable; or it does not starts with - (dash) sign"
    }

    Write-Verbose "Additional ARM parameters parsed to hashtable:"
    Write-Verbose ($additionalArmParamsHashtable | Out-String)

    foreach ($additionalKey in $additionalArmParamsHashtable.Keys) {
        #check, if we have such keys in our $additionalParams object
        $reportObject = $additionalArmParamsHashtable[$additionalKey];
        if ($additionalParams.ContainsKey($additionalKey)) {
            $initialValue = $additionalParams[$additionalKey]
            Write-Verbose "Overriding $additionalKey from $initialValue to $reportObject"
            $additionalParams.Set_Item($additionalKey, $reportObject);
        } else {
            Write-Verbose "Adding $additionalKey with value $reportObject"
            $additionalParams.Add($additionalKey, $reportObject);
        }
    }
}

ListArmParameters -inputMessage "Listing keys AFTER filling up by extension:" -armParamatersHashTable $additionalParams

#endregion

Write-Host "Check if resource group already exists..."
$notPresent = Get-AzureRmResourceGroup -Name $RgName -ev notPresent -ea 0;

if (!$notPresent)
{
    if ($DeploymentType -ne "infra")
    {
        #if it is not an infra deployment - than we shall throw error
        throw "Resource group is not present, exiting"
    }
    New-AzureRmResourceGroup -Name $RgName -Location $location;
}

Write-Host "Starting ARM deployment...";

#checking, if we are running at Debug build, e.g system.debug is set to TRUE
$isDebugBuild = $False;
try {
    Write-Verbose "SYSTEM_DEBUG is set to $env:SYSTEM_DEBUG";
    $isDebugBuild = [System.Convert]::ToBoolean($env:SYSTEM_DEBUG)
} catch [FormatException] {}
Write-Verbose "We are running debug build? $isDebugBuild"

if ($DeploymentType -eq "infra") {
    $deploymentName = "sitecore-infra"
    if ($isDebugBuild) {
        #for debug build I wish more verbosity in output
        New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $RgName -TemplateFile $ArmTemplatePath -TemplateParameterObject $additionalParams -Verbose;
    } else {
        New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $RgName -TemplateFile $ArmTemplatePath -TemplateParameterObject $additionalParams;
    }
}
if ($DeploymentType -eq "redeploy") {
    #deployment name is used to generate login to SQL as well - so for msdeploy and redeploy it shall be equal
    $deploymentName = "sitecore-msdeploy"
    # Fetch output parameters from Sitecore ARM deployment as authoritative source for the rest of web deploy params
    $sitecoreDeployment = Get-AzureRmResourceGroupDeployment -ResourceGroupName $RgName -Name "sitecore-infra"
    $sitecoreDeploymentOutput = $sitecoreDeployment.Outputs
    $sitecoreDeploymentOutputAsJson =  ConvertTo-Json $sitecoreDeploymentOutput -Depth 5
    $sitecoreDeploymentOutputAsHashTable = ConvertPSObjectToHashtable $(ConvertFrom-Json $sitecoreDeploymentOutputAsJson)
    if ($isDebugBuild) {
        #for debug build I wish more verbosity in output
        New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $RgName -TemplateFile $ArmTemplatePath -TemplateParameterObject $additionalParams -provisioningOutput $sitecoreDeploymentOutputAsHashTable -Verbose;
    } else {
        New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $RgName -TemplateFile $ArmTemplatePath -TemplateParameterObject $additionalParams -provisioningOutput $sitecoreDeploymentOutputAsHashTable;
    }
}
if ($DeploymentType -eq "validate") {
    if ($isDebugBuild) {
        #for debug build I wish more verbosity in output
        Test-AzureRmResourceGroupDeployment -ResourceGroupName $RgName -TemplateFile $ArmTemplatePath -TemplateParameterObject $additionalParams -Verbose;
    } else {
        Test-AzureRmResourceGroupDeployment -ResourceGroupName $RgName -TemplateFile $ArmTemplatePath -TemplateParameterObject $additionalParams;
    }
}

if ($DeploymentType -ne "validate") {
    #access limiting should not be executed on validation builds
    LimitAccessToInstance -rgName $RgName -instanceName $instanceNameRep -instanceRole "rep" -limitAccessToInstanceAsString $limitRepAccessInput -ipMaskCollectionUserInput $ipList;
    LimitAccessToInstance -rgName $RgName -instanceName $instanceNameCm -instanceRole "cm" -limitAccessToInstanceAsString $limitCmAccessInput -ipMaskCollectionUserInput $ipList;
    LimitAccessToInstance -rgName $RgName -instanceName $instanceNamePrc -instanceRole "prc" -limitAccessToInstanceAsString $limitPrcAccessInput -ipMaskCollectionUserInput $ipList;
}
Write-Host "Deployment Complete.";
