New-ADOrganizationalUnit -Name "Damago-Test" -Path "DC=DAMAGO,DC=local"

New-ADUser -Name "Hans.Gast" -DisplayName "Hans Gast" -City "Dresden" -Path "ou=Damago-Test,DC=DAMAGO,DC=local"
New-ADObject -Name "Sandra.Gast" -DisplayName "Sandra Gast" -type User  -Path "ou=Damago-Test,DC=DAMAGO,DC=local"