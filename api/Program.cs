using Microsoft.AspNetCore.Authentication.Negotiate;
using Microsoft.AspNetCore.Authorization;
using ToastApi;

var builder = WebApplication.CreateBuilder(args);

builder.Logging.ClearProviders();
builder.Logging.AddConfiguration(builder.Configuration.GetSection("Logging"));
builder.Logging.AddConsole();
builder.Logging.AddDebug();
if (OperatingSystem.IsWindows())
{
    builder.Logging.AddEventLog();
}

if (string.IsNullOrWhiteSpace(builder.Configuration.GetConnectionString(ToastApiOptions.ConnectionStringName)))
{
    throw new InvalidOperationException($"Connection string '{ToastApiOptions.ConnectionStringName}' must be configured.");
}

builder.Services.Configure<ToastApiOptions>(builder.Configuration.GetSection(ToastApiOptions.SectionName));

// Windows Authentication. When hosted in IIS the Negotiate handler defers to IIS Windows Authentication;
// with Kestrel/HTTP.sys it performs Kerberos/NTLM itself.
builder.Services
    .AddAuthentication(NegotiateDefaults.AuthenticationScheme)
    .AddNegotiate();

var allowedRoles = builder.Configuration.GetSection($"{ToastApiOptions.SectionName}:AllowedRoles").Get<string[]>()
    ?.Where(role => !string.IsNullOrWhiteSpace(role))
    .ToArray() ?? [];

builder.Services.AddAuthorization(options =>
{
    var policy = new AuthorizationPolicyBuilder(NegotiateDefaults.AuthenticationScheme).RequireAuthenticatedUser();
    if (allowedRoles.Length > 0)
    {
        policy.RequireRole(allowedRoles);
    }

    // Every endpoint requires an authenticated (and optionally role-restricted) Windows identity.
    options.FallbackPolicy = policy.Build();
});

builder.Services.AddControllers();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();

app.Run();

namespace ToastApi
{
    public sealed class ToastApiOptions
    {
        public const string SectionName = "ToastApi";
        public const string ConnectionStringName = "ToastDatabase";

        // SQL command timeout used for all stored procedure calls.
        public int CommandTimeoutSeconds { get; set; } = 15;

        // Windows groups allowed to call the API. Empty means any authenticated Windows identity.
        public string[] AllowedRoles { get; set; } = [];

        // Group names clients are allowed to register for. Empty means any group name.
        public string[] AllowedClientGroups { get; set; } = [];

        // When true, only the computer account (DOMAIN\NAME$) matching {computerName} may call the API.
        // When false, computer accounts must still match, but user identities may act for any computer name.
        public bool RequireComputerAccountMatch { get; set; }
    }
}
