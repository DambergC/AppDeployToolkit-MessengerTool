# AppDeployToolkit-MessengerTool

Gruppbaserade meddelanden från SQL Server till interaktiva Windows-sessioner. Administratören importerar datorgrupper från AD och köar meddelanden. Klienten läser kön och visar en AppDeployToolkit-dialog med **en kvitteringsknapp** (standardtext `Stäng`). Lässtatus och eventuella repetitioner lagras lokalt **per användare i HKCU**, aldrig som leveranshistorik i SQL.

## Förutsättningar

- 64-bitars Windows och 64-bitars Windows PowerShell 5.1 eller PowerShell 7. Det medföljande PSAppDeployToolkit-manifestet kräver minst Windows PowerShell 5.1.14393.0.
- SQL Server 2016 eller senare, en ny tom databas och DBA-behörighet för installationen.
- TCP-åtkomst till SQL Server (vanligen port 1433), aktiverad SQL-TLS och ett betrott servercertifikat vars namn matchar servernamnet i konfigurationen.
- Synkroniserade systemklockor på SQL-server, administrationsdator och klienter; alla giltighetskontroller använder UTC.
- `sqlcmd` på installationsdatorn. Endast administrationsdatorn behöver RSAT-modulen `ActiveDirectory` och rätt att läsa aktuella AD-objekt.
- Klienten måste köras utan elevation i den inloggade användarens interaktiva session, inte som `SYSTEM` eller i Session 0.

## 1. Installera filer och skapa konfiguration

Distribuera projektets filer, inklusive den oförändrade, versionslåsta katalogen `Dependencies\PSAppDeployToolkit\4.1.8`, till **`C:\Program Files\AppDeployToolkit-MessengerTool`**. Hämta inte moduler dynamiskt vid inloggning. Skydda kod, beroenden och konfiguration med fil-ACL: endast administratörer får ändra dem; klientanvändare behöver läs-/köråtkomst.

Kör följande kopiering som lokal administratör på respektive dator. Administrationsdatorn kan använda samma installationssökväg:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
# På klienten:
Copy-Item -LiteralPath (Join-Path $root 'config\config.example.psd1') `
  -Destination (Join-Path $root 'config\config.psd1')

# Endast på administrationsdatorn:
Copy-Item -LiteralPath (Join-Path $root 'config\config.example.psd1') `
  -Destination (Join-Path $root 'config\admin.local.psd1')
```

Använd endast `config.example.psd1` som mall. De lokala konfigurationerna är git-ignorerade; distribuera inte administratörskonfiguration eller administratörsuppgifter till klienterna. Ett filnamn ger inga SQL-rättigheter.

Redigera respektive lokal fil med statiska värden (`Import-PowerShellDataFile` utvärderar inte godtycklig kod):

```powershell
@{
    SqlServer = 'sql01.example.test'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = $true
    SqlCredential = $null
    ClientName = $null
    AppDeployToolkitModulePath = 'C:\Program Files\AppDeployToolkit-MessengerTool\Dependencies\PSAppDeployToolkit\4.1.8\PSAppDeployToolkit.psd1'
    Encrypt = $true
    TrustServerCertificate = $false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
```

Ange samma SQL-server, port och databas i båda konfigurationerna. `ClientName = $null` använder lokalt datornamn, vilket ska matcha importerad AD-dators **Name**, inte DNSHostName. Behåll `Encrypt = $true` och `TrustServerCertificate = $false`; åtgärda certifikatkedja/namn i stället för att kringgå valideringen.

## 2. Skapa en tom databas och installera SQL

**Endast för förstagångsinstallation.** Installationsskriptet skapar inte databasen och vägrar installera över befintliga applikationsobjekt. Det är ingen destruktiv uppgradering eller kompatibilitetslösning för äldre databaser. Befintliga installationer kräver separat uppgraderingsplan, verifierad backup och testad återställning.

Kör som DBA i PowerShell; ersätt server/databas med era värden. `-E` använder aktuell Windows-identitet, `-N` begär kryptering, `-b` ger felkod vid SQL-fel och `-f 65001` läser skriptet som UTF-8 så att exempelvis `Stäng` bevaras:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
sqlcmd -S 'tcp:sql01.example.test,1433' -E -N -b -f 65001 -d master `
  -Q 'CREATE DATABASE [ToastNotifications];'
if ($LASTEXITCODE -ne 0) { throw 'Databasen kunde inte skapas; fortsätt inte.' }

sqlcmd -S 'tcp:sql01.example.test,1433' -E -N -b -f 65001 -d ToastNotifications `
  -i (Join-Path $root 'sql\Install-ToastDatabase.sql')
if ($LASTEXITCODE -ne 0) { throw 'SQL-installationen misslyckades; kontrollera felutskriften.' }
```

Kör **enbart** detta installationsskript i den uttryckligen valda, tomma databasen. Det installerar tabellerna `dbo.ToastGroup`, `dbo.ToastClient`, `dbo.ToastClientGroup`, `dbo.ToastMessage`, kö-/läsprocedurer och roller. Inga delivery-, lease- eller historiktabeller behövs.

### Separera SQL-identiteter

DBA skapar separata Windows-grupplogins och databasanvändare. Ersätt `EXAMPLE` och gruppnamnen med befintliga AD-grupper. Klientgruppen ska innehålla **användare**, inte datorernas maskinkonton:

```sql
USE [master];
CREATE LOGIN [EXAMPLE\ToastMessageAdmins] FROM WINDOWS;
CREATE LOGIN [EXAMPLE\ToastClientUsers] FROM WINDOWS;
GO
USE [ToastNotifications];
CREATE USER [EXAMPLE\ToastMessageAdmins] FOR LOGIN [EXAMPLE\ToastMessageAdmins];
CREATE USER [EXAMPLE\ToastClientUsers] FOR LOGIN [EXAMPLE\ToastClientUsers];
ALTER ROLE [ToastMessageAdmin] ADD MEMBER [EXAMPLE\ToastMessageAdmins];
ALTER ROLE [ToastClientReader] ADD MEMBER [EXAMPLE\ToastClientUsers];
GO
```

- `ToastClientReader`: `EXECUTE` på den SELECT-baserade `dbo.usp_GetPendingToast`; `INSERT`, `UPDATE` och `DELETE` nekas. Ingen klientregistrering eller skrivning till SQL.
- `ToastMessageAdmin`: `EXECUTE` på `dbo.usp_QueueToastMessage` samt `SELECT`/`INSERT` på de tre måltabellerna `ToastGroup`, `ToastClient`, `ToastClientGroup`, vilket AD-importens parametriserade SQL använder.

Kör import/köning med administratörens Windows-identitet och klienten med användarens Windows-identitet. Ge inte klientgruppen `db_owner`, `db_datawriter`, breda EXECUTE-rättigheter eller medlemskap i administratörsgruppen. Kontrollera även rättigheter via andra grupper och `public`.

**Datornamn är ett urval, inte en autentiseringsgräns:** en behörig klientidentitet kan begära en annan registrerad dators meddelanden. Använd inte denna målstyrning för hemligt innehåll.

## 3. Importera mål från AD

Kör på administrationsdatorn med administratörens SQL-behörighet. `Tag` är notifieringsgruppens namn i SQL, inte ett AD-attribut. Förhandsgranska först:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
$adminConfig = Join-Path $root 'config\admin.local.psd1'
$importScript = Join-Path $root 'src\Server\Import-ToastADComputers.ps1'

& $importScript -ConfigPath $adminConfig -Tag 'IT-TEST' `
  -SearchBase 'OU=Workstations,DC=example,DC=test' `
  -Filter 'Enabled -eq $true' -WhatIf

# Efter kontroll: samma kommando utan -WhatIf.
& $importScript -ConfigPath $adminConfig -Tag 'IT-TEST' `
  -SearchBase 'OU=Workstations,DC=example,DC=test' `
  -Filter 'Enabled -eq $true'
```

Alternativt anger du en AD-grupps DN som `SearchBase`; då används rekursiva datormedlemskap och inget eget `Filter`:

```powershell
& $importScript -ConfigPath $adminConfig -Tag 'IT-TEST' `
  -SearchBase 'CN=ToastPilot,OU=Groups,DC=example,DC=test' -WhatIf
```

Ta bort `-WhatIf` efter kontroll för att importera gruppurvalet. Importen ändrar inte AD. Saknade grupper, datorer och medlemskap läggs till utan dubbletter; befintliga medlemskap bevaras, inte synkroniseras bort. Inaktiva objekt återaktiveras inte. Klienterna registrerar aldrig sig själva.

## 4. Köa ett meddelande med obligatorisk giltighetstid

`Title` och `Body` krävs. `Subtitle` är en valfri, självständig underrubrik; utelämnad eller blank underrubrik visas som det neutrala `Meddelande`, aldrig som en kopia av titeln eller brödtexten. Innehållet behandlas som vanlig text, utan markup eller klickbara länkar. En URL får stå som text men öppnas inte.

Dialogen har exakt en kvitteringsknapp; `AcknowledgeButtonText` ändrar dess text (standard `Stäng`). Texten `Timeout` är reserverad för ADT:s timeoutresultat och nekas oavsett skiftläge. Det finns inga exponerade parametrar för URL-start, bilder, ljud, scenario, brådskande läge eller visningsläge.

Knapptexten får vara högst 200 tecken; tom text använder standardvärdet.

Välj **exakt ett** av följande:

- `ExpiresUtc`: en explicit framtida tidpunkt som `DateTimeOffset`, tidszonsbestämd `DateTime` eller ISO 8601-text med `Z`/tidszonsförskjutning. Tidszon krävs; exemplet nedan konverterar till UTC.
- `ActiveDuration`: positivt heltal tillsammans med `DurationUnit`, exakt `Days`, `Hours` eller `Minutes`.

SQL beräknar varaktigheten relativt `CreatedUtc = SYSUTCDATETIME()` vid insättning, inte relativt klientstart. Sluttiden måste vara senare än aktuell UTC-tid. Giltighetstiden är varken repetitionsintervall eller dialogens timeout.

Exempel med uttrycklig tidszon och egen knapptext (byt datum till en framtida tidpunkt vid körning):

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
$adminConfig = Join-Path $root 'config\admin.local.psd1'
$sendScript = Join-Path $root 'src\Server\Send-ToastMessage.ps1'
$expiry = ([datetimeoffset]'2027-01-15T17:00:00+01:00').UtcDateTime

& $sendScript -ConfigPath $adminConfig -GroupName 'IT-TEST' `
  -Title 'Planerat underhåll' -Subtitle 'Information från IT' `
  -Body 'Spara arbetet. Mer information: https://status.example.test/' `
  -AcknowledgeButtonText 'Jag har läst' -ExpiresUtc $expiry
```

Exempel för samtliga varaktighetsenheter:

```powershell
& $sendScript -ConfigPath $adminConfig -GroupName 'IT-TEST' `
  -Title 'Veckoinformation' -Body 'Information giltig i två dygn.' `
  -ActiveDuration 2 -DurationUnit Days

& $sendScript -ConfigPath $adminConfig -GroupName 'IT-TEST' `
  -Title 'Driftinformation' -Body 'Information giltig i tre timmar.' `
  -ActiveDuration 3 -DurationUnit Hours

& $sendScript -ConfigPath $adminConfig -GroupName 'IT-TEST' `
  -Title 'Testmeddelande' -Body 'Kvittera med Stäng.' `
  -ActiveDuration 15 -DurationUnit Minutes
```

Utelämna repetitionsparametrar för engångsvisning. Vid behov kan **antingen** `RepeatIntervalSeconds` **eller** `RepeatIntervalMinutes` kombineras med `RepeatCount` (minst 2, inklusive första kvitteringen). Nästa visning räknas från föregående lyckade kvittering. Repetitioner förlänger aldrig giltighetstiden.

## 5. Starta och verifiera klienten

Kör i avsedd användares **icke-eleverade, interaktiva 64-bitars PowerShell**:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
$clientScript = Join-Path $root 'src\Client\Start-ToastClient.ps1'
$clientConfig = Join-Path $root 'config\config.psd1'
& $clientScript -ConfigPath $clientConfig -Once
```

Smoketest med ett nytt meddelande utan repetitioner:

1. Importera testdatorn och köa ett meddelande med tillräcklig giltighetstid.
2. Kör `-Once` och klicka på kvitteringsknappen.
3. Kör samma kommando igen: meddelandet ska **inte** visas för samma användare.
4. Logga in som en annan SQL-behörig användare på samma dator och kör `-Once`: den användaren har egen lässtatus och ska få meddelandet.
5. Köa ett separat meddelande med kort giltighetstid och vänta tills det gått ut innan klientstart: det ska hoppas över. Timeout, okänt dialogresultat eller visningsfel ska lämna meddelandet oläst; ett nytt försök sker medan det fortfarande är giltigt.

Klienten lagrar `Read`, `ShowCount` och `NextShowUtc` per meddelande i användarens HKCU, avgränsat av SQL-server/port, databas och datornamn. Registernyckeln skapas automatiskt vid behov; ingen manuell initiering eller maskinomfattande register-ACL behövs. En per-användar-mutex hindrar konkurrerande visningar för samma användarscope; en upptagen `-Once` kan avslutas utan visning. Andra användares kvittenser påverkar inte din status.

Medlemskap, avbrott och giltighet kontrolleras igen innan nästa väntande meddelande visas. **En redan öppen dialog stängs inte automatiskt när giltighetstiden går ut.** Ingen lässtatus skickas tillbaka till SQL. Lokal status är inte ett manipulationsskyddat revisionsregister; borttagen användarprofil/status kan göra att aktiva meddelanden visas igen. Återanvändning av meddelande-ID efter databasåterställning kräver separat hantering av lokal status.

### Automatisk start per användare

Efter godkänt smoketest registrerar varje avsedd användare sin egen inloggningsaktivitet:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
& (Join-Path $root 'deploy\Register-ToastClientTask.ps1') `
  -ScriptPath (Join-Path $root 'src\Client\Start-ToastClient.ps1') `
  -ConfigPath (Join-Path $root 'config\config.psd1')
```

Aktiviteten använder interaktiv inloggning, begränsade rättigheter och PowerShell med `-STA`; den startar vid nästa inloggning. Registrera inte som `SYSTEM`. Använd beständiga, absoluta sökvägar och behåll filskyddet från steg 1. Stoppa manuellt startad polling innan aktiviteten testas. För manuell kontinuerlig körning:

```powershell
& (Join-Path $root 'src\Client\Start-ToastClient.ps1') `
  -ConfigPath (Join-Path $root 'config\config.psd1') -PollSeconds 30
```

## Felsökning och tester

| Symptom | Kontroll |
| --- | --- |
| SQL-inloggning/EXECUTE nekas | Aktuell Windows-användare, AD-gruppmedlemskap och rätt databasroll; använd inte maskinkontot eller adminrättigheter som klientlösning. |
| SQL-anslutning eller TLS misslyckas | Servernamn, TCP-port, brandvägg och betrodd certifikatkedja/namn; behåll certifikatvalidering. |
| Inga meddelanden | Matchning mellan AD `Name` och `ClientName`, aktiv dator/grupp, medlemskap, UTC-giltighet, eventuell avbrytning och användarens lokala kvittens/repetitionsstatus. Stoppa dubbla klientprocesser för användaren. |
| Dialogen kan inte visas | Interaktiv session, 64-bitars PowerShell, lokal ADT-sökväg samt läs-/köråtkomst till den medföljande modulen. |
| Meddelandet visas igen efter kvittering | Kontrollera fel vid skrivning till HKCU, ändrat SQL-/datorscope, borttagen profil/status eller aktiverade repetitioner. |

Repositoryts befintliga Pester-svit körs på en dator med Pester installerat:

```powershell
$root = 'C:\Program Files\AppDeployToolkit-MessengerTool'
Invoke-Pester -Path (Join-Path $root 'tests\ToastSql.Tests.ps1')
```

Mockade tester ersätter inte integrationstest mot verklig SQL Server, AD, TLS och en interaktiv Windows-session. Verifiera installation, SQL-roller och smoketest i målmiljön före utrullning.
