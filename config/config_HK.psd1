# Configuration used by the scripts. Copy to config.psd1 and edit values.
#
# Recommended production setup:
# - Use Windows Integrated Security for clients when possible.
# - Leave ClientName as $null if the client should auto-detect the local hostname.
# - Do not commit real passwords or SQL credentials to source control.

@{
    # SQL Server instance or hostname that the client/server scripts will connect to.
    SqlServer = 'cm01.corp.hogwart.org'

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
    AppDeployToolkitModulePath = 'E:\Github\BurnTtoast-SQLserver\Dependencies\PSAppDeployToolkit\4.1.8'

    # Enable encryption for SQL connections.
    Encrypt = $true

    # Set to $true only in lab environments or when you intentionally trust the server certificate.
    TrustServerCertificate = $true

    # Connection timeout in seconds for SQL communication.
    ConnectTimeoutSeconds = 15

    # Command timeout in seconds for SQL commands executed by the scripts.
    CommandTimeoutSeconds = 15
}
