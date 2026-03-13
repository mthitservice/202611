# Domainverwaltung JumpServer
Install-WindowsFeature RSAT-AD-Tools,GPMC -IncludeManagementTools
#
Import-Module ActiveDirectory
Import-Module GroupPolicy   
#
Install-Module -Name SecurityPolicyDSC -Scope AllUsers
Install-Module -Name AuditPolicyDsc -Scope AllUsers
Install-Module -Name ActiveDirectoryDSC -Scope AllUsers

# Windows Defender / ASR (per PowerShell steuern)
# (Kein separates Modul nötig, integrierte Defender-Cmdlets)
# Beispiel-Cmdlets:
# Get-MpPreference, Set-MpPreference, Add-MpPreference

# JEA Werkzeugkasten (nativ in Windows PowerShell enthalten)
# Cmdlets: New-PSSessionConfigurationFile, Register-PSSessionConfiguration
#
#git config --global user.email "you@example.com"
 # git config --global user.name "Your Name"
#