#requires -Version 5.1
<#
.SYNOPSIS
    Schritt 12: Netzwerk der Knoten konfigurieren (SET-Switch, SMB-vNICs fuer Storage/Live Migration).
.DESCRIPTION
    Als t1-adm-hvcluster (JIT) auf dem Jump Server.
    MGMT bleibt ein eigener physischer Adapter (keine Unterbrechung der WinRM-Sitzung).
    SET1/SET2 bilden einen Switch Embedded Team; darauf zwei Host-vNICs SMB1/SMB2 ohne Gateway/DNS-Registrierung.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\ClusterConfig.psd1"
)
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile -Path $ConfigPath

foreach ($node in $cfg.Nodes) {
    if (-not $PSCmdlet.ShouldProcess($node.Name, 'SET-Switch und SMB-vNICs konfigurieren')) { continue }

    Invoke-Command -ComputerName $node.Name -ArgumentList $cfg, $node -ScriptBlock {
        param($cfg, $node)
        $ErrorActionPreference = 'Stop'

        # Lab: Adapter anhand Hyper-V Device Naming umbenennen; produktiv vorher manuell benennen
        foreach ($wanted in @($cfg.ManagementAdapter) + $cfg.SetAdapters) {
            if (Get-NetAdapter -Name $wanted -ErrorAction SilentlyContinue) { continue }
            $match = Get-NetAdapterAdvancedProperty -DisplayName 'Hyper-V Network Adapter Name' -ErrorAction SilentlyContinue |
                Where-Object DisplayValue -eq $wanted
            if (-not $match) { throw "Adapter '$wanted' auf $env:COMPUTERNAME nicht gefunden." }
            Rename-NetAdapter -Name $match.Name -NewName $wanted
        }

        if (-not (Get-VMSwitch -Name $cfg.SwitchName -ErrorAction SilentlyContinue)) {
            New-VMSwitch -Name $cfg.SwitchName -NetAdapterName $cfg.SetAdapters `
                -EnableEmbeddedTeaming $true -AllowManagementOS $false | Out-Null
        }

        $vnics = @(
            @{ Name = 'SMB1'; Ip = $node.Smb1Ip; Physical = $cfg.SetAdapters[0] }
            @{ Name = 'SMB2'; Ip = $node.Smb2Ip; Physical = $cfg.SetAdapters[1] }
        )
        foreach ($vnic in $vnics) {
            if (-not (Get-VMNetworkAdapter -ManagementOS -Name $vnic.Name -ErrorAction SilentlyContinue)) {
                Add-VMNetworkAdapter -ManagementOS -Name $vnic.Name -SwitchName $cfg.SwitchName
            }
            # Feste Zuordnung vNIC -> physischer Adapter fuer vorhersagbare SMB-Multichannel-Pfade
            Set-VMNetworkAdapterTeamMapping -ManagementOS -VMNetworkAdapterName $vnic.Name `
                -PhysicalNetAdapterName $vnic.Physical
            if ($cfg.SmbVlanId -gt 0) {
                Set-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName $vnic.Name -Access -VlanId $cfg.SmbVlanId
            }

            $alias = "vEthernet ($($vnic.Name))"
            Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Dhcp Disabled
            if (-not (Get-NetIPAddress -InterfaceAlias $alias -IPAddress $vnic.Ip -ErrorAction SilentlyContinue)) {
                New-NetIPAddress -InterfaceAlias $alias -IPAddress $vnic.Ip -PrefixLength $cfg.SmbPrefixLength | Out-Null
            }
            Set-DnsClient -InterfaceAlias $alias -RegisterThisConnectionsAddress $false

            # RDMA nur, wenn die Hardware es kann (im Nested-Lab nicht vorhanden)
            if (Get-NetAdapterRdma -Name $alias -ErrorAction SilentlyContinue) {
                Enable-NetAdapterRdma -Name $alias
            }
        }

        # SMB zwischen den Knoten (S2D/Live Migration); stabiler Regelname statt lokalisiertem Anzeigenamen
        Enable-NetFirewallRule -Name 'FPS-SMB-In-TCP'

        Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $cfg.ManagementAdapter, 'vEthernet (SMB*)' |
            Select-Object @{ n = 'Node'; e = { $env:COMPUTERNAME } }, InterfaceAlias, IPAddress, PrefixLength
    } | Select-Object Node, InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize
}
