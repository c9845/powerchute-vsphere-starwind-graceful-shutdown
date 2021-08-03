## Abstract:
Deploy a system completely independent from the primary vSphere cluster to handle proper shutdown in a utility power failure scenario to reduce the chances of corruption of the vSAN storage data.

## Target Audience:
System administrators who are running a StarWind vSAN cluster and vSphere. Administrators should be knowledgeable in deploying VMware ESXi, deploying a Windows VM, installing software, powershell commands, some basic networking, and configuring the UPS(s).

## Tasks in this Guide:
1) Build an ESXi installer for installing ESXi on an Intel NUC.
1) Install ESXi onto the NUC.
1) Deploy a Windows VM for running PCNS.
1) Set up the APC UPS NMC(s).
1) Install PowerChute Network Server (PCNS).
1) Set up the powershell script.
1) Testing.
1) Run in Production.

## Target/Required Infrastructure:
- 2-node vSphere cluster running StarWind vSAN.
	- vSphere 7U2 (ESXi and vCenter).
	- vSphere Essentials Plus licensing.
	- StarWind vSAN 8.
- APC UPS(s) with NMC(s) installed.
	- This guide assume dual UPSes, each powering both nodes through two power supplies in each node.
- An Intel NUC to use as the independent system for running APC's PowerChute Network Server (PCNS).
- Network communication between the system PCNS runs on, the UPS(s), and the vSphere nodes.
- A Windows Server installer ISO and license.
	- Server 2016 with Desktop.
- The StarWind Management Console installer to install the powershell module.

## Purpose:
This guide is used for deploying a system completely independent from the primary vSphere cluster to orchestrate proper shutdown in a utility power failure scenario. Shutting down the vSphere cluster in the proper order is critical for reducing the chances of data corruption on the vSAN. An independent system (from the vSphere cluster) is needed to orchestrate the shutdown since a VM running on the primary cluster will not be able to shutdown this cluster (it itself is running on it!).  

## How This Works:
- A Windows system runs the APC PowerChute Network Server software.
- PCNS software will be used to monitor the UPSs for on-battery events and run the script to shutdown your infrastructure correctly.
- The script will connect to your vCenter server and shut down VMs (except vCenter itself and the StarWind VMs).
- After shutting down the VMs via vCenter, vCenter itself is commanded to shut down. At this point the only VMs running should be the StarWind VMs with no traffic since everything running on the storage they present is turned off.
- The script will now connect to one of the StarWind VMs via StarWind's powershell module and put the storage devices into Maintenace Mode. This will reduce the full synchronization time when your infrastructure is powered on again. We only need to enable Maintenace Mode via one VM as this will affect the storage on both VMs.
- The script will then turn off the ESXi hosts in the cluster. This will also shut down the StarWind VMs.

## Notes:
- You should have AC Power Recovery set up in the BIOS for your cluster nodes. This way when power is restored they will boot back up automatically.
- You should have AC Power Recovery set up in the BIOS for the system running the PCNS software. If this server is an ESXi host, then you should set the VM running PCNS to start up automatically.
- If you use **redundant** UPSes, note that PCNS will *not* trigger a command file to run unless both UPSes encounter the same issue. This is a bit unexpected and very poorly documented in the APC documents.

## Decisions, Assumptions, Misc.:
- An Intel NUC is used to run the independent system since it is relatively low cost, low power, and easy to fit in a server rack.
- Running Windows on the independent system is driven by two points:
  - Being able to run the StarWind Management Console application for diagnostics.
  - Providing a system to access via remote desktop from a remote location to handle restarting your infrastructure after a 
  power failure has ended (i.e.: starting up the nodes, checking status of StarWind VMs, exiting maintenance mode on the StarWind VMs, and starting up your production VMs).
- ESXi is installed on the NUC with Windows running as a VM, instead of just installing Windows on the NUC, to provide a lower-level management tool since the NUC is designed to be deployed headless. If Windows encounters an issue you can diagnose it through ESXi.
- The independent Windows system should be as minimal as possible. It should not even be domain joined since your domain controllers may all be VMs running on the primary cluster. We just need a VM we can access remotely and manage the primary cluster from. You should still have some sort of VPN or other method preventing direct access to this VM from the WAN.

## Notes on Running a Linux VM:
While you could deploy an Ubuntu VM in place of Windows (you can run APC PowerChute and powershell on Ubuntu), it does not provide the ability to run the StarWind Management Console or other GUI tools to diagnose issues. If you have a separate system with the StarWind Management Console installed you could run PCNS and this script on an Ubuntu VM.

## Miscellaneous Setup Notes:
- Intel NUC (quad core, 8GB RAM, 256GB SSD).
- ESXi 7U2 installer bundle zip (not the installer ISO).
- ESXi Community Network Driver.
- A Windows PC to perform the install, configuration, and management from (must have VMware PowerCLI installed).
- Rufus USB image writer or similar.
- USB key to install ESXi from (>4GB).
- USB key to install ESXi to (>16GB).
- APC networks cards wired on same network as NUC.
- Windows installer ISO (Server 2016, others should work fine).
- Powerchute for 64-bit systems installer (not the "for virtualization" version).

---

## Make NUC ESXi Installer ISO:
*The following instructions are performed on a Windows 10 PC.*
1) Download the ESXi 7.0.2 offline bundle zip file, not the ISO.
	- From my.vmware.com.
	- Named something like `VMware-ESXi-7.0U2a-17867351-depot.zip`.
1) Download the Community Network Driver. 
	- https://flings.vmware.com/community-networking-driver-for-esxi.
	- This is needed since ESXi does not contain the ethernet driver for the NUC.
1) Make sure VMware PowerCLI is installed, otherwise install it. 
	- See https://vdc-repo.vmware.com/vmwb-repository/dcr-public/a63e75d6-490f-4d08-b0ca-cdc2cf155dae/451d164c-c0fd-40c1-80a0-9c2934dda006/GUID-ACD2320C-D00F-4CCE-B968-B3C41A95C085.html.
	- So we can build an ESXi installer ISO from the offline bundle and community network driver.
1) Place the offline bundle zip and network driver zip in the same folder.
1) Open powershell and navigate to the folder where the bundle and network zip files are located.
1) Run the following commands (from https://www.virten.net/2021/03/esxi-7-0-update-2-on-intel-nuc/).
	```powershell
	Add-EsxSoftwareDepot .\VMware-ESXi-7.0U2a-17867351-depot.zip
	Add-EsxSoftwareDepot .\Net-Community-Driver_1.2.0.0-1vmw.700.1.0.15843807_18028830.zip
	New-EsxImageProfile -CloneProfile "ESXi-7.0U2a-17867351-standard" -name "ESXi-7.0U2a-17867351-standard-NUC" -Vendor "anything-you-want".
	Add-EsxSoftwarePackage -ImageProfile "ESXi-7.0U2a-17867351-standard-NUC" -SoftwarePackage "net-community".
	Export-ESXImageProfile -ImageProfile "ESXi-7.0U2a-17867351-standard-NUC" -ExportToISO -filepath ESXi-7.0U2a-17867351-standard-NUC.iso.
	```
1) Using Rufus, or another USB image writing tool, write the ISO to the smaller USB key.

## Install ESXi onto NUC:
*Make sure recovery after power loss is enabled in BIOS (press F2 at boot).*

*Make sure USB device is the first boot device.*

1) Connect the NUC to a monitor, keyboard, network, and power.
1) Plug both USB keys into the NUC.
1) Boot NUC into BIOS.
	- Press `F2` during boot.
1) Configure the BIOS:
	- Set USB drives to boot first.
	- Set the power policy to turn on the NUC after power is restored. This way the NUC will always restart when power comes back.
1) Reboot the NUC and verify USB is the first boot device. 
	- Press `F10` during boot to view boot menu.
	- USB boot should be first.
1) Boot the USB key with the ESXi installer.
1) Install ESXi per the on-screen guide. 
	- Make sure you install ESXi on the correct USB key!
1) Once ESXi is installed, the system should reboot and successfully boot into ESXi. 
	- At this point you can remove the ESXi installer UBS key.
1) Set up the management network per your network. Record the IP address.
1) Reboot the NUC to make sure it boots properly and the management is set correctly.
1) Shutdown the NUC and move it to its final location.
	- Connect it back to network and power.
	- Make sure it is hooked up to a UPS itself so that when the power goes out it can still run PCNS and the shutdown script!
1) Log into the ESXi web console via the IP address you set prior.
1) Assign a license to ESXi.
1) Make sure date and time are configured properly (Manage > System > Time & date).
1) Set up networking as needed (you shouldn't have to do anything in most cases).
1) Set up datastore as needed (the SSD installed in the NUC, so you have a place to run VMs from).

## Deploy the Windows VM for running PowerChute:
1) In ESXi's web console, create a new VM.
	- Name: PowerChute.
	- Compatibility: ESXi 7.0 U2.
	- Guest OS Family: Windows
	- Guest OS Version (Windows Server 2016).
	- 4 CPUs, 4GB RAM, and 75GB disk should be plenty.
	- Everything else can be left at defaults.
1) Mount a Windows installer ISO and perform the install.
	- If installing Server, make sure to install with a desktop.
1) Activate Windows.
1) Install VMware tools. Reboot as needed.
1) Install Windows updates. Reboot as needed.
	- You may need to perform the update and reboot cycle numerous times.
1) Configure static IP for Windows.
1) Turn on remote desktop access.
1) Set correct date, time, and timezone.
1) Disable feedback (Settings > Privacy > Feedback & diagnostics).
1) Make sure the system is set to never go to sleep (Settings > System > Power & sleep).
1) Turn off IE Enhance Security for administrators (Server Manager > IE Enhanced Security Configuration).
	- Windows Server only.
1) Install VMware PowerCLI.
	- This is needed to connect to the vSphere infrastructure to send the shutdown commands to VMs and ESXi hosts.
	- https://vdc-repo.vmware.com/vmwb-repository/dcr-public/a63e75d6-490f-4d08-b0ca-cdc2cf155dae/451d164c-c0fd-40c1-80a0-9c2934dda006/GUID-ACD2320C-D00F-4CCE-B968-B3C41A95C085.html
	- You may need to run the following command to get PowerCLI to install: `[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12;`
	- Run the command `Connect-VIServer` upon successful install to make sure PowerCLI is installed. You should be displayed a welcome message.
13) Install the StarWind Management Console and powershell module.
	- Download the installer from StarWind. You should have been provided a link to this installer, if not, request it.
	- When shown the "Select Components" page of the installer, check StarWind Management Console and Integration Component Library (with child element).
	- In powershell, run the command `New-SWServer`. You should not get an error message.

## Setup APC NMCs:
*We assume the NMCs are already installed in each UPS and connected to your LAN and IPs set.*

*The following steps are repeated on each NMC.*

1) Open a web browser to each NMC.
2) Configure alerts via emails.
	- In Configuration > Notifiation > Email > Server, provide your email server settings.
	- In Configuration > Notifiation > Email > Recipients, create the email addresses that should receive email alerts.
	- In Configuration > Notifiation > Email > Test, run a test and make sure the emails are received successfully.
3) Configure shutdown.
	- In Configuration > Shutdown.
	- Set the Low Battery Duration (the amount of on-battery time remaining before triggering PowerChute to initiate a shutdown. This must be long enough to shutdown your infrastructure (aka run this script)!
	- Set the User Name and Authentication phrase. These will be used in PowerChute for authentication.
4) Configure date and time.
	- In Configuration > General > Date/Time > Mode.
	- Set up NTP servers and enable NTP.
5) Configure user session timeout.
	- In Configuration > Security > Local Users > Management.
	- Choose user (default is "apc").
	- Set "Session Timeout" to something a bit longer so we don't need to log in as often when performing diagnostics.

## Install PowerChute:
1) Download and install PowerChute.
	- Tested with version 4.4.1.
	- https://www.apc.com/shop/us/en/products/PowerChute-Network-Shutdown-v4-4-1-64-bit-systems-only-/P-SFPCNS441
	- When prompted, allow firewall rules to be created.
2) PowerChute should run automatically and open anInternet Explorer window.
	- If not, open a browser window to https://localhost:6547.
3) Follow the PowerChute setup.
	- When asked, *do not* enable for virtualization/VMware support. We will manage the virtual infrastructure separately in the script run as a PCNS command file.
	- Choose "Redundant" for the UPS configuration (if you have the same setup as this guide targets).
4) Provide the IPs of your UPS NMCs.
	- Check "Accept Untrusted SSL Certificates" as needed (most likely).
	- Make sure communication is established.
5) Set up the correct outlet groups.
	- View the power ports on your UPSes.
6) You can leave the default settings for each subsequent page you are displayed. Click Finish and wait for PowerChute to configure successfully.
7) At this point, you should be able to access the main UI of the PowerChute tool and access it via a web browser on any device in your LAN (given the firewall allows port 6547).

## Setup the Script:
1) On the system that runs PCNS, open file explorer and navigate to `C:\Program Files\APC\PowerChute\user_files`.
1) Copy the `powerchute-vsphere-starwind-shutdown.cmd` and `powerchute-vsphere-starwind-shutdown.ps1` files to this directory.
1) Gather some information needed for configuring the `powerchute-vsphere-starwind-shutdown.ps1` script.
	- vCenter IP.
	- Your vCenter VM name.
	- Your vCenter cluter and datacenter.
	- ESXi IPs.
	- One StarWind VM IP.
	- Your StarWind VM names.
	- Email server hostname and SMTP port.
1) Create a minimal vCenter user.
	- So that you don't store a more highly powered user's credentials in the configuration.
	- Create a user (ex.: "apc-shutdown").
	- Create the role and assign permissions.
		- Host > Inventory > Modify Cluster (to disable vSphere High Availability).
		- Virtual Machine > Interaction > Power off (to shut down VMs).
	- Assign the role to a user by right clicking the vCenter in the "Hosts & Virtual Machines" inventory.
1) Create a minimal ESXi user.
	- So that you don't store a more highly powered user's credentials in the configuration.
	- You must do this on both ESXi hosts and the username and password must be the same.
	- Permissions:
		- System > Anonymous, System > View, System > Read (basic permissions).
		- Host > Config > Power (to shut down host).
		- VirtualMachine > Interact > PowerOff (to shut down VMs).
1) Open a powershell window and navigate to the `C:\Program Files\APC\PowerChute\user_files` directory.
1) Run the `powerchute-vsphere-starwind-shutdown.ps1` script and follow the prompts to save your configuration.
	- Set all the `Do...` fields to "n" for testing purposes.
	- When prompted to saves logs to a file, provide "n". This is just for testing.
1) You should now have a `powerchute-vsphere-starwind-shutdown.config` file located in the same directory.
	- This is the configuration file.
	- You can edit this file as needed manually, but be sure to test any changes since there is very little validation in the script.
1) Inspect the `powerchute-vsphere-starwind-shutdown.config` file to make sure your settings were saved properly.
1) In the powershell window, run the `powerchute-vsphere-starwind-shutdown.ps1` script and watch the logging output.
	- This will test the credentials and IPs you provided.
	- Monitor the logging output (it should be written out, not to a file).
	- There should be no errors. If there are, correct them.
	- All VMs should have been targeted but none should have been shut down.
	- vCenter and ESXi should not have been shut down either.
	- StarWind VMs should not have been shut down and devices should not have been put in maintance mode.

## Testing:
*You should test this script manually by running it in powershell with logging turned off, so it is output to the powershell window, so that you can verify the script works as intended without getting PCNS involved. Plus, you will be able to test quicker without having to worry about PCNS events needing to be trigged.*

1) Test this script many times using the `Do...` configuration file fields set to `false` initially and then setting them to `true` one by one. See the README for more info. 
1) Test the script via PCNS.
	- Edit the `powerchute-vsphere-starwind-shutdown.config` file setting the `WriteToFile` field to `true`.
		- Make sure a valid directory is provided for the field `PathToDirectory`.
	- Edit the `powerchute-vsphere-starwind-shutdown.config` file setting the `Do...` fields to `false`.
		- Enable each field one-by-one ensuring each works as expected first.
		- Make sure you are enabling these fields and testing during off-hours!
	- Open a browser and navigate to the PCNS port (https://localhost:6547 from the independent system).
	- Navigate to "Configure Events".
	- Choose an easy to test event, such as "PowerChute cannot communicate with the NMC" and click the gear under "Command File".
		- We use this event, instead of the "On Battery" event because it is easier to test and doesn't stress the battery.
	- Check the "Enable Command File" checkbox.
	- Provide the path the cmd file.
		- Should be `C:\Program Files\APC\PowerChute\user_files\powerchute-vsphere-starwind-shutdown.cmd`).
		- Note that double quotes are not needed.
		- The PowerChute UI will show an error if the file path provided does not exist.
		- Click Apply.
	- Cause the event to occur.
		- For the "PowerChute cannot communicate with the NMC", pull the ethernet cables from the NMC or disable the associated ports on your switch.
		- In PCNS, navigate to "View Event Log".
		- You may need to wait some time for PCNS to recognize the event.
		- Once the PCNS recognizes the event from *both* UPSes, the command file will be run.
		- If you have email alerts set up in the script configuration, you should receive an email when the event occurs and the script runs.
		- If the script does not run, check the logs in `"C:\Program Files\APC\PowerChute\group1\cmdfile.log"`.
		- If the script does run, check the logs in the directory your provided in the configuration file.

## Deploying the Script in Production:
*This guide assumes certain timings and settings based on the test environment, you will have to adjust your settings based on your UPS runtime, the time it takes for your VMs and ESXi hosts to shut down, the amount of time you want your systems to run prior to commencing shutdown, and other details.*

*The list of settings on the APC NMC and PCNS regarding shutdown is very confusing. Unhelpfully, the documents for both are also confusing. A lot of the settings are based on trial and error.*

*Our goal is to allow the infrastructure to remain running on battery for 10 minutes, then initate the shutdown proceedure. 10 minutes was determined based on historical experience; either the power goes out and comes back quickly or the power goes out and is out for hours.*

*It is a good idea to test this script during off-hours in a "production setting" to verify it works as expected. By this, we mean, set up the script to run on the "UPS On Battery" event as noted below and then literally pull the UPSes power supply cable from the wall forcing it to run on battery. Watch your PCNS logs, script logs, vCenter tasks, and ESXi tasks for events*.

1) Navigate to `C:\Program Files\APC\PowerChute\user_files` and open the `powerchute-vsphere-starwind-shutdown.config` file for editing. 
1) Set the configuration fields `DoVMShutdowns`, `DoVcenterShutdown`, `DoStarWindMaintance`, and/or `DoESXiShutdowns` fields to `true`.
1) Set the configuration field `Tag` to "" and make sure any related tags are removed from your VMs.
1) Set the configuration field `WriteToFile` to `true` to enable writing logging to a file.
1) Connect to the PCNS web application.
1) Navigate to "Configure Events".
1) For the "UPS on Battery" event, click the gears.
1) Check teh "Enable Command File" checkbox.
1) Set the Delay to 600 (to 10 minutes of runtime before initiating shut down).
1) Provide the path the cmd file.
	- Should be `C:\Program Files\APC\PowerChute\user_files\powerchute-vsphere-starwind-shutdown.cmd`).
	- Note that double quotes are not needed.
	- The PowerChute UI will show an error if the file path provided does not exist.
	- Click Apply.
1) Done! The script should now run after the UPS has been running on battery for 10 minutes causing the VMs and hosts to shut down.

---

# TODO
- Document NMC settings and why we have them set as they are. The battery runtime settings, max delay, etc. Although we don't really use these.