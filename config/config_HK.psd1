# Configuration used by the scripts. Copy to config.psd1 and edit values.
#
# Recommended production setup:
# - Use Windows Integrated Security for clients when possible.
# - Leave ClientName as $null if the client should auto-detect the local hostname.
# - Use InternalPowerShellRepository for approved BurntToast package source in production.
# - Do not commit real passwords or SQL credentials to source control.

@{
    # SQL Server instance or hostname that the client/server scripts will connect to.
    SqlServer = 'cm01.corp.hogwart.org'

    # Database name used by the project for queue, status, and delivery tracking.
    SqlDatabase = 'ToastNotifications'

    # TCP port for SQL Server access.
    SqlPort = 1433

    # Use Windows Integrated Security when the service account or user has SQL access.
    UseIntegratedSecurity = $true

    # When UseIntegratedSecurity = $false, provide a static hashtable with UserName and Password,
    # or inject a PSCredential at runtime. Keep secrets out of source control.
    SqlCredential = $null

    # Leave as $null to auto-detect the local computer name in the client script.
    # Set a specific value only when a fixed client name is required for registration/reporting.
    ClientName = $null

    # One or more group names a client should register for and listen to.
    ClientGroups = @('HK')

    # Optional internal PowerShell repository used to install BurntToast in production.
    # Leave as $null if BurntToast is already installed or managed by another process.
    InternalPowerShellRepository = $null

    # Optional local path to a packaged PSAppDeployToolkit copy used by DisplayMode AppDeployToolkit.
    # Point to a version-pinned module manifest, module file, or containing folder.
    # Leave as $null if AppDeployToolkit mode is not used on this client.
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
