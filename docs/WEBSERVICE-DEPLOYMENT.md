# Driftsättning av webservicen (ToastApi)

`api/` innehåller ett litet ASP.NET Core Web API som ligger mellan klienterna och SQL Server. Klienterna pratar HTTPS (TCP 443) med webservicen, och bara webbservern ansluter till SQL Server (TCP 1433). Mönstret är inspirerat av webservicen i ConfigMgr Client Health.

```
Windows-klient ──HTTPS/443──► IIS (ToastApi) ──TCP 1433──► SQL Server
```

## Endpoints

Alla endpoints kräver en autentiserad Windows-identitet (Negotiate/Kerberos/NTLM).

| Metod | URL | Funktion |
|---|---|---|
| `GET` | `/api/Clients/{computerName}` | Anropar `dbo.usp_GetPendingToast`, leasar och returnerar väntande meddelanden som JSON |
| `POST` | `/api/Clients` | Registrerar klienten och dess grupper i `dbo.ToastClient`, `dbo.ToastGroup` och `dbo.ToastClientGroup` |
| `PUT` | `/api/Clients/{computerName}` | Kvitterar leverans via `dbo.usp_RecordToastDelivery` |

Exempel på request bodies:

```json
POST /api/Clients
{ "computerName": "PC001", "groups": ["IT-TEST", "SALES"] }

PUT /api/Clients/PC001
{ "messageId": 123, "leaseId": "6f9619ff-8b86-d011-b42d-00c04fc964ff", "status": "Delivered", "errorMessage": null }
```

Svarskoder:

| Kod | Betydelse |
|---|---|
| `200` / `204` | OK |
| `400` | Ogiltig indata (datornamn, grupper, `status`, `leaseId` m.m.) |
| `401` | Ingen Windows-autentisering |
| `403` | Identiteten får inte agera för datorn/gruppen (se *Behörighet*) |
| `409` | Leasen är inte längre aktiv – kvittensen är redan registrerad eller leasen har gått ut |
| `503` | Databasfel; klienten gör retry |

### Idempotens

- `POST /api/Clients` kan upprepas; befintliga klienter, grupper och medlemskap skapas inte igen.
- `PUT /api/Clients/{computerName}` registrerar aldrig samma lease två gånger. En lease är engångs: en upprepad kvittens returnerar `409` i stället för att räkna upp `ShowCount` en gång till. API-klienten tolkar `409` efter ett transient fel (t.ex. timeout där första försöket faktiskt nådde servern) som "redan registrerad".
- `GET /api/Clients/{computerName}` leasar meddelanden (samma som `dbo.usp_GetPendingToast`). Leasar som aldrig kvitteras går ut efter 120 sekunder och plockas upp igen.

## Bygga och publicera

Krav på byggdatorn: .NET 10 SDK.

```powershell
dotnet publish .\api\toastapi.csproj -c Release -o C:\Build\ToastApi
```

## Installera i IIS

1. Installera IIS med **Windows Authentication** (`Web-Windows-Auth`) och [ASP.NET Core Hosting Bundle](https://dotnet.microsoft.com/download/dotnet/10.0) för .NET 10.
2. Skapa en app pool, t.ex. `ToastApi`, med **.NET CLR version = No Managed Code**. Kör den som ett dedikerat domänkonto eller gMSA (t.ex. `CONTOSO\svc-toastapi$`), eller som `ApplicationPoolIdentity` (ansluter då mot SQL som datorkontot `CONTOSO\WEBSERVER$`).
3. Kopiera publiceringskatalogen till t.ex. `C:\inetpub\ToastApi` och skapa en webbplats eller applikation som pekar dit och använder app poolen.
4. Lägg till en **HTTPS-bindning på port 443** med ett certifikat som klienterna litar på (t.ex. från intern PKI). Namnet i certifikatet måste matcha `ApiUri` i klientkonfigurationen.
5. Aktivera Windows Authentication och stäng av Anonymous Authentication för webbplatsen:

   ```powershell
   Import-Module WebAdministration
   Set-WebConfigurationProperty -Filter /system.webServer/security/authentication/anonymousAuthentication -Name enabled -Value $false -PSPath IIS:\ -Location 'Default Web Site/ToastApi'
   Set-WebConfigurationProperty -Filter /system.webServer/security/authentication/windowsAuthentication -Name enabled -Value $true -PSPath IIS:\ -Location 'Default Web Site/ToastApi'
   ```

   Under IIS delegerar Negotiate-hanteraren i `Program.cs` autentiseringen till IIS Windows Authentication.
6. Registrera SPN för webbplatsens namn på kontot som kör app poolen om ni använder ett eget DNS-namn och vill ha Kerberos (annars faller Negotiate tillbaka till NTLM), t.ex. `setspn -S HTTP/messenger.contoso.se CONTOSO\svc-toastapi$`.
7. Konfigurera `appsettings.json` (eller miljövariabler/`appsettings.Production.json`), se nedan.

## Konfiguration (`api/appsettings.json`)

```json
{
  "ConnectionStrings": {
    "ToastDatabase": "Data Source=tcp:SQLSERVER.example.test,1433;Initial Catalog=ToastNotifications;Integrated Security=True;Encrypt=True;TrustServerCertificate=False;Pooling=True;Max Pool Size=100;ConnectRetryCount=3;ConnectRetryInterval=5;Application Name=ToastApi"
  },
  "ToastApi": {
    "CommandTimeoutSeconds": 15,
    "AllowedRoles": [],
    "AllowedClientGroups": [],
    "RequireComputerAccountMatch": false
  }
}
```

| Inställning | Beskrivning |
|---|---|
| `ConnectionStrings:ToastDatabase` | SQL-anslutning. Använd `Integrated Security=True` så att app poolens identitet används – inga lösenord i filen. Connection pooling är aktiverat (standard i `Microsoft.Data.SqlClient`). |
| `ToastApi:CommandTimeoutSeconds` | Timeout för SQL-anrop. |
| `ToastApi:AllowedRoles` | Windows-grupper som får anropa API:t, t.ex. `["CONTOSO\\Domain Users"]`. Tom lista = alla autentiserade Windows-identiteter. |
| `ToastApi:AllowedClientGroups` | Gruppnamn som klienter får registrera sig för. Tom lista = valfritt gruppnamn. |
| `ToastApi:RequireComputerAccountMatch` | `true` = endast datorkontot (`DOMÄN\PC001$`) får agera för `PC001`. Se *Behörighet*. |

Loggning styrs med sektionen `Logging`. Webservicen loggar till konsol/debug samt till Windows Event Log när den körs på Windows. Registreringar, leasar, kvittenser och nekade anrop loggas med anropande identitet.

## SQL-behörigheter för app poolens identitet

Webservicen behöver inga `db_owner`-rättigheter:

```sql
CREATE LOGIN [CONTOSO\svc-toastapi$] FROM WINDOWS;
USE ToastNotifications;
CREATE USER [CONTOSO\svc-toastapi$] FOR LOGIN [CONTOSO\svc-toastapi$];

-- Polling och kvittens
GRANT EXECUTE ON dbo.usp_GetPendingToast TO [CONTOSO\svc-toastapi$];
GRANT EXECUTE ON dbo.usp_RecordToastDelivery TO [CONTOSO\svc-toastapi$];

-- Klientregistrering (POST /api/Clients) körs som parametriserad SQL mot tabellerna
GRANT SELECT, INSERT ON dbo.ToastClient TO [CONTOSO\svc-toastapi$];
GRANT SELECT, INSERT ON dbo.ToastGroup TO [CONTOSO\svc-toastapi$];
GRANT SELECT, INSERT ON dbo.ToastClientGroup TO [CONTOSO\svc-toastapi$];
```

Rättigheten att köa meddelanden (`dbo.usp_QueueToastMessage`) behövs inte av webservicen; administratörer köar fortfarande med `src/Server/Send-ToastMessage.ps1` direkt mot SQL Server.

## Behörighet

- Alla anrop kräver Windows-autentisering; `AllowedRoles` kan begränsa till vissa AD-grupper.
- Klientskriptet körs i den inloggade användarens session för att kunna visa ADT-prompten, så `-UseDefaultCredentials` skickar normalt **användarens** identitet, inte datorns. Ett inskickat `computerName` är därför inte i sig ett bevis på vilken dator som anropar.
- Anropar ett datorkonto (`DOMÄN\NAMN$`) får det alltid bara agera för sitt eget datornamn (kortnamn eller FQDN).
- Sätt `RequireComputerAccountMatch = true` om klienten körs som `SYSTEM` (datorkontot) och användaridentiteter inte ska få anropa API:t.
- Använd `AllowedClientGroups` om klienter inte själva ska kunna välja godtyckliga grupper.

## Klienten

Se `config/config.example-api.psd1` och README. Kort:

```powershell
Copy-Item .\config\config.example-api.psd1 .\config\config.psd1
.\src\Client\Start-ToastClient-API.ps1 -ConfigPath .\config\config.psd1 -Register -Once
.\src\Client\Start-ToastClient-API.ps1 -ConfigPath .\config\config.psd1 -PollSeconds 30
```

Schemalagd uppgift vid inloggning:

```powershell
.\deploy\Register-ToastClientTask.ps1 -ScriptPath 'C:\ToastSql\src\Client\Start-ToastClient-API.ps1' -ConfigPath 'C:\ToastSql\config\config.psd1'
```

## Nätverk och brandvägg

| Från | Till | Trafik |
|---|---|---|
| Klienter | Webbserver | TCP 443 (HTTPS) |
| Klienter | SQL Server | Ingen (när alla klienter använder API-klienten) |
| Webbserver | SQL Server | TCP 1433 (eller instansens konfigurerade port) |
| Administratör | SQL Server | TCP 1433 för `Send-ToastMessage.ps1` |

Stäng inte klientnätets åtkomst till TCP 1433 förrän alla klienter har bytts till `Start-ToastClient-API.ps1` och flödet (registrering, leasing, kvittens, avbrott/omsändning) är verifierat. Befintliga SQL-klienter (`Start-ToastClient.ps1`) fungerar oförändrat parallellt mot samma databas.

## Felsökning

- `401` från klienten: kontrollera att Windows Authentication är aktiverat och Anonymous avstängt, och att webbplatsens namn finns i *Local intranet*-zonen/SPN är registrerat.
- `403`: identiteten saknas i `AllowedRoles`, datorkontot matchar inte `computerName`, eller gruppen saknas i `AllowedClientGroups`.
- `503`: se Event Log/loggarna på webbservern för SQL-felet (anslutning, behörighet).
- Certifikatfel: klienterna måste lita på certifikatkedjan och namnet måste matcha `ApiUri`.
