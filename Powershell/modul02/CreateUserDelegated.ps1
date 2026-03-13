Configuration CreateUserDelegated
{
    param(
        [string]$DomainController = "dam-dc01.damago.local",
        [string]$TargetOu = "OU=Damago-Test,DC=damago,DC=local"
     #   [pscredential]$RunAsCredential
        
   
    )

    Import-DscResource -ModuleName ActiveDirectoryDsc

    Node "DAM-DC01"
    {
        ADUser NewTestUser
        {
            DomainController = $DomainController
            DomainName       = "damago.local"
            UserName         = "TestUser01"
            GivenName        = "Test"
            Surname          = "User"
            DisplayName      = "Test User"
            Path             = $TargetOu
            Enabled          = $false
            
          

         #   PsDscRunAsCredential =$RunAsCredential
        }
    }
}



CreateUserDelegated
#Start-DscConfiguration -Path .\CreateUserDelegated -Wait -Verbose -Force
