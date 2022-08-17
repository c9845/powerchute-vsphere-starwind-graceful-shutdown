<#
INTRODUCTION:
This script handles consolidating VMs on a two-node vSphere cluster using StarWind vSAN
for storage. This script is designed to be run during the initial stages of a power 
failure to reduce the chances of data corruption by keeping all VMs on a single host
and thus using a single underlying storage. This script may also help in shutting down
your infrastructure, or starting everything back up, because all your VMs are located
on a single host to manage. Furthermore, this may extend the runtime of your backup
batteries since you can shut down one ESXi host since no VMs are running on it.
Obviously, this only works in a situation where one ESXi node can support your entire
set of VMs, however, if you are running a 2-node cluster, this should not be an issue.

REQUIREMENTS:
    - 2-node vSphere cluster.
    - StarWind HCA vSAN.
    - APC UPSes with NMC3 network cards.
    - APC PowerChute Network Shutdown server application.
    - Network connectivity between APC UPSes, APC PowerChute, and vSphere.

DETAILS:
The following steps occur:
    - All powered-on VMs are vMotioned from ESXi2 to ESXi1.
    - The StarWind storage VM on ESXi2 is shut down.
    - ESXi2 is put into maintance mode.

This script should be run on a host that is independent of your vSphere environment. 
This is necessary since if APC PowerChute is running as a VM within your vSphere
environment it may not be able to properly communicate with with everything else,
especially if it, itself, is being vMotioned. An idea would be to purchase a small, 
low power computer (such as an Intel NUC) and PowerChute, and this script, on it. The 
system running the PowerChute software and this script does become a single point of 
failure so please take note of that in your planning (you could potentially run 
redundant systems with PowerChute and this script monitoring your same UPS(s) but how 
to handle the race condition between the two PowerChute hosts becomes a bit problematic).

The configuration needed to run this script is generated upon the first-run when you 
run this script interactively (in a powershell window). A JSON formatted configuration 
file is saved to the same directory this script is located in. Note that the 
configuration file will include the password to vSphere. You should create a separate 
user and roles with minimal permissions to protect against misuse. You should also 
make sure the system running PowerChute and this script are hardened (it is best to 
use a non-domain joined system). Powershell secure-string is not used since doing so 
is difficult because APC PowerChute runs commands as the NT Authority/System user but 
it is very difficult to create and store secure-string passwords as this user (you 
need to use the same user to create a secure-string as you will read said secure string).

vSphere Permissions:
    - Datastore > Allocate space (for vMotion, not sure why).
    - Host > Inventory > Modify Cluster (to disable vSphere High Availability).
    - Host > Configuration > Maintance (to put host into maintance mode).
    - Virtual Machine > Interaction > Power off (to shut down StarWind VM).
    - Resource > Assing virtual machine to resource pool (for vMotion).
    - Resource > Migrate powered on virtual machine (for vMotion).
    - Resource > Migrate powered off virtual machine (for vMotion).
    - Resource > Query vMotion (for vMotion).

You should never have to modify this script directly!

NOTES:
- You will need to run this script interactively, in a Powershell window, initially to 
  create and save the configuration file. You can edit the configuration file manually 
  after it is created.
- There is VERY LITTLE error handling in this script. It is advised to heavily test 
  this script during non-work hours to check for errors.
- You should ensure your UPS(s) have adequate runtime to allow this script to run to
  completion. You should also ensure your UPS(s) are configured with the proper runtime
  delays, wait times, etc.
#>


#------------------------------------------------------------------------------------
#Define configuration. This information is prompted for upon first run (running this 
#script interactively) and is saved to a JSON file. This information is read from the 
#JSON file on subsequent runs. Doing so keeps the configuration separate from the 
#script so that an end-user does not need to modify this script's contents at all.
$config = [PSCustomObject]@{
    #user credentials and systems to connect to.
    VCenter                      = [PSCustomObject]@{
        FQDN        = "vcenter.example.com"     #FQDN is fine since DNS should be functioning.
        Username    = "non-admin@vsphere.local" #Make sure this user only has minimal permissions to vMotion VMs, disable vSphere High Availability, and enter maintance mode.
        Password    = ""
        ClusterName = "Cluster" #Your cluster name in vSphere, needed to disabled vSphere High Availability.
    }
    ESXi                         = [PSCustomObject]@{
        Host1FQDN = "esxi1.example.com" #For vMotion target.
        Host2FQDN = "esxi2.example.com" #For listing VMs to vMotion from and putting host into maintance mode.
    }
    StarWind                     = [PSCustomObject]@{
        VM2Name = "SW-HCA-VM-02"   #Name as shown in vSphere Web Client, used to skip this VM when listing running VMs to prevent trying to vMotion this VM.
    }

    Logging                      = [PSCustomObject]@{
        WriteToFile     = $false                                #Set to $true to write logging to a file, set to $false to write to terminal. $true should be used for production so you can inspect logs
        PathToDirectory = "C:\powerchute-consolidate-vms\" #Path to location where log files will be saved. Make sure you have permission to write to this location.
    }

    WaitForVMotionDelay          = 60 #How long to wait after issuing vMotion commands to proceed with shutting down StarWind storage VM and putting host into maintance mode.
    WaitForStarWindShutdownDelay = 30 #How long to wait for StarWind storage VM to shutdown before putting host in maintance mode.
    WaitForMaintanceModeDelay    = 10 #How long to wait for the host to go into maintance mode.

    #Email server configuration is used to send an alert when this script is run. This
    #lets administrators know this script is running and provides a secondary alert
    #separate from your APC UPS's alerts.
    Emails                       = [PSCustomObject]@{
        Enable    = $false
        Server    = "emails.example.com" #IP or FQDN of your email server.
        Port      = 25 #email server SMTP port (default: 25).
        Recipient = "to@example.com" #who email will be sent to.
        From      = "powerchute-consolidate-vms@example.com" #who email will be sent from.
    }
}


#------------------------------------------------------------------------------------
#Some defaults for use when gathering user input and building configuration.
$defaultWaitForVMotionDelay = 60
$defaultWaitForStarWindShutdownDelay = 30
$defaultWaitForMaintanceModeDelay = 10


#------------------------------------------------------------------------------------
#Check if configuration file exists, otherwise prompt user for data to build 
#configuration. The configuration file should be stored in the same directory as this 
#script. If the file does not exist, it will be created. The directory noted is the 
#directory from where powerchute can run scripts from.
$configFileName = "powerchute-consolidate-vms.config"
$scriptRunningDirectory = "C:\Program Files\APC\PowerChute\user_files"
$pathToConfigFile = Join-Path -Path $scriptRunningDirectory -ChildPath $configFileName

Write-Host "Searching for config file at '$pathToConfigFile'..."
$exists = Test-Path -Path $pathToConfigFile
if (!$exists) {
    Write-Host "Config file does not exist, gathering data to create config file..."

    #gather data from user
    $config.VCenter.FQDN = Read-Host -Prompt "Enter your vCenter FQDN"
    $config.VCenter.Username = Read-Host -Prompt "Enter your vCenter username (should be a minimal-permissioned user solely used for this script)"
    $config.VCenter.Password = Read-Host -Prompt "Enter your vCenter user's password"
    $config.VCenter.ClusterName = Read-Host -Prompt "Enter your vCenter cluster name"
    
    $config.ESXi.Host1FQDN = Read-Host -Prompt "Enter your first ESXi server FQDN. This is where VMs will be vMotioned to"
    $config.ESXi.Host2FQDN = Read-Host -Prompt "Enter your second ESXi server FQDN. This host will be put into maintance mode"
    
    $config.StarWind.VM2Name = Read-Host -Prompt "Enter the name for your second StarWind VM (as displayed in vSphere)"

    [int]$config.WaitForVMotionDelay = Read-Host -Prompt "Seconds to wait for VMs to vMotion. (default: $defaultWaitForVMotionDelay)"
    if ($config.WaitForVMotionDelay -le 0) {
        $config.WaitForVMotionDelay = $defaultWaitForVMotionDelay
    }
    [int]$config.WaitForStarWindShutdownDelay = Read-Host -Prompt "Seconds to wait for StarWind VM to shut down. (default: $defaultWaitForStarWindShutdownDelay)"
    if ($config.WaitForStarWindShutdownDelay -le 0) {
        $config.WaitForStarWindShutdownDelay = $defaultWaitForStarWindShutdownDelay
    }
    [int]$config.WaitForMaintanceModeDelay = Read-Host -Prompt "Seconds to wait for second ESXi host to enter maintance mode. (default: $defaultWaitForMaintanceModeDelay)"
    if ($config.WaitForMaintanceModeDelay -le 0) {
        $config.WaitForMaintanceModeDelay = $defaultWaitForMaintanceModeDelay
    }

    $do = Read-Host -Prompt "Write logs to file? (Y/N)"
    if ($do -eq "Y" -or $do -eq "y") {
        $config.Logging.WriteToFile = $true
    }
    else {
        $config.Logging.WriteToFile = $false
    }
    $config.Logging.PathToDirectory = Read-Host -Prompt "Directory where log files should be stored"
    
    $do = Read-Host -Prompt "Send email alert when script is run? (Y/N)"
    if ($do -eq "Y" -or $do -eq "y") {
        $config.Emails.Enable = $true
    }
    else {
        $config.Emails.Enable = $false
    }
    $config.Emails.Server = Read-Host -Prompt "Email server address"
    [int]$config.Emails.Port = Read-Host -Prompt "Email server SMTP port (default: 25)"
    if ($config.Emails.Port -lt 1) {
        $config.Emails.Port = $defaultSMTPPort
    }
    $config.Emails.Recipient = Read-Host -Prompt "Email address to send email to"
    $config.Emails.From = Read-Host -Prompt "Email address to send email from"

    #save data to config file on disk
    ConvertTo-Json $config | Set-Content -Path $pathToConfigFile

    #Exit and tell user to rerun script. Why not just continue? Because we want to
    #make sure we can parse the config file for the future and the best way to do
    #that is by making user rerun this script.
    Write-Host "Config file does not exist, gathering data to create config file...done"
    Write-Host "Config file saved to $pathToConfigFile. Please rerun this script."
    exit
}
else {
    #read and parse config from file on disk (from previous run of this script)
    $config = Get-Content -Path $pathToConfigFile -Raw | ConvertFrom-Json
    Write-Host "Searching for config file at '$pathToConfigFile'...found!"
}


#------------------------------------------------------------------------------------
#Validate the config file (since user could have changed it manually).
if ($config.VCenter.FQDN -eq "") {
    Write-Host "No vCenter FQDN provided in config file."
    exit
}
if ($config.VCenter.Username -eq "") {
    Write-Host "No vCenter username provided in config file."
    exit
}
if ($config.VCenter.Password -eq "") {
    Write-Host "No vCenter password provided in config file."
    exit
}
if ($config.VCenter.ClusterName -eq "") {
    Write-Host "No vCenter cluster name provided in config file."
    exit
}
if ($config.ESXi.Host1FQDN -eq "") {
    Write-Host "No FQDN provided for your first ESXi host in config file."
    exit
}
if ($config.ESXi.Host2FQDN -eq "") {
    Write-Host "No FQDN provided for your second ESXi host in config file."
    exit
}
if ($config.StarWind.VM2Name -eq "") {
    Write-Host "No VM name provided for second StarWind VM in config file."
    exit
}
if ($config.WaitForVMotionDelay -lt 0) {
    Write-Host "Invalid WaitForVMotionDelay set in config file. Must be at least 1 (seconds)."
    exit
}
if ($config.WaitForStarWindShutdownDelay -lt 0) {
    Write-Host "Invalid WaitForStarWindShutdownDelay set in config file. Must be at least 1 (seconds)."
    exit
}
if ($config.WaitForMaintanceModeDelay -lt 0) {
    Write-Host "Invalid WaitForMaintanceModeDelay set in config file. Must be at least 1 (seconds)."
    exit
}
if ($config.Logging.WriteToFile -ne $true -and $config.Logging.WriteToFile -ne $false) {
    Write-Host "Invalid WriteToFile not set in config file. Must be at true or false (without quotes)."
    exit
}
if ($config.Logging.WriteToFile -and $config.Logging.PathToDirectory -eq "") {
    Write-Host "No logging directory set in config file."
    exit
}
if ($config.Emails.Enable) {
    if ($config.Emails.Server -eq "") {
        Write-Host "No email server set in config file."
        exit
    }
    if ($config.Emails.Port -lt 0) {
        Write-Host "Invalid email server port set in config file. Must be at least 1."
        exit
    }
    if ($config.Emails.Recipient -eq "") {
        Write-Host "No email recipient set in config file."
        exit
    }
    if ($config.Emails.From -eq "") {
        Write-Host "No email from address set in config file."
        exit
    }
}


#------------------------------------------------------------------------------------
#Define list of VMs that we will ignore from consolidating. These VMs are the StarWind
#storage VMs, and any other VMs that are somehow separately managed.
$ignoredVMNames = @($config.StarWind.VM2Name)


#------------------------------------------------------------------------------------
#Set up logging for diagnostics.
#Define function for handling logging. This cleans up the code base a bit and allows
#us to switch between logging to a file and logging to a terminal easily.
function Write-Log {
    param (
        [string]$Line
    )

    if ($config.Logging.WriteToFile) {
        Add-Content $logfile "$(Get-Date -f yyyy-MM-dd) $(Get-Date -f HH:mm:ss.fff) $Line"
    }
    else {
        Write-Host "$(Get-Date -f yyyy-MM-dd) $(Get-Date -f HH:mm:ss.fff) $Line"
    }
}

if ($config.Logging.WriteToFile) {
    $date = (Get-Date).ToString('yyyy-MM-dd')
    $time = (Get-Date).ToString('HH-mm-ss')
    $pathToLogFile = Join-Path $config.Logging.PathToDirectory -ChildPath "powerchute-consolidate-vms--$date--$time.txt"
    $logfile = New-Item -ItemType file $pathToLogFile -Force
}

Write-Log -Line "Consolidating VMs of utility power failure..."
Write-Log -Line "This script will move all VMs from to the first ESXi host and put the second ESXi host into maintenance mode."
Write-Log -Line " vCenter: $($config.VCenter.FQDN)"
Write-Log -Line " vCenter User: $($config.VCenter.Username)"
Write-Log -Line " ESXi Hosts: $($config.ESXi.Host1FQDN), $($config.ESXi.Host2FQDN)"
Write-Log -Line " StarWind Second Host: $($config.StarWind.VM2Name)"


#------------------------------------------------------------------------------------
#Make sure the powershell modules are imported
Import-Module VMware.PowerCLI


#------------------------------------------------------------------------------------
#Send email alert that this script is running.
#Note taht Send-MailMessage is obsolete but it still works as of now. This is way easier
#than having to import a third-party mail client for powershell.
if ($config.Emails.Enable) {
    Write-Log -Line "Sending alert email..."
    
    $subject = "APC Consolidate Command Powershell Running..."
    $body = "The APC Consolidate Command powershell script is running. Your VMs will be consolidated to one host."
    Send-MailMessage -SmtpServer $config.Emails.Server -Port $config.Emails.Port -From $config.Emails.From -To $config.Emails.Recipient -Subject $subject -Body $body
    

    Write-Log -Line "Sending alert email...sent to $($config.Emails.Recipient)"
    Write-Log -Line "Sending alert email...done"
}


#------------------------------------------------------------------------------------
#Create powershell credentials for use with PowerCLI to connect to vCenter.
$vcenterPasswordSS = ConvertTo-SecureString $config.VCenter.Password -AsPlainText -Force
$vcenterCredentials = New-Object System.Management.Automation.PSCredential ($config.VCenter.Username, $vcenterPasswordSS)


#------------------------------------------------------------------------------------
#Connect to vCenter.

#Disable prompts/logging about sending diagnostics to VMware. This just cleans up logging
#output.
Set-PowerCLIConfiguration -Scope User -ParticipateInCeip $false -Confirm:$false | Out-Null

#If you have a valid https certificate installed on vCenter, you can comment out the 
#following line. By default, we assume you are using the default self-signed certificate
#that will be marked as invalid.
Set-PowerCLIConfiguration -InvalidCertificateAction ignore -Confirm:$false | Out-Null

#Set PowerCLI into single-vcenter server mode to run this script. Otherwise some errors
#might be returned or this script could require user interaction which should not happen.
Set-PowerCLIConfiguration -DefaultVIServerMode "Single" -Confirm:$false | Out-Null

Write-Log -Line "Connecting to vCenter $($config.VCenter.FQDN) ..."
$success = Connect-VIServer $config.VCenter.FQDN -Credential $vcenterCredentials -WarningAction:SilentlyContinue
if ($success) {
    Write-Log -Line "Connecting to vCenter $($config.VCenter.FQDN) ...done"
}
else {
    Write-Log -Line "Connecting to vCenter $($config.VCenter.FQDN) ...ERROR!"
    exit
}


#------------------------------------------------------------------------------------
#Diable vSphere High Availability (HA) on the cluster. This is done to prevent issues
#where VMs are restarted unexpectedly during this consolidation process or when the 
#cluster has full power and you are restoring everything again.
Write-Log -Line "Disabling vSphere High Availability on the cluster $($config.VCenter.ClusterName)..."
Get-Cluster $config.VCenter.ClusterName | Set-Cluster -HAEnabled:$false -confirm:$false | Out-Null
Write-Log -Line "Disabling vSphere High Availability on the cluster $($config.VCenter.ClusterName)...done"


#------------------------------------------------------------------------------------
#Get the list of VMs to consolidate. Consolidation happens by moving VMs from host 2
#to host 1. Sorting alphabetically just helps with organizing logging. Note that this
#will include the StarWind storage VM, we will ignore this below when vMotioning.
Write-Log -Line "Getting list of running VMs on second host $($config.ESXi.Host2FQDN) to vMotion..."
$poweredOnVMs = Get-VMHost -Name $config.ESXi.Host2FQDN | Get-VM | Where-Object { $_.PowerState -eq "PoweredOn" } | Sort-Object
Write-Log -Line "Getting list of running VMs in cluster $($config.VCenter.ClusterName) to vMotion...done"


#------------------------------------------------------------------------------------
#Issue vMotion commands to each running VM.
Write-Log -Line "Sending vMotion commands VMs..."
ForEach ($vm in $poweredOnVMs) {
    #Make sure we don't try to vMotion the StarWind storage VMs (it wouldn't work
    #anyway since these VMs run on dedicated per-host storage).
    if (!$ignoredVMNames.Contains($vm.Name)) {
        Write-Log -Line "Processing $vm..."
        
        Move-VM -VM $vm.Name -Destination $config.ESXi.Host1FQDN -RunAsync | Out-Null
        
        #Wait a few seconds between sending vMotion commands to prevent spamming the
        #vCenter server. If you remove the -RunAsync flag to Move-VM, you can remove
        #this since each VM will be processed one at a time and the vMotion process 
        #will block.
        Start-Sleep 2
        
        Write-Log -Line "Processing $vm...done"
    } #end if: VM is not ignored, not StarWind
} #end for: loop through powered on VMs
Write-Log -Line "Sending vMotion commands to VMs...done"

Write-Log -Line "Waiting for VMs to vMotion, sleeping for $($config.WaitForVMotionDelay) seconds..."
Start-Sleep $config.WaitForVMotionDelay
Write-Log -Line "Waiting for VMs to vMotion, sleeping for $($config.WaitForVMotionDelay) seconds...done"


#------------------------------------------------------------------------------------
#Shut down the second StarWind storage VM. Have to do this before putting host into
#maintance mode. Wait a few minutes for this to complete.
Write-Log -Line "Shutting down second StarWind storage VM..."
$starwindVM2 = Get-VM -Name $config.StarWind.VM2Name
$starwindVM2 | Shutdown-VMGuest -Confirm:$false | Out-Null
Write-Log -Line "Shutting down second StarWind storage VM...done"

Write-Log -Line "Waiting for second StarWind storage VM to shut down, sleeping for $($config.WaitForStarWindShutdownDelay)..."
Start-Sleep $config.WaitForStarWindShutdownDelay
Write-Log -Line "Waiting for second StarWind storage VM to shut down, sleeping for $($config.WaitForStarWindShutdownDelay)...done"


#------------------------------------------------------------------------------------
#Put second ESXi host into maintenace mode. This will not 
Write-Log -Line "Putting second ESXi host into maintance mode..."
Get-VMHost -Name $config.ESXi.Host2FQDN | Set-VMHost -State Maintenance | Out-Null
Write-Log -Line "Putting second ESXi host into maintance mode...done"

Write-Log -Line "Waiting for second ESXi to enter maintance mode, sleeping for $($config.WaitForMaintanceModeDelay)..."
Start-Sleep $config.WaitForMaintanceModeDelay
Write-Log -Line "Waiting for second ESXi to enter maintance mode, sleeping for $($config.WaitForMaintanceModeDelay)...done"


#------------------------------------------------------------------------------------
#Done. All running VMs were consolidated to first host and second host is in maintance
#mode.
Write-Log -Line "Consolidating VMs of utility power failure...done"
