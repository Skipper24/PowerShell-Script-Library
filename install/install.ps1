#parameters resolved via configuration:
$scriptRoot = Split-Path (Resolve-Path $myInvocation.MyCommand.Path)
[xml]$Config = get-content ($scriptRoot + "\install.config")

$baseStorageUrl = $Config.InstallSettings.BaseStorageUrl

#Download the versions meta data file
$clnt = new-object System.Net.WebClient
$clnt.DownloadFile($baseStorageUrl + "versions.config",$scriptRoot + "\versions.config")

[xml]$VersionsConfig = get-content ($scriptRoot + "\versions.config")

if ($args.Count -lt 3)
{
	Write-Host "Please specify at least 'prefix', 'ver' and 'rev' parameters. Instead of 'ver' and 'rev' you can simply put '-recommended' or '-latest'" 
    Exit
}

if($args.Count -gt 2)
{
   $prefix = $args[1]
}

if($args.Count -lt 4 -and $args[2] -eq "-recommended")
{
    $recommended = $VersionsConfig.SelectSingleNode("versions/version[@recommended='true']")
    $version = $recommended.GetAttribute("number")
    $revision = $recommended.GetAttribute("revision")

    Write-Host "downloading recommended release: " $version $revision
}
elseif ($args.Count -lt 4 -and $args[2] -eq "-latest")
{  
    $latest = $VersionsConfig.SelectSingleNode("versions/version[@latest='true']")
    $version = $latest.GetAttribute("number")
    $revision = $latest.GetAttribute("revision")
    
    Write-Host "downloading latest release: " $version $revision
}
else
{
    $version = $args[3];
    $revision = $args[5];    
    $validVersionFound = $false;
    
    foreach($ver in $VersionsConfig.SelectNodes("versions/*"))
    {
        $configVerNumber = $ver.GetAttribute("number")
        $configRevNumber = $ver.GetAttribute("revision")
        
        if($version -eq $configVerNumber -and
           $revision -eq $configRevNumber)
         {
              Write-Host $configVerNumber $configRevNumber            
              $validVersionFound = $true
         }         
    }
    
    if($validVersionFound)
    {
        Write-Host "OK. Valid Version Found."
    }
    else
    {
        Write-Host "ERROR! Specified version was not found!"
        exit
    }
}

#parameters resolved via configuration:
$runtimeVer = $Config.InstallSettings.DefaultRuntimeVersion
$hostNamesuffix = $Config.InstallSettings.HostNameSuffix
$inetpub = $Config.InstallSettings.InetpubLocation
$identity = $Config.InstallSettings.AppPoolIdentity
$temp = $Config.InstallSettings.TempFolder
$baseStorageUrl = $Config.InstallSettings.BaseStorageUrl
$licenseFilePath = $Config.InstallSettings.LicenseFilePath
$serverName = $Config.InstallSettings.SQLServerName
$sqlUserName = $Config.InstallSettings.SQLUserName
$sqlPassword = $Config.InstallSettings.SQLPassword
$sqlPrefix = $Config.InstallSettings.DatabaseNamePrefix

#other parameters:
$sitename = "$prefix" + "$version" + "x" + "$revision"
$hostname = "$sitename" + "$hostNamesuffix"
$webroot = "$inetpub" + "$sitename"
$filename = "$version" + "x" + "$revision" + ".zip"
$downloadUrl = "$baseStorageUrl" + "$filename"
$tempDownloadLoc = "$temp" + "$filename"

#config settings start
$currentDate = (get-date).tostring("mm_dd_yyyy-hh_mm_s")
$dataFolder = $webroot + "\data"
#config settings end

#database settings start
$dbPrefix = "$sqlPrefix" + "$sitename"
$databaseNames = @("core", "master", "web")
$databaseLoc = $webroot + "\databases\"
#database settings end

#connectionstring settings start
$baseConnectionString = "user id=$sqlUserName;password=$sqlPassword;Data Source=$serverName;Database=$dbPrefix"
$connectionStringsPath = "$webroot\website\app_config\connectionstrings.config"
#connectionstring settings end
$siteUrl = "http://" + "$hostname"

#create a web root directory
New-Item $webroot -type directory -force

#Conditional download of the distributive
if (Test-Path $tempDownloadLoc)
{
	Write-Host "Distributive has already been downloaded. Skipping."
}
else
{
	$clnt = new-object System.Net.WebClient
	Write-Host "Downloading from $url ..."
	$clnt.DownloadFile($downloadUrl,$tempDownloadLoc)
	Write-Host "Download complete!"	
}

#unzip the downloaded distributive into the webroot
Write-Host "Unzipping from $tempDownloadLoc to $webroot ..."
$shell_app=new-object -com shell.application 
$zip_file = $shell_app.namespace($tempDownloadLoc) 
$destination = $shell_app.namespace($webroot)
$destination.Copyhere($zip_file.items())
Write-Host "Unzipping done!"

Import-Module WebAdministration

# Setup app pool
Write-Host "Check if the pool already exists"

$poolname = $sitename

if(Test-Path IIS:\AppPools\$sitename)
{
    Write-Host "Such app pool already exist"
    $poolname = "$sitename - " + [System.Guid]::NewGuid()
}

Write-Host "Setting up new app pool in IIS..."
New-WebAppPool -Name $poolname -force

$pool = Get-Item IIS:\AppPools\$sitename
$pool.processModel.identityType = $identity
$pool.managedRuntimeVersion = $runtimeVer
$pool | set-item

# Setup website
Write-Host "Check if the site $sitename already exists in IIS..."
$iissitename = $sitename

if(Test-Path IIS:\Sites\$sitename)
{
    Write-Host "Such site already exist"
    $iissitename = "$sitename - " + [System.Guid]::NewGuid()
}

Write-Host "Creating new IIS site..."
New-Website –Name $iissitename –Port 80 –HostHeader $hostname –PhysicalPath "$webroot\Website" -ApplicationPoo $sitename -force

# Add hostname to hosts file
Write-Host "Modifying hosts file..."
$hostsPath = "$env:windir\System32\drivers\etc\hosts"
Add-Content $hostsPath "`n127.0.0.1 $hostname"

# edit web.config start
Write-Host "Editing web.config..."
$webConfigPath = "$webroot\website\web.config"
$webconfig = [xml](get-content $webConfigPath)
$backup = $webConfigPath + "_$currentDate"
$webconfig.Save($backup)
$webconfig.configuration.SelectSingleNode("sitecore/sc.variable[@name='dataFolder']").SetAttribute("value", $dataFolder)
$webconfig.configuration.sitecore.SelectSingleNode("settings/setting[@name='LicenseFile']").SetAttribute("value", $licenseFilePath);
$webconfig.Save($webConfigPath)

#edit web.config end

#connectionstring script start
Write-Host "Editing connectionStrings.config..."
$connectionStringsConfig = [xml](get-content $connectionStringsPath)
$backup = $connectionStringsPath + "_$currentDate"
$connectionStringsConfig.Save($backup)

foreach ($db in $databaseNames)
{
    $connectionStringsConfig.SelectSingleNode("connectionStrings/add[@name='$db']").SetAttribute("connectionString", $baseConnectionString + $db);
}

$connectionStringsConfig.Save($connectionStringsPath)
#connectionstring script end

# database attach start
Write-Host "Attaching databases..."

[Reflection.Assembly]::Load("Microsoft.SqlServer.Smo, `
      Version=10.0.0.0, Culture=neutral, `
      PublicKeyToken=89845dcd8080cc91")
[Reflection.Assembly]::Load("Microsoft.SqlServer.SqlEnum, `
      Version=10.0.0.0, Culture=neutral, `
      PublicKeyToken=89845dcd8080cc91")
[Reflection.Assembly]::Load("Microsoft.SqlServer.ConnectionInfo, `
      Version=10.0.0.0, Culture=neutral, `PublicKeyToken=89845dcd8080cc91")

$sql = New-Object -typeName Microsoft.SqlServer.Management.Smo.Server -argumentList "$serverName"
$db = New-Object Microsoft.SqlServer.Management.Smo.Database
$sql.ConnectionContext.LoginSecure=$false;               
$sql.ConnectionContext.set_Login($sqlUserName)
$securePassword = ConvertTo-SecureString $sqlPassword -AsPlainText –Force
$sql.ConnectionContext.set_SecurePassword($securePassword)

[System.Reflection.Assembly]::LoadWithPartialName("System") 

foreach ($db in $databaseNames)
{
  $files = New-Object System.Collections.Specialized.StringCollection 
 
  $dataFileName = "$databaseLoc" + "Sitecore.$db.mdf";
  $logFileName = "$databaseLoc" + "Sitecore.$db.ldf";

  $files.Add("$dataFileName")
  $files.Add("$logFileName")
  $sqldbName = $dbPrefix + $db
  
  Write-Host "Attaching $dataFileName to database $sqldbName"

  $sql.AttachDatabase("$sqldbName", $files)
  
  Write-Host "Attached!"
}

# database attach end

# launching the site...

Write-Host "Launching site: $siteUrl..."

$ie = new-object -comobject "InternetExplorer.Application" 
$ie.visible = $true
$ie.navigate($siteUrl) 