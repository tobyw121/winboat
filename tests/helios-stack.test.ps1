$ErrorActionPreference='Stop'
. "$PSScriptRoot/../guest_server/scripts/Compare-HeliosStack.ps1"
$c=@([pscustomobject]@{PNPDeviceID='PCI\VEN_1AF4&DEV_1050';DriverVersion='22.22.291.0'})
$a=[pscustomobject]@{apiRegistration=@([pscustomobject]@{name='VulkanDriverName';values=@('C:\Program Files\Helios\helios-windows-x64-22.22.294.0-rev\runtime\mesa\helios_vulkan.json')});loadedApplications=@()}
if((Compare-HeliosStack $c $a).state -ne 'mismatch'){throw 'Mixed active versions missed'}
$a.apiRegistration[0].values=@('C:\Program Files\Helios\helios-windows-x64-22.22.291.0-rev\runtime\mesa\helios_vulkan.json')
if((Compare-HeliosStack $c $a).state -ne 'coherent-observed'){throw 'Coherent paths rejected'}
$a.apiRegistration=@()
if((Compare-HeliosStack $c $a).state -ne 'unknown'){throw 'Absent registration is not success'}
'Stack coherence tests passed.'
