# Configuration used by src/Client/Start-ToastClient-API.ps1. Copy to config.psd1 and edit values.
#
# The API client talks to the ToastApi webservice over HTTPS (TCP 443) instead of connecting
# directly to SQL Server on TCP 1433. Only the webserver needs network access to SQL Server.
#
# Authentication uses the current Windows identity (Invoke-RestMethod -UseDefaultCredentials).
# No SQL or API credentials are stored on the client.
@{
    # Base URL of the ToastApi webservice, including the /api path. Must use https.
    ApiUri = 'https://messenger.example.test/api'

    # Leave as $null to auto-detect the local computer name in the client script.
    # Set a specific value only when a fixed client name is required for registration/reporting.
    ClientName = $null

    # One or more group names a client should register for and listen to.
    ClientGroups = @('IT-TEST')

    # Local path to a packaged PSAppDeployToolkit copy used by this client.
    # Set this to a version-pinned module manifest, module file, or containing folder
    # unless Show-ADTInstallationPrompt / Show-InstallationPrompt is already loaded in the session.
    AppDeployToolkitModulePath = $null

    # Timeout in seconds for each HTTP request to the webservice.
    RequestTimeoutSeconds = 30

    # Number of extra attempts for transient errors (network failures, timeouts, HTTP 408/429/500/502/503/504).
    MaxRetryCount = 3

    # Delay in seconds before the first retry. The delay doubles for each following retry.
    RetryDelaySeconds = 2
}
