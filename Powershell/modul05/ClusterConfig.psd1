# Zentrale Lab-Parameter fuer Tag 5 (Hyper-V-Failover-Cluster mit S2D, JIT-Administration).
# Alle Skripte in modul05 lesen diese Datei; Namen/IPs nur hier anpassen.
@{
    # Active Directory
    DomainFqdn           = 'secureops.local'
    DomainNetbios        = 'SECUREOPS'
    DomainController     = 'SRV-DC01.secureops.local'
    Tier1ServersOu       = 'OU=Servers,OU=Tier 1,DC=secureops,DC=local'
    ClusterOuName        = 'HV-Cluster'
    AccountsOu           = 'OU=Accounts,OU=Tier 1,DC=secureops,DC=local'
    GroupsOu             = 'OU=Groups,OU=Tier 1,DC=secureops,DC=local'

    # AGDLP: Konto (TTL) -> Global JIT-Gruppe -> Domain Local -> lokale Admins + CNO-Vollzugriff
    JitGroup             = 'T1-HVCluster-Admins-JIT'
    LocalAdminGroup      = 'DL-HVCluster-LocalAdmins'
    ApproverGroup        = 'T1-JIT-Approvers'
    JumpServerUsersGroup = 'T1-JumpServer-Users'
    ClusterAdminAccount  = 't1-adm-hvcluster'
    DefaultJitHours      = 4
    MaxJitHours          = 8

    # Cluster
    ClusterName          = 'SRV-HVCL01'
    ClusterIp            = '10.0.0.60'
    Nodes                = @(
        @{ Name = 'SRV-HV01'; Smb1Ip = '10.10.1.61'; Smb2Ip = '10.10.2.61' }
        @{ Name = 'SRV-HV02'; Smb1Ip = '10.10.1.62'; Smb2Ip = '10.10.2.62' }
    )

    # Netzwerk: MGMT bleibt getrennt, SET1/SET2 bilden den Switch Embedded Team
    ManagementAdapter    = 'MGMT'
    SetAdapters          = @('SET1', 'SET2')
    SwitchName           = 'SETswitch'
    SmbPrefixLength      = 24
    SmbVlanId            = 0   # 0 = ungetaggt (Lab); produktiv eigenes Storage-VLAN
    # Rollen: 0 = None, 1 = Cluster (nur Cluster/Storage), 3 = ClusterAndClient
    ClusterNetworks      = @(
        @{ Name = 'Management'; Address = '10.0.0.0'; Role = 3 }
        @{ Name = 'SMB1'; Address = '10.10.1.0'; Role = 1 }
        @{ Name = 'SMB2'; Address = '10.10.2.0'; Role = 1 }
    )

    # Quorum (File Share Witness auf separatem Tier-1-Fileserver)
    WitnessServer        = 'SRV-FILE01'
    WitnessShare         = 'HVCL01-Witness$'
    WitnessPath          = 'D:\ClusterWitness\SRV-HVCL01'

    # Storage Spaces Direct
    PoolName             = 'S2D on SRV-HVCL01'
    Volumes              = @(
        @{ Name = 'CSV01'; SizeGB = 100 }
        @{ Name = 'CSV02'; SizeGB = 100 }
    )

    # Funktionstest
    TestVmName           = 'VM-TEST01'
    TestVmVolume         = 'CSV01'
}
