# powerchute-vsphere-starwind-shutdown README Addendum

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