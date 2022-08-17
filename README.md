# powerchute-vsphere-starwind-shutdown

## Introduction:
These scripts handle shutting down or consolidating a vSphere environment during a power loss event. These scripts are designed to be run by APC's PowerChute Network Server software against a 2-node vSphere cluster running StarWind's hyperconverged vSAN storage solution.


## Target/Required Infrastructure:
- 2-node vSphere cluster.
- StarWind HCA vSAN.
- APC UPS(s) with NMC(s) installed.
- APC PowerChute Network Server (PCNS).
- Network communication between the system PCNS runs on, the UPS(s), and the vSphere nodes.
- VMware PowerCLI and StarWindX powershell modules installed on the PCNS host system.


## powerchute-consolidate-vms
This script is designed as a first-step when a power failure occurs. It will consolidate all VMs to a single ESXi host and put the other ESXi host into maintance mode. The thought process is that (1) running all VMs off one host makes "locating" the VMs easier in a shutdown or power-restore scenario, (2) that you can shut down the vacated ESXi host to preserve battery runtime, and (3) that there is a lesser chance of storage corruption if all VMs are running on a single StarWind storage VM.

The following steps occur:
- All powered-on VMs are vMotioned from ESXi2 to ESXi1.
- The StarWind storage VM on ESXi2 is shut down.
- ESXi2 is put into maintance mode.


## powerchute-vsphere-starwind-shutdown
This script is designed as a last-step when a power failure occurs. It will shutdown all your VMs and vSphere infrastructure cleanly. Use this when you know power will not be restored before your batteries run out.

The following steps occur:
- All VMs (except vCenter and StarWind) are gracefully shut down (guest OS shutdown).
- Any VMs (except vCenter and StarWind) that remain running, after a delay, are then forcefully shut down (power off).
- vCenter is shut down.
- StarWind storage is put into maintance mode.
- ESXi hosts are shut down (which shuts down the StarWind VMs).


## Script Configuration:
The configuration needed to run each script is generated upon the first-run when you run the script interactively (in a powershell window). A JSON formatted configuration file is saved to the directory where the scripts needs to be placed/located per APC's documentation (`C:\Program Files\APC\PowerChute\user_files`). The configurations, and scripts, are designed so that you should never have to modify the powershell script directly.

Note that the configuration files will include the passwords. You *should* create separate users and roles for vSphere and ESXi with minimal permissions to protect against misuse (see the scripts for the permissions required).


## cmd vs ps1 Files:
The .cmd files are provided as the command scripts in PCNS. The .cmd file simply call the corresponding .ps1 file. This is needed since PCNS will not run a PS file directly.


## Testing The Scripts as PCNS Command Files:
There are two "hacky" ways to confirm that PCNS can run a script properly. PCNS does not provide a good method of testing in another "non-hacky" manner. 

The first method is to run the script ( the .cmd file) via the "NMC cannot communicate with the UPS" event and simply pull the ethernet cord from the NMC (UPS network card). 

The second involved editing the `pcnsconfig.ini` file. Stop the PowerChute Network Shutdown service, open the file, edit the `event_MonitoringStarted_enableCommandFile` line setting it to `true`, and edit the `event_MonitoringStarted_commandFilePath` line setting it to the path to your script cmd file in the `user_files` directory. Save the file and restart the service. 

Monitor the `cmdfile.log` and `error.log` files in the `%Program Files%\APC\PowerChute\group1` folder for diagnostic information.


## PCNS Details:
The machine where APC PowerChute is installed, and where these scripts run from, *must* be a machine/host that is independent of your vSphere environment. This is required because if PCNS and these scripts are run on a VM inside the vSphere environment, it would not be able to shutdown the environment properly because the VM itself would be shut down. An idea would be to purchase a small, low power computer (such as an Intel NUC) and run this script on it.

You should harden the system running PCNS since it can shut down your infrastructure:
- Do not join the system running APC PowerChute to a domain.
- Set a long, complex password for the default Windows administrator user.
- Make sure Windows firewall is enabled with only the minimal ports needed for PowerChute opened.
- Make sure antivirus is working.
- Make sure file sharing is turned of.
- Make sure remote desktop access is turned off.

Installation help:
- When presented with the Virtualization Support options, choose "Do not enable Virtualization Support".
- When presented the option about what do to after shutting down running machines, choose "Do not turn off the UPS".


## Notes:
- There is very little error handling in these scripts. It is advised to heavily test during non-work hours to check for errors.
- You should ensure your UPS(s) have adequate runtime to allow the scripts to run to completion. You should also ensure your UPS(s) are configured with the proper runtime delays, wait times, etc. Setting up the UPS NMC and PCNS properly is, simply put, a pain.


## Currently Tested/Running Configuration:
- 2-node vSphere 7U3 (ESXi and vCenter).
- StarWind vSAN 8 running on linux VMs.
- PowerChute Network Server 4.4.1.
- Dual APC UPSes, each with NMC 3.
- Windows Server 2016 as the host OS for PCNS.
- VMware PowerCLI 12.2.0 build 17538434 (component versions 12.3).


## Single Point of Failure:
The system running the PCNS software and these script does become a single point of failure so please take note of that in your planning. 
    - Example 1: the system could be hooked up to one of your two UPSes and that UPS has a much shorter runtime causing the script to not run to completion.
    - Example 2: the system only has one network connection and the switch the system is connected to could lose power if the UPS it is connected to dies, therefore the script would run to completion but not be able to contact vCenter, the hosts, or the StarWind VMs to perform the tasks needed.

You could potentially run redundant systems with PCNS and this script monitoring your same UPS(s) but how to handle the race condition between the two systems could become problematic (two systems issuing the same commands to vCenter, the hosts, etc). Also, you would have to handle times when one system only partially completed the shut down commands before it lost power.


## Powershell Help:
- Run the StarWind installer and choose "StarWindX" as the item to install. This should install just the powershell component and install it so it is accessible via scripts. Check if StarWindX is installed using `Get-Module -ListAvailable` and searching for StarWindX.

- Installing the VMware PowerCLI Powershell module:
    - Run `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`.
    - Run `Register-PSRepository -Default`.
    - Run `Set-PSRepository -Name PSGallery -InstallationPolicy Trusted`.
    - Check repositories with `Get-PSRepository`. Make sure the PSGallery repository is listed and is Trusted.
    - Run `Install-Module -Name VMware.PowerCLI -Scope AllUsers` (you may some mix, or all of, the following flags as well: `-Force -SkipPublisherCheck -AllowClobber`).
    - Run `Get-PowerCLIConfiguration` to check if PowerCLI is installed. You will most likely see a warning about the VMware CEIP, use `Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false` to clear this warning out.


## References:
- [StarWind vSAN](https://www.starwindsoftware.com/starwind-virtual-san)
- [StarWind Shutdown Script](https://www.starwindsoftware.com/resource-library/starwind-virtual-san-gentle-shutdown-with-powerchute/) - Does not work (easily) due to usage of secure-string, doesn't allow for easy testing, doesn't have a ton of logging, and the script is pretty messy.
- [APC PowerChute](https://www.apc.com/shop/us/en/categories/power/uninterruptible-power-supply-ups-/ups-management/powerchute-network-shutdown/N-auzzn7)
- [APC Network Management Card User Guide](http://cdn.cnetcontent.com/c0/88/c08805e4-623b-4086-84f4-23077d7ca5b7.pdf)
- [APC PowerChute Install Guide](https://download.schneider-electric.com/files?p_File_Name=990-2838Q-EN.pdf&p_Doc_Ref=SPD_PMAR-9HBK44_EN&p_enDocType=User+guide)
- [APC PowerChute User Guide](https://download.schneider-electric.com/files?p_File_Name=990-4595H-EN-Standard.pdf&p_Doc_Ref=SPD_PMAR-9E5LVY_EN&p_enDocType=User+guide)
- https://www.stevejenkins.com/blog/2013/07/howto-configure-low-battery-duration-and-pcns-to-shut-down-with-an-apc-smartups/
- https://web.archive.org/web/20210727085714/https://www.stevejenkins.com/blog/2013/07/howto-configure-low-battery-duration-and-pcns-to-shut-down-with-an-apc-smartups/