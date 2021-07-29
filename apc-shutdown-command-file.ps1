<#
INTRODUCTION:
This script handles shutting down a vSphere environment in a safe manner during a utility
power failure to reduce teh chances of data corruption. This script is designed to be run
by APC's PowerChute Network Server software against a 2-node vSphere cluster running
StarWind's hyperconverged vSAN storage solution.

DETAILS:
This script will attempt to gracefully shut down all your VMs (except vCenter and the
StarWind storage VMs), then non-gracefully power off any VMs that do not shut down quickly
enough, then shut down vCenter, put StarWind into maintance mode, and finally shut down 
the ESXi hosts (which will in turn shut down the StarWind storage VMs). This order of 
operations is designed to limit the chances of data corruption on the StarWind vSAN VMs
and ensure the infrastructure can be restarted quickly (little resynchronization time).

This script must run on a host that is independent of your vSphere environment. This is
done because if this script ran on a VM inside the vSphere environment, it would not be
able to shutdown the environment properly because the VM itself would be shut down. An
idea would be to purchase a small, low power computer (such as an Intel NUC) and run this
script on it. The system running the PowerChute software and this script does become a
single point of failure so please take not of that in your planning (you could potentially
run redundant systems with PowerChute and this script monitoring your same UPS(s) but how
to handle the race condition between the two hosts becomes a bit problematic)

The configuration needed to run this script is generated upon the first-run when you run
this script interactively (in a powershell window). A JSON formatted configuration file is
saved to the same directory this script is located in. Note that the configuration file will
include the passwords to your vSphere system, ESXi hosts, and StarWind management port. You
should create separate users and roles for vSphere and ESXi with minimal permissions to
protect against misuse. You should also make sure the system running PowerChute and this
script are hardened (it is best to use a non-domain joined system). Powershell secure-string
is not used since doing so is difficult because APC PowerChute runs commands as the
NT Authority/System user but it is very difficult to create and store secure-string passwords
as this user (you need to use the same user to create a secure-string as you will read said
secure string).

vSphere Permissions:
    - Host > Inventory > Modify Cluster (to disable vSphere High Availability).
    - Virtual Machine > Interaction > Power off (to shut down VMs).
ESXi Permissions (create matching users on both hosts):
    - System > Anonymous, System > View, System > Read (basic permissions).
    - Host > Config > Power (to shut down host).
    - VirtualMachine > Interact > PowerOff (to shut down VMs).

You should never have to modify this script directly!

TESTING:
1) Set the DoVMShutdowns, DoVcenterShutdown, DoStarWindMaintance, and/or DoESXiShutdowns
   variables to false (note no quotes).  This will prevent shutdown commands from running 
   against your in-production infrastructure but you will be able to inspect the logging 
   output for expected results.
2) Set the tag "test-vm-apc-shutdown" on a few of your test, development, or less important
   VMs. Set the Tag in the config file to the same "test-vm-apc-shutdown" tag. Run this 
   script to make sure only your tagged VMs are logged for shutting down.
3) Set the tag "test-vm-apc-shutdown" on a few of your test, development, or less important
   VMs. Set the Tag in the config file to the same "test-vm-apc-shutdown" tag. Set the 
   DoVMShutdowns field to true. Run this script and check if only your tagged VMs were shut
   down.
4) Set the Tag to "" and set DoVMShutdowns to true. During NON-PRODUCTION-HOURS, run this
   script and check if all your VMs are shut down (except vCenter and StarWind VMs).
5) Set the DoVcenterShutdown field to true, run this script, and check if vCenter is shut
   down. Not during production hours!
6) Set the DoStarWindMaintance field to true and check if the StarWind devices are put into
   maintance mode. You will need a system with StarWind Management Console to view the status
   of maintance mode. Again, not during production hours and make sure all your VMs are turned
   off first (or will be turned off via this script).
7) Set the DoESXiShutdowns field to true, run this script, and check if your ESXi hosts are
   shut down. The StarWind appliance VMs should automatically be shut down first.

PRODUCTION USE:
1) Set the DoVMShutdowns, DoVcenterShutdown, DoStarWindMaintance, and/or DoESXiShutdowns
   fields to true (not no quotes).
2) Set the proper log file directory and set WriteToFile to true. Make sure permissions
   to write to the log file directory are set properly.
3) Remove the Tag by setting it to "".

NOTES:
- You will need to run this script interactively, in a powershell window, initially to create
  and save the configuration file. You can edit the configuration file manually after it is
  created.
- There is VERY LITTLE error handling in this script. It is advised to heavily test this
  script during non-work hours to check for errors.
- You should ensure your UPS(s) have adequate runtime to allow this script to run to
  completion. You should also ensure your UPS(s) are configured with the proper runtime
  delays, wait times, etc.
- You could run this script on an Ubuntu (or other Linux OS) since powershell is available
  on Linux as powershell-core. However, you would not have access to the StarWind
  Management Console (Windows application) for diagnostics during restart of your 
  infrastructure.
#>


#-------------------------------------------------------------------------------------
#Define configuration. This information is prompted for upon first run (running this script
#interactively) and is saved to a JSON file. This information is read from the JSON file on 
#subsequent runs. Doing so keeps the configuration separate from the script so that an 
#end-user does not need to modify this script's contents at all.
$config = [PSCustomObject]@{
    #user credentials and systems to connect to.
    VCenter                      = [PSCustomObject]@{
        IP             = "10.168.172.100" #IP is recommended over FQDN to prevent DNS issues.
        VMName         = "VMware vCenter Server" #name as shown in vSphere Web Client; used to skip when listing running VMs to prevent shutting down vCenter server prematurely.
        Username       = "non-admin@vsphere.local" #make sure this user only has minimal permissions to shut down VMs and disable vSphere High Availability.
        Password       = ""
        ClusterName    = "Cluster" #your cluster name in vSphere.
        DatacenterName = "Datacenter" #your datacenter name in vSphere.
    }
    ESXi                         = [PSCustomObject]@{
        Host1IP  = "10.168.172.201" #IP is recommended over FQDN to prevent DNS issues.
        Host2IP  = "10.168.172.202" #IP is recommended over FQDN to prevent DNS issues.
        Username = "non-admin" #make sure this user only has minimal permissions to shut down VMs and shut down the host.
        Password = ""
    }
    StarWind                     = [PSCustomObject]@{
        VM1IP    = "10.168.172.221" #used to connect via StarWind powershell module to enter maintence mode for storage. we only need one IP since this will handle storage on both StarWind VMs.
        VM1Name  = "SW-HCA-VM-01" #name as shown in vSphere Web Client; used to skip when listing running VMs to prevent shutting down StarWind storage appliance prematurely.
        VM2Name  = "SW-HCA-VM-02" #name as shown in vSphere Web Client; used to skip when listing running VMs to prevent shutting down StarWind storage appliance prematurely.
        Username = "root" #not the same as GUI/console username and password.
        Password = "starwind" #default per starwind.
    }

    #script configuration
    DoVMShutdowns                = $false #if VMs should be shut down.
    DoVcenterShutdown            = $false #if vCenter should be shut down.
    DoStarWindMaintance          = $false #if StawWind storage devices should be placed in maintance mode preventing reads and writes.
    DoESXiShutdowns              = $false #if ESXi hosts should be shut down.

    WaitForGracefulShutdownDelay = 5 #how many seconds to wait for successful shutdown of VMs after issuing shutdown commands to each (default: 180).
    WaitForNonGracefulDelay      = 5 #how many seconds to wait for successful power-off of VMs after issuing power-off commands to each (default: 30).
    WaitForvCenterShutdownDelay  = 5 #how many seconds to wait for successful shutdown of vCenter VM after issuing shutdown command (default: 120).
    WaitBetweenHostShutdowns     = 5 #how many seconds to wait between shutting down each ESXi host (default: 60).

    #A vSphere tag applied to the VMs you want to shut down. This is used for testing 
    #purposes by only shutting down certain VMs (i.e.: your development or test VMs)
    #that are tagged with this tag. Apply this tag to your VMs in vSphere for testing
    #purposes ONLY and REMOVE the tag ("") when you want to run this script in production 
    #against all VMs. You can change this tag as needed just make sure it matches the 
    #tag you used in vSphere (default: test-vm-apc-shutdown).
    Tag                          = "test-vm-apc-shutdown"

    Logging                      = [PSCustomObject]@{
        WriteToFile     = $false #set to $true to write logging to a file, set to $false to write to terminal. $true should be used for production so you can inspect logs
        PathToDirectory = "C:\Users\corey.SIMALFA\Desktop\apc\" #path to location where log files will be saved. Make sure you have permission to write to this location.
    }

    #Email server configuration is used to send an alert when this script is run. This
    #lets administrators know this script is running and provides a secondary alert
    #separate from your APC UPS's alerts. Note that you will obviously have to have
    #a network connection to your email server which may not exist if your networking
    #equipment isn't powered (power outage) or your WAN connection is down.
    Emails                       = [PSCustomObject]@{
        Enable    = $true
        Server    = "exchange.simalfa.com" #IP or FQDN of your email server.
        Port      = 25 #email server SMTP port (default: 25).
        Recipient = "system.alerts@simalfa.com" #who email will be sent to.
        From      = "apc-shutdown-ps1@example.com" #who email will be sent from.
    }
}


#-------------------------------------------------------------------------------------
#Some defaults for use when gathering user input and building configuration.
$defaultWaitForGracefulShutdownDelay = 180
$defaultWaitForNonGracefulDelay = 30
$defaultWaitForvCenterShutdownDelay = 180
$defaultWaitBetweenHostShutdowns = 60
$defaultSMTPPort = 25


#-------------------------------------------------------------------------------------
#Check if configuration file exists, otherwise prompt user for data to build configuration.
#The configuration file should be stored in the same directory as this script. If the file
#does not exist, it will be created.
$configFileName = "apc-shutdown-command-file.config"
$scriptRunningDirectory = "C:\Program Files\APC\PowerChute\user_files"
$pathToConfigFile = Join-Path -Path $scriptRunningDirectory -ChildPath $configFileName

Write-Host "Searching for config file at '$pathToConfigFile'..."
$exists = Test-Path -Path $pathToConfigFile
if (!$exists) {
    Write-Host "Config file does not exist, gathering data to create config file..."

    #gather data from user
    $config.VCenter.IP = Read-Host -Prompt "Enter your vCenter IP"
    $config.VCenter.VMName = Read-Host -Prompt "Enter your vCenter VM's name (as displayed in vSphere)"
    $config.VCenter.Username = Read-Host -Prompt "Enter your vCenter username (should be a minimal-permissioned user solely used for this script)"
    $config.VCenter.Password = Read-Host -Prompt "Enter your vCenter user's password"
    $config.VCenter.ClusterName = Read-Host -Prompt "Enter your vCenter cluster name"
    $config.VCenter.DatacenterName = Read-Host -Prompt "Enter your vCenter datacenter name"
    
    $config.ESXi.Host1IP = Read-Host -Prompt "Enter your first ESXi server IP"
    $config.ESXi.Host2IP = Read-Host -Prompt "Enter your seccond ESXi server IP"
    $config.ESXi.Username = Read-Host -Prompt "Enter your ESXi username (should be a minimal-permissioned user solely used for this script)"
    $config.ESXi.Password = Read-Host -Prompt "Enter your ESXi user's password"
    
    $config.StarWind.VM1IP = Read-Host -Prompt "Enter the IP address for one of your StarWind VMs"
    $config.StarWind.VM1Name = Read-Host -Prompt "Enter the name for your first StarWind VM (as displayed in vSphere)"
    $config.StarWind.VM2Name = Read-Host -Prompt "Enter the name for your second StarWind VM (as displayed in vSphere)"
    $config.StarWind.Username = Read-Host -Prompt "Enter your StarWind username"
    $config.StarWind.Password = Read-Host -Prompt "Enter your StarWind user's password"

    $do = Read-Host -Prompt "Shut down VMs? (Y/N)"
    if ($do -eq "Y" -or $do -eq "y") {
        $config.DoVMShutdowns = $true
    }
    else {
        $config.DoVMShutdowns = $false
    }
    $do = Read-Host -Prompt "Shut down vCenter? (Y/N)"
    if ($do -eq "Y" -or $do -eq "y") {
        $config.DoVcenterShutdown = $true
    }
    else {
        $config.DoVcenterShutdown = $false
    }
    $do = Read-Host -Prompt "Put StarWind into maintance mode? (Y/N)"
    if ($do -eq "Y" -or $do -eq "y") {
        $config.DoStarWindMaintance = $true
    }
    else {
        $config.DoStarWindMaintance = $false
    }
    $do = Read-Host -Prompt "Shut down ESXi? (Y/N)"
    if ($do -eq "Y" -or $do -eq "y") {
        $config.DoESXiShutdowns = $true
    }
    else {
        $config.DoESXiShutdowns = $false
    }

    [int]$config.WaitForGracefulShutdownDelay = Read-Host -Prompt "Seconds to wait for VMs to gracefully shut down. (default: $defaultWaitForGracefulShutdownDelay)"
    if ($config.WaitForGracefulShutdownDelay -le 0) {
        $config.WaitForGracefulShutdownDelay = $defaultWaitForGracefulShutdownDelay
    }
    [int]$config.WaitForNonGracefulDelay = Read-Host -Prompt "Seconds to wait for VMs to forcefully power off. (default: $defaultWaitForNonGracefulDelay)"
    if ($config.WaitForNonGracefulDelay -le 0) {
        $config.WaitForNonGracefulDelay = $defaultWaitForNonGracefulDelay
    }
    [int]$config.WaitForvCenterShutdownDelay = Read-Host -Prompt "Seconds to wait for vCenter to gracefully shut down. (default: $defaultWaitForvCenterShutdownDelay)"
    if ($config.WaitForvCenterShutdownDelay -le 0) {
        $config.WaitForvCenterShutdownDelay = $defaultWaitForvCenterShutdownDelay
    }
    [int]$config.WaitBetweenHostShutdowns = Read-Host -Prompt "Seconds to wait for between shutting down ESXi hosts. (default: $defaultWaitBetweenHostShutdowns)"
    if ($config.WaitBetweenHostShutdowns -le 0) {
        $config.WaitBetweenHostShutdowns = $defaultWaitBetweenHostShutdowns
    }

    $config.Tag = Read-Host -Prompt "vSphere tag to target only certain VMs (use for testing)"
    
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


#-------------------------------------------------------------------------------------
#Calidate the config file (since user could have changed it manually).
if ($config.VCenter.IP -eq "") {
    Write-Host "No vCenter IP provided in config file."
    exit
}
if ($config.VCenter.VMName -eq "") {
    Write-Host "No vCenter VM name provided in config file."
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
if ($config.VCenter.DatacenterName -eq "") {
    Write-Host "No vCenter datacenter name provided in config file."
    exit
}
if ($config.ESXi.Host1IP -eq "") {
    Write-Host "No IP provided for your first ESXi host in config file."
    exit
}
if ($config.ESXi.Host2IP -eq "") {
    Write-Host "No IP provided for your second ESXi host in config file."
    exit
}
if ($config.ESXi.Username -eq "") {
    Write-Host "No ESXi username provided in config file."
    exit
}
if ($config.ESXi.Password -eq "") {
    Write-Host "No ESXi password provided in config file."
    exit
}
if ($config.StarWind.VM1IP -eq "") {
    Write-Host "No IP provided for one of your StarWind VMs in config file."
    exit
}
if ($config.StarWind.VM1Name -eq "") {
    Write-Host "No VM name provided for first StarWind VM in config file."
    exit
}
if ($config.StarWind.VM2Name -eq "") {
    Write-Host "No VM name provided for second StarWind VM in config file."
    exit
}
if ($config.StarWind.Username -eq "") {
    Write-Host "No StarWind username provided in config file."
    exit
}
if ($config.StarWind.Password -eq "") {
    Write-Host "No StarWind password provided in config file."
    exit
}
if ($config.WaitForGracefulShutdownDelay -lt 0) {
    Write-Host "Invalid WaitForGracefulShutdownDelay set in config file. Must be at least 1 (seconds)."
    exit
}
if ($config.DoVMShutdowns -ne $true -and $config.DoVMShutdowns -ne $false) {
    Write-Host "Invalid DoVMShutdowns set in config file. Must be at true or false (without quotes)."
    exit
}
if ($config.DoVcenterShutdown -ne $true -and $config.DoVcenterShutdown -ne $false) {
    Write-Host "Invalid DoVcenterShutdown set in config file. Must be at true or false (without quotes)."
    exit
}
if ($config.DoStarWindMaintance -ne $true -and $config.DoStarWindMaintance -ne $false) {
    Write-Host "Invalid DoStarWindMaintance set in config file. Must be at true or false (without quotes)."
    exit
}
if ($config.DoESXiShutdowns -ne $true -and $config.DoESXiShutdowns -ne $false) {
    Write-Host "Invalid DoESXiShutdowns set in config file. Must be at true or false (without quotes)."
    exit
}
if ($config.WaitForNonGracefulDelay -lt 0) {
    Write-Host "Invalid WaitForNonGracefulDelay set in config file. Must be at least 1 (seconds)."
    exit
}
if ($config.WaitForvCenterShutdownDelay -lt 0) {
    Write-Host "Invalid WaitForvCenterShutdownDelay set in config file. Must be at least 1 (seconds)."
    exit
}
if ($config.WaitBetweenHostShutdowns -lt 0) {
    Write-Host "Invalid WaitBetweenHostShutdowns set in config file. Must be at least 1 (seconds)."
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


#-------------------------------------------------------------------------------------
#Define list of VMs that we will ignore from shutting down. These VMs are vCenter server,
#the StarWind VMs, and any other VMs that are somehow separately managed.
$ignoredVMNames = @($vcenterVMName, $starwindVM1Name, $starwindVM2Name)


#-------------------------------------------------------------------------------------
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
    $pathToLogFile = Join-Path $config.Logging.PathToDirectory -ChildPath "shutdownlog--$date--$time.txt"
    $logfile = New-Item -ItemType file $pathToLogFile -Force
}

Write-Log -Line "Shutdown infrastructure because of utility power failure..."
Write-Log -Line "This script will shutdown all of the VMs and hosts using:"
Write-Log -Line " vCenter: $($config.VCenter.IP)"
Write-Log -Line " vCenter User: $($config.VCenter.Username)"
Write-Log -Line " ESXi Hosts: $($config.ESXi.Host1IP), $($config.ESXi.Host2IP)"
Write-Log -Line " ESXi User: $($config.ESXi.Username)"
Write-Log -Line " StarWind Hosts: $($config.StarWind.VM1Name), $($config.StarWind.VM2Name)"
Write-Log -Line " StarWind User: $($config.StarWind.Username)"

#empty lines are used to separate warning in logging so that stand out a bit more.
Write-Log -Line ""
if ($config.DoVMShutdowns -eq $false) {
    Write-Log -Line "WARNING! DoVMShutdowns is FALSE! VMs will not be shut down."
}
if ($config.DoVcenterShutdown -eq $false) {
    Write-Log -Line "WARNING! DoVcenterShutdown is FALSE! vCenter will not be shut down."
}
if ($config.DoESXiShutdowns -eq $false) {
    Write-Log -Line "WARNING! DoESXiShutdowns is FALSE! ESXi hosts will not be shut down and vSphere High Availability will not be disabled."
}
if ($config.DoStarWindMaintance -eq $false) {
    Write-Log -Line "WARNING! DoStarWindMaintance is FALSE! StarWind devices will not be put in maintance mode."
}
Write-Log -Line ""


#-------------------------------------------------------------------------------------
#Additional warning logging if tag is enabled since this should only be used for testing
#and not all (if any VMs) will be affected (i.e. shut down). This is separated from warnings
#above so that it stands out more in logging.
if ($config.Tag -ne "") {
    Write-Log -Line "WARNING! VM tag ($($config.Tag)) set, not all VMs will be sent shutdown commands. This should ONLY be used during testing."
    Write-Log -Line ""
}


#-------------------------------------------------------------------------------------
#Some error checking. This is used to make sure we are shutting down child elements
#if we are shutting down parents (i.e.: don't shut down hosts without first shutting
#down VMs).
if ($config.DoESXiShutdowns -and !$config.DoVMShutdowns) {
    Write-Log -Line "ERROR! You cannot enable host shutdowns if you have disabled VM shutdowns. VMs should always be shut down if hosts are shutting down."
    exit
}
if ($config.DoVcenterShutdown -and !$config.DoVMShutdowns) {
    Write-Log -Line "ERROR! You cannot shut down vCenter without shutting down VMs first."
    exit
}
if ($config.DoStarWindMaintance -and !$config.DoVMShutdowns) {
    Write-Log -Line "ERROR! You cannot put the StarWind storage into maintance mode without shutting down VMs first as this could cause corruption."
    exit
}
if ($config.DoStarWindMaintance -and !$config.DoVcenterShutdown) {
    Write-Log -Line "ERROR! You cannot put the StarWind storage into maintance mode without shutting down vCenter first as this could cause corruption."
    exit
}


#-------------------------------------------------------------------------------------
#Send email alert that this script is running.
#Note taht Send-MailMessage is obsolete but it still works as of now. This is way easier
#than having to import a third-party mail client for powershell.
if ($config.Emails.Enable) {
    Write-Log -Line "Sending alert email..."
    
    $subject = "APC Shutdown Command Powershell Running..."
    $body = "The APC Shutdown Command powershell script is running. Your VMs will be shut down, followed by shutdown of vCenter, and the StarWind storage and ESXi hosts. No further emails will be sent from this script."
    Send-MailMessage -SmtpServer $config.Emails.Server -Port $config.Emails.Port -From $config.Emails.From -To $config.Emails.Recipient -Subject $subject -Body $body
    

    Write-Log -Line "Sending alert email...sent to $($config.Emails.Recipient)"
    Write-Log -Line "Sending alert email...done"
}


#-------------------------------------------------------------------------------------
#Create powershell credentials for use with PowerCLI to connect to vCenter and ESXi.
$vcenterPasswordSS = ConvertTo-SecureString $config.VCenter.Password -AsPlainText -Force
$vcenterCredentials = New-Object System.Management.Automation.PSCredential ($config.VCenter.Username, $vcenterPasswordSS)

$esxiPasswordSS = ConvertTo-SecureString $config.ESXi.Password -AsPlainText -Force
$esxiCredentials = New-Object System.Management.Automation.PSCredential ($config.ESXi.Username, $esxiPasswordSS)


#-------------------------------------------------------------------------------------
#Connect to vCenter.

#Disable prompts/logging about sending diagnostics to VMware. This just cleans up logging
#output.
Set-PowerCLIConfiguration -Scope User -ParticipateInCeip $false -Confirm:$false | Out-Null

#If you have a valid https certificate installed on vCenter, you can comment out the 
#following line.  By default, we assume you are using the default self-signed certificate
#that will be marked as invalid.
Set-PowerCLIConfiguration -InvalidCertificateAction ignore -Confirm:$false | Out-Null

#Set PowerCLI into single-vcenter server mode to run this script.  Otherwise some errors
#might be returned or this script could require user interaction which should not happen.
Set-PowerCLIConfiguration -DefaultVIServerMode "Single" -Confirm:$false | Out-Null

Write-Log -Line "Connecting to vCenter $($config.VCenter.IP) ($($config.VCenter.VMName))..."
$success = Connect-VIServer $config.VCenter.IP -Credential $vcenterCredentials -WarningAction:SilentlyContinue
if ($success) {
    Write-Log -Line "Connecting to vCenter $($config.VCenter.IP) ($($config.VCenter.VMName))...done"
}
else {
    Write-Log -Line "Connecting to vCenter $($config.VCenter.IP) ($($config.VCenter.VMName))...ERROR!"
    exit
}


#-------------------------------------------------------------------------------------
#Diable vSphere High Availability (HA) on the cluster. This is done to prevent issues
#where VMs are restarted unexpectedly during this shutdown process or when the cluster
#starts up again.
Write-Log -Line "Disabling vSphere High Availability on the cluster $($config.VCenter.ClusterName)..."
if ($config.DoESXiShutdowns) {
    Get-Cluster $config.VCenter.ClusterName | Set-Cluster -HAEnabled:$false -confirm:$false
    Write-Log -Line "Disabling vSphere High Availability on the cluster $($config.VCenter.ClusterName)...done"
}
else {
    Write-Log -Line "Disabling vSphere High Availability on the cluster $($config.VCenter.ClusterName)...IGNORED"
}


#-------------------------------------------------------------------------------------
#Get the list of VMs to shutdown.
#Sorting alphabetically just helps with organizing logging.
#Tag is used for limiting which VMs this script will send shutdown commands to.  A tag
#should ONLY be set for TESTING purposes otherwise some VMs may be missed from being
#shutdown and could be corrupted when the StarWind storage enters maintance mode
#(preventing all access to the vSphere disks).
Write-Log -Line "Getting list of running VMs in cluster $($config.VCenter.ClusterName) to shut down..."
if ($config.Tag -ne "") {
    $poweredOnVMs = Get-VM -Location $config.VCenter.ClusterName -Tag $config.Tag | Where-Object { $_.PowerState -eq "PoweredOn" } | Sort-Object
    Write-Log -Line "Getting list of running VMs in cluster $($config.VCenter.ClusterName) to shut down...using tag '$($config.Tag)'..."
}
else {
    $poweredOnVMs = Get-VM -Location $config.VCenter.ClusterName | Where-Object { $_.PowerState -eq "PoweredOn" } | Sort-Object
}
Write-Log -Line "Getting list of running VMs in cluster $($config.VCenter.ClusterName) to shut down...done"

#-------------------------------------------------------------------------------------
#Issue graceful shutdown commands to each running VM. This will use VMware tools to
#send a "shutdown guest" command which should tell each VM to shutdown gracefully. This
#depends on your VMware tools shutdown command for each VM set in vSphere. The default
#settings will use a graceful shutdown. Note that if VMware tools is not installed in
#the VM, a non-graceful shutdown (power off) will be performed.
Write-Log -Line "Sending graceful shutdown commands to VMs..."
ForEach ($vm in $poweredOnVMs) {
    #Make sure we don't shut down the vcenter server or starwind storage VMs.
    #The vCenter server needs to remain running since we are sending commands to it to
    #shut down the running VMs. The StarWind VMs need to remain running since they
    #provide the storage to each ESXi host that the VMs are running on.
    if (!$ignoredVMNames.Contains($vm.Name)) {
        Write-Log -Line "Processing $vm..."

        #Check if VMware tools is installed.
        #If no, issue a non-graceful power off command.
        #If yes, issue a gracefule shutdown command.
        $vmInfo = get-view -Id $vm.ID
        if ($vmInfo.config.Tools.ToolsVersion -eq 0) {
            Write-Log -Line "Processing $vm...vmware tools not installed, issuing non-graceful power off."
            if ($config.DoVMShutdowns) {
                Stop-VM $vm -confirm:$false | out-null
                Write-Log -Line "Processing $vm...vmware tools not installed, issuing non-graceful power off...done"
            }
            else {
                Write-Log -Line "Processing $vm...vmware tools not installed, issuing non-graceful power off...IGNORED"
            }
        }
        else {
            Write-Log -Line "Processing $vm...vmware tools installed, issuing graceful shutdown..."
            if ($config.DoVMShutdowns) {
                $vm | Shutdown-VMGuest -Confirm:$false | out-null
                Write-Log -Line "Processing $vm...vmware tools installed, issuing graceful shutdown...done"
            }
            else {
                Write-Log -Line "Processing $vm...vmware tools installed, issuing graceful shutdown...IGNORED"
            }
        }

        Write-Log -Line "Processing $vm...done"
    } #end if: VM is not vCenter or StarWind
} #end for: loop through powered on VMs
Write-Log -Line "Sending graceful shutdown commands to VMs...done"


#-------------------------------------------------------------------------------------
#VMs will probably take a few minutes to shut down. Wait before proceeding. How much
#time it will take for all your VMs to shutdown gracefully is hard to determine, so
#you will probably have to play with this value a bit.
Write-Log -Line "Waiting for VMs to gracefully shut down, sleeping for $($config.WaitForGracefulShutdownDelay) seconds..."
Start-Sleep $config.WaitForGracefulShutdownDelay
Write-Log -Line "Waiting for VMs to gracefully shut down, sleeping for $($config.WaitForGracefulShutdownDelay) seconds...done"


#-------------------------------------------------------------------------------------
#Iterate through VMs again checking if any are still running. If any are running,
#power them off. This is a non-graceful shutdown and is done because we want to have
#all VMs powered off before shutting down vCenter, the ESXi hosts, or the StarWind
#storage VMs. We re-retrieve the list of running VMs since most (hopefully all) should
#have already been shut down gracefully. We don't reuse the $poweredOnVMs variable so
#we can be extra certain we are re-retrieving the list of VMs.
Write-Log -Line "Getting list of still-running VMs in cluster $($config.VCenter.ClusterName) to power off..."
if ($config.Tag -ne "") {
    $poweredOnVMs2 = Get-VM -Location $config.VCenter.ClusterName -Tag $config.Tag | Where-Object { $_.PowerState -eq "PoweredOn" } | Sort-Object
    Write-Log -Line "Getting list of still-running VMs in cluster $($config.VCenter.ClusterName) to power off...using tag '$($config.Tag)'..."
}
else {
    $poweredOnVMs2 = Get-VM -Location $config.VCenter.ClusterName | Where-Object { $_.PowerState -eq "PoweredOn" } | Sort-Object
}
Write-Log -Line "Getting list of still-running VMs in cluster $($config.VCenter.ClusterName) to power off...done"

Write-Log -Line "Sending power-off shutdown commands to any still-running VMs in cluster $($config.VCenter.ClusterName)..."
ForEach ( $vm in $poweredOnVMs2 ) {
    #Make sure we don't shut down the vcenter server or starwind storage VMs.
    #The vCenter server needs to remain running since we are sending commands to it to
    #shut down the running VMs. The StarWind VMs need to remain running since they
    #provide the storage to each ESXi host that the VMs are running on.
    if (!$ignoredVMNames.Contains($vm.Name)) {
        Write-Log -Line "Processing $vm..."
        if ($doVMShutdowns) {
            Stop-VM $vm -confirm:$false | out-null
            Write-Log -Line "Processing $vm...done"
        }
        else {
            Write-Log -Line "Processing $vm...IGNORED"
        }
    } #end if: VM is not vCenter or StarWind
} #end for: loop through powered on VMs
Write-Log -Line "Sending power-off shutdown commands to any still-running VMs in cluster $($config.VCenter.ClusterName)...done"


#-------------------------------------------------------------------------------------
#Wait a short amount of time for VMs to be powered off. Non-graceful power-offs should
#happen pretty quickly.
Write-Log -Line "Waiting for VMs to power off, sleeping for $($config.WaitForNonGracefulDelay) seconds..."
Start-Sleep $config.WaitForNonGracefulDelay
Write-Log -Line "Waiting for VMs to power off, sleeping for $($config.WaitForNonGracefulDelay) seconds...done"


#-------------------------------------------------------------------------------------
#Shut down vCenter server. It should be the only VM, outside the StarWind storage VMs,
#that is still running.  This is okay to shut down now since we will connect to the
#hosts to shut them down (and their respective StarWind storage VMs).
Write-Log -Line "Shut down vCenter server..."
if ($config.DoVcenterShutdown) {
    Shutdown-VMGuest $config.VCenter.VMName -Confirm:$false
    Write-Log -Line "Shut down vCenter server...done"
}
else {
    Write-Log -Line "Shut down vCenter server...IGNORED"
}


#-------------------------------------------------------------------------------------
#Wait for vCenter server to shut down. This can typically take some time.
Write-Log -Line "Waiting for vCenter to gracefully shut down, sleeping for $($config.WaitForvCenterShutdownDelay) seconds..."
Start-Sleep $config.WaitForvCenterShutdownDelay
Write-Log -Line "Waiting for vCenter to gracefully shut down, sleeping for $($config.WaitForvCenterShutdownDelay) seconds...done"


#-------------------------------------------------------------------------------------
#Put StarWind devices (storage HA images) into Maintance Mode. Note that this is not
#vSphere maintance mode. The StarWind powershell module must be installed via the
#StarWind Management Console installer. Putting StarWind into maintance mode will
#prevent storage related issues, possible corruption, and avoids long resynchronization
#when the infrastructure is restarted.  We only need to interface with one StarWind
#VM here (one IP address) as putting the storage device into maintance mode will affect
#both StarWind VMs. Once the storage devices are in maintance mode, the two storage
#VMs will be synchronzied (matching data on both) and nothing will be able to read or
#write to the storage (which is why it is important to turn off all VMs before this).
Import-Module StarWindX
Write-Log -Line "Putting StarWind into maintance mode..."
try {
    $starwindServer = New-SWServer -host $config.StarWind.VM1IP -port 3261 -user $config.StarWind.Username -password $config.StarWind.Password
    $starwindServer.Connect()

    ForEach ($device in $starwindServer.Devices) {
        if (!$device) {
            Write-Log -Line "Putting StarWind into maintance mode...no devices found, there should have been!"
            return
        }
        else {
            #StarWind high availability storage devices are typically named "HAImage*". You can
            #look this up via the StarWind Management Console. Set the device into maintance mode.
            $disk = $device.Name
            if ($device.Name -like "HAImage*") {
                Write-Log -Line "Putting StarWind into maintance mode...$disk..."
                if ($config.DoStarWindMaintance) {
                    $device.SwitchMaintenanceMode($true, $true)
                    Write-Log -Line "Putting StarWind into maintance mode...$disk...done"
                }
                else {
                    Write-Log -Line "Putting StarWind into maintance mode...$disk...IGNORED"
                }
            }
            else {
                Write-Log -Line "Device is not a HA device, maintance mode is not supported...$disk"
            } #end if: disk is an expected HAImage
        } #end if: device was found.
    } #end for: loop through each StarWind device.
} #end try
catch {
    Write-Log -Line "Putting StarWind into maintance mode...error encounted"
} #end catch
finally {
    #disconnect from the StarWind VM
    $starwindServer.Disconnect()
} #end finally: put StarWind devices into maintance mode.
Write-Log -Line "Putting StarWind into maintance mode...done"


#-------------------------------------------------------------------------------------
#Shut down the ESXi hosts. This will also shut down the StarWind storage VMs and should
#do so gracefully.
Write-Log -Line "Shut down ESXi1..."
Connect-VIServer $config.ESXi.Host1IP -Credential $esxiCredentials -WarningAction:SilentlyContinue | Out-Null
if ($config.DoESXiShutdowns) {
    Stop-VMHost $config.ESXi.Host1IP -Confirm:$false -Force
}
else {
    Write-Log -Line "Shut down ESXi1...IGNORED"
}
Write-Log -Line "Shut down ESXi1...done"

#Sleep for a few seconds just so both hosts are going down at the exact same time. Is this
#really needed, probably not.
Write-Log -Line "Waiting for ESXi1 to shut down, sleeping for $($config.WaitBetweenHostShutdowns) seconds..."
Start-Sleep $config.WaitBetweenHostShutdowns
Write-Log -Line "Waiting for ESXi1 to shut down, sleeping for $($config.WaitBetweenHostShutdowns) seconds...done"

Write-Log -Line "Shut down ESXi2..."
Connect-VIServer $config.ESXi.Host2IP -Credential $esxiCredentials -WarningAction:SilentlyContinue | Out-Null
if ($config.DoESXiShutdowns) {
    Stop-VMHost $config.ESXi.Host2IP -Confirm:$false -Force
}
else {
    Write-Log -Line "Shut down ESXi2...IGNORED"
}
Write-Log -Line "Shut down ESXi2...done"


#-------------------------------------------------------------------------------------
#Done.  All VMs and hosts have been turned off.
Write-Log -Line "Shutdown infrastructure because of utility power failure...done"
