# Shared template: copy to config.psd1 for clients or admin.local.psd1 for administration.
# File names do not grant permissions; use separate Windows identities and SQL roles.
#
# Recommended production setup:
# - Use Windows Integrated Security for clients when possible.
# - SYSTEM tasks authenticate to remote SQL as DOMAIN\COMPUTERNAME$.
# - Leave ClientName as $null if the client should auto-detect the local hostname.
# - Do not commit real passwords or SQL credentials to source control.
@{
    # SQL Server instance or hostname that the client/server scripts will connect to.
    SqlServer = 'SQLSERVER.example.test'

    # Database for messages and administrator-managed membership; no client delivery reporting.
    SqlDatabase = 'ToastNotifications'

    # TCP port for SQL Server access.
    SqlPort = 1433

    # Use Windows Integrated Security when the service account or user has SQL access.
    UseIntegratedSecurity = $true

    # When UseIntegratedSecurity = $false, provide a static hashtable with UserName and Password,
    # or inject a PSCredential at runtime. Keep secrets out of source control.
    SqlCredential = $null

    # Leave as $null to auto-detect the local computer name in the client script.
    # Must match the administrator-imported AD computer Name.
    ClientName = $null

    # Group membership is managed on the server with Import-ToastADComputers.ps1.

    # Local path to a packaged PSAppDeployToolkit copy used by this client.
    # Set this to a version-pinned module manifest, module file, or containing folder
    # unless Show-ADTInstallationPrompt / Show-InstallationPrompt is already loaded in the session.
    # SYSTEM requires the modern session bridge; use the bundled PSAppDeployToolkit 4.1.8.
    AppDeployToolkitModulePath = $null

    # Enable encryption for SQL connections.
    Encrypt = $true

    # Set to $true only in lab environments or when you intentionally trust the server certificate.
    TrustServerCertificate = $false

    # Connection timeout in seconds for SQL communication.
    ConnectTimeoutSeconds = 15

    # Command timeout in seconds for SQL commands executed by the scripts.
    CommandTimeoutSeconds = 15
}
