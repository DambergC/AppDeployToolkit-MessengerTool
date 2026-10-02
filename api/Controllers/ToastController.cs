using System.Data;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace ToastApi.Controllers;

public sealed class RegisterClientRequest
{
    public string? ComputerName { get; set; }
    public string[]? Groups { get; set; }
}

public sealed class RecordDeliveryRequest
{
    public long MessageId { get; set; }
    public Guid? LeaseId { get; set; }
    public string? Status { get; set; }
    public string? ErrorMessage { get; set; }
}

[ApiController]
[Route("api/Clients")]
[Produces("application/json")]
public sealed partial class ToastController : ControllerBase
{
    private const int MaxComputerNameLength = 256;
    private const int MaxGroupNameLength = 128;
    private const int MaxGroupsPerRequest = 50;
    private const int MaxErrorMessageLength = 2000;

    // Lease/status errors thrown by dbo.usp_RecordToastDelivery.
    private const int SqlErrorLeaseRequired = 50005;
    private const int SqlErrorLeaseNotFound = 50006;
    private const int SqlErrorInvalidStatus = 50007;

    private static readonly string[] AllowedStatuses = ["Delivered", "Failed", "Cancelled"];

    private const string RegisterClientSql = """
        SET NOCOUNT ON;
        SET XACT_ABORT ON;
        IF NOT EXISTS (SELECT 1 FROM dbo.ToastClient WITH (UPDLOCK, HOLDLOCK) WHERE ComputerName = @ComputerName)
            INSERT dbo.ToastClient (ComputerName) VALUES (@ComputerName);
        DECLARE @ClientId int = (SELECT ClientId FROM dbo.ToastClient WHERE ComputerName = @ComputerName);
        IF NOT EXISTS (SELECT 1 FROM dbo.ToastGroup WITH (UPDLOCK, HOLDLOCK) WHERE GroupName = @GroupName)
            INSERT dbo.ToastGroup (GroupName) VALUES (@GroupName);
        INSERT dbo.ToastClientGroup (ClientId, GroupId)
        SELECT @ClientId, g.GroupId
        FROM dbo.ToastGroup g
        WHERE g.GroupName = @GroupName
          AND NOT EXISTS (SELECT 1 FROM dbo.ToastClientGroup x WHERE x.ClientId = @ClientId AND x.GroupId = g.GroupId);
        """;

    private readonly string _connectionString;
    private readonly ToastApiOptions _options;
    private readonly ILogger<ToastController> _logger;

    public ToastController(IConfiguration configuration, IOptions<ToastApiOptions> options, ILogger<ToastController> logger)
    {
        _connectionString = configuration.GetConnectionString(ToastApiOptions.ConnectionStringName)
            ?? throw new InvalidOperationException($"Connection string '{ToastApiOptions.ConnectionStringName}' is not configured.");
        _options = options.Value;
        _logger = logger;
    }

    // GET /api/Clients/{computerName} - claims (leases) pending toast messages via dbo.usp_GetPendingToast.
    [HttpGet("{computerName}")]
    public async Task<IActionResult> GetPendingToasts(string computerName, CancellationToken cancellationToken)
    {
        var validation = ValidateComputerName(computerName) ?? AuthorizeComputer(computerName);
        if (validation is not null)
        {
            return validation;
        }

        try
        {
            await using var connection = new SqlConnection(_connectionString);
            await connection.OpenAsync(cancellationToken);
            await using var command = CreateProcedureCommand(connection, "dbo.usp_GetPendingToast");
            command.Parameters.Add("@ComputerName", SqlDbType.NVarChar, MaxComputerNameLength).Value = computerName;

            var rows = new List<Dictionary<string, object?>>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                var row = new Dictionary<string, object?>(reader.FieldCount, StringComparer.OrdinalIgnoreCase);
                for (var i = 0; i < reader.FieldCount; i++)
                {
                    row[reader.GetName(i)] = await reader.IsDBNullAsync(i, cancellationToken) ? null : reader.GetValue(i);
                }

                rows.Add(row);
            }

            if (rows.Count > 0)
            {
                _logger.LogInformation("Leased {Count} toast message(s) to {ComputerName} for {Identity}.", rows.Count, computerName, User.Identity?.Name);
            }

            return Ok(rows);
        }
        catch (SqlException ex)
        {
            return SqlFailure(ex, "claim pending toasts", computerName);
        }
    }

    // POST /api/Clients - registers a client and its group memberships. Safe to repeat.
    [HttpPost]
    public async Task<IActionResult> RegisterClient([FromBody] RegisterClientRequest? request, CancellationToken cancellationToken)
    {
        var computerName = request?.ComputerName?.Trim();
        var validation = ValidateComputerName(computerName) ?? AuthorizeComputer(computerName!);
        if (validation is not null)
        {
            return validation;
        }

        var groups = (request!.Groups ?? [])
            .Select(group => group?.Trim())
            .Where(group => !string.IsNullOrEmpty(group))
            .Select(group => group!)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (groups.Length == 0)
        {
            return ValidationError("groups", "At least one group name is required.");
        }

        if (groups.Length > MaxGroupsPerRequest)
        {
            return ValidationError("groups", $"At most {MaxGroupsPerRequest} groups can be registered per request.");
        }

        var tooLong = groups.FirstOrDefault(group => group.Length > MaxGroupNameLength);
        if (tooLong is not null)
        {
            return ValidationError("groups", $"Group name '{tooLong}' exceeds {MaxGroupNameLength} characters.");
        }

        var allowedGroups = (_options.AllowedClientGroups ?? []).Where(g => !string.IsNullOrWhiteSpace(g)).ToArray();
        if (allowedGroups.Length > 0)
        {
            var notAllowed = groups.Where(group => !allowedGroups.Contains(group, StringComparer.OrdinalIgnoreCase)).ToArray();
            if (notAllowed.Length > 0)
            {
                _logger.LogWarning("{Identity} attempted to register {ComputerName} for non-allowed group(s): {Groups}.", User.Identity?.Name, computerName, string.Join(", ", notAllowed));
                return Problem(statusCode: StatusCodes.Status403Forbidden, title: "Group registration not allowed.", detail: $"Group(s) not allowed: {string.Join(", ", notAllowed)}");
            }
        }

        try
        {
            await using var connection = new SqlConnection(_connectionString);
            await connection.OpenAsync(cancellationToken);
            await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);

            foreach (var group in groups)
            {
                await using var command = connection.CreateCommand();
                command.Transaction = transaction;
                command.CommandType = CommandType.Text;
                command.CommandText = RegisterClientSql;
                command.CommandTimeout = _options.CommandTimeoutSeconds;
                command.Parameters.Add("@ComputerName", SqlDbType.NVarChar, MaxComputerNameLength).Value = computerName;
                command.Parameters.Add("@GroupName", SqlDbType.NVarChar, MaxGroupNameLength).Value = group;
                await command.ExecuteNonQueryAsync(cancellationToken);
            }

            await transaction.CommitAsync(cancellationToken);
        }
        catch (SqlException ex)
        {
            return SqlFailure(ex, "register client", computerName!);
        }

        _logger.LogInformation("Registered {ComputerName} for group(s) {Groups} by {Identity}.", computerName, string.Join(", ", groups), User.Identity?.Name);
        return Ok(new { computerName, groups });
    }

    // PUT /api/Clients/{computerName} - records delivery status via dbo.usp_RecordToastDelivery.
    // Each lease can only be acknowledged once; repeating an already applied acknowledgement returns 409
    // instead of recording a duplicate delivery.
    [HttpPut("{computerName}")]
    public async Task<IActionResult> RecordDelivery(string computerName, [FromBody] RecordDeliveryRequest? request, CancellationToken cancellationToken)
    {
        var validation = ValidateComputerName(computerName) ?? AuthorizeComputer(computerName);
        if (validation is not null)
        {
            return validation;
        }

        if (request is null)
        {
            return ValidationError("body", "A request body is required.");
        }

        if (request.MessageId <= 0)
        {
            return ValidationError("messageId", "messageId must be a positive integer.");
        }

        if (request.LeaseId is null || request.LeaseId == Guid.Empty)
        {
            return ValidationError("leaseId", "leaseId is required.");
        }

        var status = AllowedStatuses.FirstOrDefault(s => string.Equals(s, request.Status?.Trim(), StringComparison.OrdinalIgnoreCase));
        if (status is null)
        {
            return ValidationError("status", $"status must be one of: {string.Join(", ", AllowedStatuses)}.");
        }

        var errorMessage = string.IsNullOrWhiteSpace(request.ErrorMessage) ? null : request.ErrorMessage;
        if (errorMessage is not null && errorMessage.Length > MaxErrorMessageLength)
        {
            errorMessage = errorMessage[..MaxErrorMessageLength];
        }

        try
        {
            await using var connection = new SqlConnection(_connectionString);
            await connection.OpenAsync(cancellationToken);
            await using var command = CreateProcedureCommand(connection, "dbo.usp_RecordToastDelivery");
            command.Parameters.Add("@ComputerName", SqlDbType.NVarChar, MaxComputerNameLength).Value = computerName;
            command.Parameters.Add("@MessageId", SqlDbType.BigInt).Value = request.MessageId;
            command.Parameters.Add("@Status", SqlDbType.VarChar, 20).Value = status;
            command.Parameters.Add("@ErrorMessage", SqlDbType.NVarChar, MaxErrorMessageLength).Value = (object?)errorMessage ?? DBNull.Value;
            command.Parameters.Add("@LeaseId", SqlDbType.UniqueIdentifier).Value = request.LeaseId.Value;
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (SqlException ex) when (ex.Number == SqlErrorLeaseNotFound)
        {
            _logger.LogWarning("Lease {LeaseId} for message {MessageId} on {ComputerName} is not active (already recorded or expired).", request.LeaseId, request.MessageId, computerName);
            return Problem(statusCode: StatusCodes.Status409Conflict, title: "Lease not active.", detail: ex.Message);
        }
        catch (SqlException ex) when (ex.Number is SqlErrorLeaseRequired or SqlErrorInvalidStatus)
        {
            return ValidationError("body", ex.Message);
        }
        catch (SqlException ex)
        {
            return SqlFailure(ex, "record delivery", computerName);
        }

        _logger.LogInformation("Recorded {Status} for message {MessageId} on {ComputerName} by {Identity}.", status, request.MessageId, computerName, User.Identity?.Name);
        return NoContent();
    }

    private SqlCommand CreateProcedureCommand(SqlConnection connection, string procedureName)
    {
        var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = procedureName;
        command.CommandTimeout = _options.CommandTimeoutSeconds;
        return command;
    }

    private IActionResult? ValidateComputerName(string? computerName)
    {
        if (string.IsNullOrWhiteSpace(computerName) || computerName.Length > MaxComputerNameLength || !ComputerNamePattern().IsMatch(computerName))
        {
            return ValidationError("computerName", $"computerName must be 1-{MaxComputerNameLength} characters and contain only letters, digits, '.', '-' or '_'.");
        }

        return null;
    }

    // A computer account (DOMAIN\PC001$) may only act for its own computer name. User identities may act for
    // any computer name unless RequireComputerAccountMatch is enabled.
    private IActionResult? AuthorizeComputer(string computerName)
    {
        var identityName = User.Identity?.Name ?? string.Empty;
        var accountName = identityName.Contains('\\') ? identityName[(identityName.LastIndexOf('\\') + 1)..] : identityName;
        var isComputerAccount = accountName.EndsWith('$');

        if (!isComputerAccount && !_options.RequireComputerAccountMatch)
        {
            return null;
        }

        var hostLabel = computerName.Split('.')[0];
        if (isComputerAccount && string.Equals(accountName[..^1], hostLabel, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        _logger.LogWarning("{Identity} is not allowed to act for computer {ComputerName}.", identityName, computerName);
        return Problem(statusCode: StatusCodes.Status403Forbidden, title: "Identity does not match computer name.");
    }

    private IActionResult SqlFailure(SqlException ex, string operation, string computerName)
    {
        _logger.LogError(ex, "SQL error {Number} while trying to {Operation} for {ComputerName}.", ex.Number, operation, computerName);
        // Treat database errors as transient so clients can retry; details stay in the server log.
        return Problem(statusCode: StatusCodes.Status503ServiceUnavailable, title: "Database temporarily unavailable.");
    }

    private BadRequestObjectResult ValidationError(string field, string message)
    {
        var details = new ValidationProblemDetails(new Dictionary<string, string[]> { [field] = [message] })
        {
            Status = StatusCodes.Status400BadRequest,
        };
        return BadRequest(details);
    }

    [GeneratedRegex("^[A-Za-z0-9][A-Za-z0-9._-]*$", RegexOptions.CultureInvariant)]
    private static partial Regex ComputerNamePattern();
}
