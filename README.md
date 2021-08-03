# powerchute-vsphere-starwind-shutdown

## Introduction:
This script handles shutting down a vSphere environment in a safe manner during a utility power failure to reduce the chances of data corruption. This script is designed to be run by APC's PowerChute Network Server software against a 2-node vSphere cluster running StarWind's hyperconverged vSAN storage solution.

## Target/Required Infrastructure:
- 2-node vSphere cluster running StarWind vSAN.
- APC UPS(s) with NMC(s) installed.
- A system independent from the vSphere cluster running APC's PowerChute Network Server (PCNS).
- Network communication between the system PCNS runs on, the UPS(s), and the vSphere nodes.
- StarWind's powershell module installed on the independent system.

## Details:
This script will attempt to gracefully shut down all of your VMs (except vCenter and the StarWind storage VMs), then non-gracefully power off any VMs that do not shut down quickly enough, then gracefully shut down vCenter, then put StarWind into maintance mode, and finally shut down the ESXi hosts (which will in turn shut down the StarWind storage VMs). This order of operations is designed to limit the chances of data corruption on the StarWind vSAN storage and ensure the infrastructure can be restarted quickly (little vSAN resynchronization time).

This script *must* run on a host that is independent of your vSphere environment. This is required because if this script ran on a VM inside the vSphere environment, it would not be able to shutdown the environment properly because the VM itself would be shut down. An idea would be to purchase a small, low power computer (such as an Intel NUC) and run this script on it.

Please see the How To Guide for step-by-step instructions on setting up an independent system, the UPS(s), and PCNS.

## Configuration:
The configuration needed to run this script is generated upon the first-run when you run this script interactively (in a powershell window). A JSON formatted configuration file is saved to the directory where this script needs to be located per APC's documentation (`C:\Program Files\APC\PowerChute\user_files`). The configuration, and this script, are designed so that you should never have to modify the powershell script directly.

Note that the configuration file will include the passwords to your vSphere system, ESXi hosts, and StarWind management port. You *should* create separate users and roles for vSphere and ESXi with minimal permissions to protect against misuse. You should also make sure the system running PowerChute, and thus this script, is hardened. Powershell secure-string is not used since PowerChute runs commands as the `NT Authority/System` user but it is very difficult to create and store secure-string passwords as this user (you need to use the same user to create a secure-string as you will read said secure-strings).

vSphere Permissions:
- Host > Inventory > Modify Cluster (to disable vSphere High Availability).
- Virtual Machine > Interaction > Power off (to shut down VMs).

ESXi Permissions (create matching users on both hosts):
- System > Anonymous, System > View, System > Read (basic permissions).
- Host > Config > Power (to shut down host).
- VirtualMachine > Interact > PowerOff (to shut down VMs).

## Testing:
1) Set the configuration fields `DoVMShutdowns`, `DoVcenterShutdown`, `DoStarWindMaintance`, and/or `DoESXiShutdowns` to `false` (note that there are no quotes). This will prevent shutdown commands from running against your in-production infrastructure but you will be able to inspect the logging output for expected results.
1) Set the tag "test-vm-apc-shutdown" on a few of your test, development, or less important VMs (in vSphere). Set the configuration field `Tag` to the same "test-vm-apc-shutdown" string. Run this script manually via powershell to make sure only your tagged VMs are logged for shutting down.
1) Set the tag "test-vm-apc-shutdown" on a few of your test, development, or less important VMs. Set the configuration field `Tag` to the same "test-vm-apc-shutdown" string. Set the configuration field `DoVMShutdowns` field to `true`. Run this script manually via powershell and check if only your tagged VMs were shut down.
1) During **non-production hours**, set the configuration field `Tag` to "" and set `DoVMShutdowns` to true. Run this script manually via powershell and check if all your VMs are shut down (except vCenter and StarWind VMs).
1) During **non-production hours**, set the configuration field `DoVcenterShutdown` to `true`, run this script manually via powershell, and check if vCenter is shut down.
1) During **non-production hours**, set the configuration field `DoStarWindMaintance` field to `true`, run this script manually via powershell, and check if the StarWind devices are put into maintance mode. You will need a system with StarWind Management Console to view the status of maintance mode. Make sure all your VMs are turned off first (or will be turned off via this script).
1) During **non-production hours**, set the configuration field `DoESXiShutdowns` field to `true`, run this script manually via powershell, and check if your ESXi hosts are shut down. The StarWind appliance VMs should automatically be shut down first. Make sure all your VMs are turned off first (or will be turned off via this script).

## Production Use:
1) Set the configuration fields `DoVMShutdowns`, `DoVcenterShutdown`, `DoStarWindMaintance`, and/or `DoESXiShutdowns` fields to `true`.
1) Set the proper log file directory and set the configuration field `WriteToFile` to `true`. Make sure permissions to write to the log file directory are set properly.
1) Remove the configuration field `Tag` by setting it to "".
1) Set up a cmd file to call this powershell script.
    - This is needed because PCNS cannot call a powershell script directly.
    - In the `C:\Program Files\APC\PowerChute\user_files` directory...
    - Create a file called `powershute-vsphere-starwind-shutdown.cmd` (see example file).
    - Add this line to the file: `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe "& 'C:\Program Files\APC\PowerChute\user_files\powershute-vsphere-starwind-shutdown.ps1'"`
1) Set up a PCNS event to run this cmd file.
    - Typically "UPS On Battery".
    - Typically with a delay to handle quick "blips" in utility power.
1) Test during off-hours!

## Notes:
- You will need to run this script interactively, in a powershell window, initially to create and save the configuration file. You can edit the configuration file manually after it is created.
- The configuration file generated by this script is saved to `C:\Program Files\APC\PowerChute\user_files` as that is the directory PCNS requires command files to be located in. This script must also be located in that same directory.
- There is very little error handling in this script. It is advised to heavily test this script during non-work hours to check for errors.
- You should ensure your UPS(s) have adequate runtime to allow this script to run to completion. You should also ensure your UPS(s) are configured with the proper runtime delays, wait times, etc. Setting up the UPS NMC and PCNS properly is, simply put, a pain.
- You could run this script on an Ubuntu (or other Linux OS) since powershell is available on Linux as [powershell-core](https://github.com/PowerShell/PowerShell). However, you would not have access to the StarWind Management Console (Windows application) for diagnostics during restart of your infrastructure. Plus, getting the StarWind powershell module installed is a bit of a pain (you have to export it from a Windows machine where has already been installed).
- IPs are preferred over FQDNs since your domain controllers may be running as VMs on your primary cluster and therefore would be shut down by this script possibly causing lookup issues (i.e. looking up IP of ESXi server after all VMs are shut down).

## Currently Tested/Running Configuration:
- 2-node vSphere 7U2 (ESXi and vCenter).
- StarWind vSAN 8 running on linux VMs.
- PowerChute Network Server 4.4.1.
- Dual APC UPSes, each with NMC 3.
- Intel NUC8 (quad core, 8GB RAM, 256 SSD) as host for VM running PCNS.
- Windows Server 2016 as the host OS for PCNS.
- VMware PowerCLI 12.2.0 build 17538434 (component versions 12.3).

## Development:
- There should be no need for end users to modify the powershell script. All configuration should be handled through the configuration file.
- Documentation of the APC NMC and PCNS setup should be heavy since it is very complex.
- "Why" we are implementing something in code, or in the how-to guide, should be explained. We should explain things to people reading this code since there is a lot of complexity involved with shutting down systems properly.

## Hardening the System Running PowerChute and this Script:
- Do not join the system to a domain.
- Set a long, complex password for the default administrator user.
- Make sure Windows firewall is enabled with only the minimal ports needed for PowerChute opened.
- Make sure antivirus is working.

## Single Point of Failure:
The system running the PCNS software and this script does become a single point of failure so please take note of that in your planning. 
    - Example 1: the system could be hooked up to one of your two UPSes and that UPS has a much shorter runtime causing the script to not run to completion.
    - Example 2: the system only has one network connection and the switch the system is connected to could lose power if the UPS it is connected to dies, therefore the script would run to completion but not be able to contact vCenter, the hosts, or the StarWind VMs to perform the tasks needed.

You could potentially run redundant systems with PCNS and this script monitoring your same UPS(s) but how to handle the race condition between the two systems could become problematic (two systems issuing the same commands to vCenter, the hosts, etc). Also, you would have to handle times when one system only partially completed the shut down commands before it lost power.

## References:
- [StarWind vSAN](https://www.starwindsoftware.com/starwind-virtual-san)
- [StarWind Shutdown script](https://www.starwindsoftware.com/resource-library/starwind-virtual-san-gentle-shutdown-with-powerchute/) - Does not work (easily) due to usage of secure-string, doesn't allow for easy testing, doesn't have a ton of logging, and the script is pretty messy.
- [APC PowerChute](https://www.apc.com/shop/us/en/categories/power/uninterruptible-power-supply-ups-/ups-management/powerchute-network-shutdown/N-auzzn7)
- [APC Network Management Card User Guide](http://cdn.cnetcontent.com/c0/88/c08805e4-623b-4086-84f4-23077d7ca5b7.pdf)
- [APC PowerChute Install Guide](https://download.schneider-electric.com/files?p_File_Name=990-2838Q-EN.pdf&p_Doc_Ref=SPD_PMAR-9HBK44_EN&p_enDocType=User+guide)
- [APC PowerChute User Guide](https://download.schneider-electric.com/files?p_File_Name=990-4595H-EN-Standard.pdf&p_Doc_Ref=SPD_PMAR-9E5LVY_EN&p_enDocType=User+guide)
- https://www.stevejenkins.com/blog/2013/07/howto-configure-low-battery-duration-and-pcns-to-shut-down-with-an-apc-smartups/
