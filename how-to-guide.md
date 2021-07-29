## Abstract:
Deploy a system completely independent from the primary vSphere cluster to handle proper shutdown in a utility power failure scenario to reduce the chances of corruption of the vSAN storage data.

## Target Audience:
System administrators who are running a StarWind vSAN cluster running vSphere. Administrators should be knowledgeable in deploying VMware ESXi, deploying a Windows VM, installing software, powershell commands, some basic networking, and configuring the battery backups.

You should want to be able to manage your primary cluster from a remote location but may not have access to the StarWind Management Console, or the StarWind IPs, outside the LAN (think, an instance where you are working from a laptop, connected via a VPN, and need to diagnose your cluster after an extended power outage and turn the cluster back on).

## Target/Required Infrastructure:
- 2-node vSphere cluster (version 7U2, ESXi and vCenter).
- StarWind vSAN running on linux VMs (version 8).
- VMware vSphere Essentials Plus licensing (3 nodes; 2 used for StarWind cluster, 1 optionally used for independent system).
- vCenter Server running as a virtual appliance within the cluster.
- Each node has dual power supplies that are connected to separate uninterruptible power supplies (UPS).
- The UPSs are made by APC and have network management cards (NMC3) installed.
- A system independent from the vSphere cluster running APC's Power Chute Network Server (PCNS).
- Network communication between the system PCNS runs on and the UPS(s) and the vSphere nodes.

## Purpose:
This guide is used for deploying a system completely independent from the primary vSphere cluster to orchestrate proper shutdown in a utility power failure scenario. Shutting down the vSphere cluster in the proper order is critical for reducing the changes of data corruption. This is even more important in a vSAN cluster since the storage itself is provided via VMs. A completely 
separate system is needed to orchestrate the shutdown since a VM running on the primary cluster will not be able to shutdown this cluster (it is running on it!).  

## How This Works:
- A Windows system (ideally Server 2016+) runs the APC PowerChute Network Server software.
- PCNS software will be used to monitor the UPSs for on-battery events and run the command script to shutdown your infrastructure correctly.
- The script will run powershell commands to connect to your vCenter server and shut down VMs (except vCenter itself and the StarWind VMs).
- After shutting down the VMs via vCenter, vCenter itself is commanded to shut down. At this point the only VMs running should be the StarWind VMs with no traffic since everything running on the storage they present is turned off.
- The script will now connect to one of the StarWind VMs via StarWind's powershell module and put the storage devices into Maintenace Mode. This will reduce the full synchronization time when your infrastructure is powered on again. We only need to enable Maintenace Mode via one VM as this will affect the storage on both VMs.
- The script will now turn off the ESXi hosts in the cluster. This will also shut down the StarWind VMs. The primary cluster is now completely and safely power off.

## Notes:
- You should have AC Power Recovery set up in the BIOS for your cluster nodes. This way when power is restored they will boot back up automatically.
- You should have AC Power Recovery set up in the BIOS for the server running the PCNS software. If this server is an ESXi host, then you should set the VM running PCNS to start up automatically.
- If you use **redundant** UPSes, note that PCNS will *not* trigger a command file to run (or the associated event) unless both UPSes encounter the same issue. This is a bit unexpected and very poorly documented in the APC documents.

## Decisions & Assumptions:
- An Intel NUC is used to run the independent system since it is relatively low cost, small and easy to fit in a server rack, and low power.
- Running Windows on the independent system is driven by two points: 
  1) Being able to run the StarWind Management Console application for diagnostics, 
  2) Providing a system to access via remote desktop from a remote location to handle restarting your infrastructure after a 
  power failure has ended (i.e.: starting up the nodes, checking status of StarWind VMs, exiting maintenance mode on the StarWind VMs, and starting up your production VMs).
- Instead of just installing Windows directly onto the NUC, ESXi is installed first with Windows running as a VM. This provides a lower-level management ability since the NUC will be deployed headless. If Windows encounters an issue, you can diagnose through ESXi.
- The independent Windows system should be as minimal as possible. It should not even be domain joined since your domain controllers may all be VMs running on the primary cluster. We just need a VM we can access remotely and manage the primary cluster from. You should still have some sort of VPN or other method preventing direct access to this VM from the WAN.

## Notes on Not Running a Linux VM:
While you could deploy an Ubuntu VM in place of Windows (you can run APC PowerChute and powershell on Ubuntu), it does not provide the ability to run the StarWind Management Console or other GUI tools to diagnose issues. If you have a separate system with a GUI to run the StarWind Management Console and interact with the ESXi and vSphere web clients you could run an Ubuntu VM. Plus, installing the StarWind powershell module on Ubuntu is a pain.

## As Tested Setup (in addition to Required Infrastructure):
- Intel NUC used as the independent system to run PCNS (quad core, 8GB RAM, 256GB SSD).
- ESXi 7U2 installer bundle zip (not the installer ISO).
- ESXi Community Network Driver.
- A Windows PC to perform the install, configuration, and management from (must have VMware PowerCLI installed).
- Rufus USB image writer or similar.
- USB key to install ESXi from (>4GB).
- USB key to install ESXi to (>16GB).
- APC networks cards wired on same network as NUC.
- Windows installer ISO (Windows 10, Server 2016, others should work fine).
- Powerchute for 64-bit systems installer (not the "for virtualization" method).

---

## Make NUC ESXi Installer ISO:
*The following instructions are performed on a Windows 10 PC.*
1) Download the ESXi 7.0.2 offline bundle zip file, not the ISO, from my.vmware.com
	- Named something like VMware-ESXi-7.0U2a-17867351-depot.zip.
2) Download the Community Network Driver. 
	- https://flings.vmware.com/community-networking-driver-for-esxi.
3) Make sure VMware PowerCLI is installed, otherwise install it. 
	- See https://vdc-repo.vmware.com/vmwb-repository/dcr-public/a63e75d6-490f-4d08-b0ca-cdc2cf155dae/451d164c-c0fd-40c1-80a0-9c2934dda006/GUID-ACD2320C-D00F-4CCE-B968-B3C41A95C085.html.
4) Place the offline bundle zip and network driver zip in the same folder.  Open powershell and navigate to that folder.
5) Run the following commands (from https://www.virten.net/2021/03/esxi-7-0-update-2-on-intel-nuc/).
	```powershell
	Add-EsxSoftwareDepot .\VMware-ESXi-7.0U2a-17867351-depot.zip
	Add-EsxSoftwareDepot .\Net-Community-Driver_1.2.0.0-1vmw.700.1.0.15843807_18028830.zip
	New-EsxImageProfile -CloneProfile "ESXi-7.0U2a-17867351-standard" -name "ESXi-7.0U2a-17867351-standard-NUC" -Vendor "anything-you-want".
	Add-EsxSoftwarePackage -ImageProfile "ESXi-7.0U2a-17867351-standard-NUC" -SoftwarePackage "net-community".
	Export-ESXImageProfile -ImageProfile "ESXi-7.0U2a-17867351-standard-NUC" -ExportToISO -filepath ESXi-7.0U2a-17867351-standard-NUC.iso.
	```
6) Using Rufus, or another USB image writing tool, write the ISO (to the smaller, less reliable, less resiliant USB key).

## Install ESXi onto NUC:
*Make sure recovery after power loss is enabled in BIOS (press F2 at boot).*
Make sure USB device is the first boot device.*

1) Get NUC hooked up to a monitor with a keyboard.
2) Plug in both USB keys.
3) Boot NUC into BIOS. 
4) Configure the BIOS:
	- Navigate through and set USB drives to boot first.
	- Navigate through and set power policy to turn on the NUC after restoring power after power failure. This way the NUC will always restart when power comes back.
6) Reboot NUC. Press F10 to view boot menu.  USB boot should be first.  Choose the USB key with the ESXi installer to boot from.
7) Install ESXi per the on-screen guide.  Make sure you install ESXi to the correct USB key!
8) Set up the management network per your network.  Record the IP address.
9) Reboot NUC to make sure it boots properly.
10) Disconnect NUC from monitor and place wherever is best.
11) Log into the ESXi web console (via the IP address you set prior).
12) Assign a license to ESXi (free one is fine although you probably have a real license from your main cluster).
13) Make sure date and time are configured properly (Manage > System > Time & date).
14) Set up networking as needed.
15) Set up datastore as needed.

## Deploy the Windows VM for running PowerChute:
1) In ESXi's web console, create a new VM.
	- Name: PowerChute.
	- Compatibility: ESXi 7.0 U2.
	- Guest OS Family: Windows
	- Guest OS Version (Ubuntu 64-bit).
	- 4 CPUs, 3GB RAM, and 75GB disk should be plenty.  Everything else can be left at defaults.
2) Mount a Windows installer ISO and perform the install.
	- If installing Server, make sure to install with a desktop.
3) Activate Windows.
4) Install VMware tools.  Reboot as needed.
5) Install Windows updates.  Reboot as needed.
6) Configure static IP for Windows.
7) Turn on remote desktop access.
8) Set correct date, time, and timezone.
9) Disable feedback (Settings > Privacy > Feedback & diagnostics).
10) Make sure the system is set to never go to sleep (Settings > System > Power & sleep).
11) (Windows Server only) Turn off IE Enhance Security for administrators (Server Manager > IE Enhanced Security Configuration).
12) Install VMware PowerCLI.
	- This is needed to connect to the vSphere infrastructure to send the shutdown commands to VMs and ESXi hosts.
	- https://vdc-repo.vmware.com/vmwb-repository/dcr-public/a63e75d6-490f-4d08-b0ca-cdc2cf155dae/451d164c-c0fd-40c1-80a0-9c2934dda006/GUID-ACD2320C-D00F-4CCE-B968-B3C41A95C085.html
	- You may need to run the following command to get PowerCLI to install: `[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12;`
	- Run the command `Connect-VIServer` upon successful install to make sure PowerCLI is installed. You should be displayed a welcome message.
13) Install the StarWind Management Console and powershell module.
	- Download the installer from StarWind. You should have been provided a link to this installer, if not, request it.
	- When shown the "Select Components" page of the installer, check StarWind Management Console and Integration Compotent Library (with child element).
	- In powershell, check if the command `New-SWServer` exists.  It must!

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
	- Set the Low Battery Duration (the amount of on-battery time remaining before triggering PowerChute to initiate a shutdown. This must be long enough to shutdown your infrastructure!
	- Set the User Name and Authentication phrase. This will be used in PowerChute for authentication.
4) Configure date and time.
	- In Configuration > General > Date/Time > Mode.
	- Set up NTP servers and enable.
5) Configure user session timeout.
	- In Configuration > Security > Local Users > Management.
	- Choose user (default is "apc").
	- Set "Session Timeout".

## Install PowerChute:
1) Download and install PowerChute.
	- Tested with version 4.4.1.
	- https://www.apc.com/shop/us/en/products/PowerChute-Network-Shutdown-v4-4-1-64-bit-systems-only-/P-SFPCNS441
	- When asked, choose Enable VMware Support.
2) PowerChute should run automatically in the Internet Explorer window.
	- If not, open a browser window to https://localhost:6547.
3) Follow the PowerChute setup.
	- When asked, do not enable for virtualization.  We will manage the VMs separately in a command/script file.
	- Choose "Redundant" for the UPS configuration.
4) Provide the IPs of your UPS NMCs.
	- Check "Accept Untrusted SSL Certificates" as needed (most likely).
	- Make sure communication is established.
5) Set up the correct outlet groups.
	- You will be able to verify the connect to the UPS in each NMC, Configuration > PowerChute Clients.
6) You can leave the default settings for each subsequent page you are displayed.  Click Finish and wait for PowerChute
   to configure successfully.
7) At this point, you should be able to access the main UI of the PowerChute tool and access it via a web browser on any
   device in your LAN (given the firewall allows port 6547).

**TODO**
- Document connecting NMC to PCNS (don't use VMware or virtualization settings!).
- Document how to set NMC battery settings (based on your battery's runtime and expected time to run script to shut everything down).
- Document PCNS settings to allow for 10 mins of runtime after on-battery event before triggering command file.