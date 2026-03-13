[DSCLocalConfigurationManager()]
configuration LCMEncryptionConfig
{
    Node "DAM-JS01"
    {
        Settings
        {
            AllowModuleOverwrite = $true
            ConfigurationMode    = "ApplyAndMonitor"

            # WICHTIG: Zertifikat für MOF-Verschlüsselung
            CertificateID        = "61a9728ddf2c75c2ebe3f25f163f8c6951341937"
        }
    }
}
LCMEncryptionConfig