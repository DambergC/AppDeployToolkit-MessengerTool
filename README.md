# BurntToast-SQLserver

Gruppbaserade SQL-köade notifieringar för Windows-klienter med **AppDeployToolkit** som enda stödda presentationslager.

Projektet behåller SQL-kö, klientregistrering, polling, leasing, repeat-logik och leveranskvittens, men klienten visar nu meddelanden enbart via `Show-ADTInstallationPrompt` / `Show-InstallationPrompt`.

## Quick start

> **Varning – ta backup först:** Vid uppgradering av en befintlig databas tar `sql/Install-BurntToast-SQLserver.sql` bort kolumnerna `AppLogoPath`, `HeroImagePath`, `AppLogoBytes`, `AppLogoContentType`, `HeroImageBytes` och `HeroImageContentType` från `dbo.ToastMessage`. All bilddata i dessa kolumner raderas **permanent**. Ta en fullständig backup av databasen (t.ex. `BACKUP DATABASE ... TO DISK = ...`) innan skriptet körs.

1. Kör det konsoliderade SQL-skriptet i databasen:

```sql
:r sql/Install-BurntToast-SQLserver.sql
```

2. Kopiera konfigurationen:

```powershell
Copy-Item .\config\config.example.psd1 .\config\config.psd1
```

3. Fyll i SQL-inställningar, klientnamn/grupper och `AppDeployToolkitModulePath`.

4. Registrera klienten:

```powershell
.\src\Client\Start-ToastClient.ps1 -ConfigPath .\config\config.psd1 -Register
```

> `-Register` registrerar klienten och fortsätter sedan polling-loopen. Använd `-Once` för att registrera och avsluta direkt efter en enda körning.

5. Köa ett testmeddelande:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Testmeddelande' `
  -Subtitle 'Valfri underrubrik' `
  -Body 'Detta är ett test.'
```

6. Kör klienten i användarens session:

```powershell
.\src\Client\Start-ToastClient.ps1 -ConfigPath .\config\config.psd1 -Once
```

7. För kontinuerlig polling:

```powershell
.\src\Client\Start-ToastClient.ps1 -ConfigPath .\config\config.psd1 -PollSeconds 30
```

`deploy/Register-ToastClientTask.ps1` registrerar ett logon-task som startar PowerShell med `-STA`. ADT-prompten kräver inte längre WPF-koden som tidigare fanns i repot, men `-STA` är fortfarande ett bra standardval för interaktiva klientstarter.

## Arkitektur

- Administratören köar ett meddelande till en grupp i SQL Server.
- Klienterna pollar SQL Server över TCP 1433.
- Klientscriptet körs i användarens interaktiva session och visar meddelandet via AppDeployToolkit.
- Leveransstatus sparas i SQL Server via lease-/acknowledgement-flödet.

SQL Server är alltså kö- och statuslager, inte presentationskanal.

## Förutsättningar

### Server / administration

- Windows PowerShell 5.1 eller PowerShell 7
- SQL Server
- rättigheter att köra SQL-installationsskript och att köa meddelanden
- nätverksåtkomst till SQL Server

### Klient

- Windows PowerShell 5.1 eller PowerShell 7
- interaktiv användarsession (inte Session 0 / `SYSTEM`)
- nätverksåtkomst till SQL Server på TCP 1433
- en **lokalt paketerad och versionslåst** kopia av `PSAppDeployToolkit` / `AppDeployToolkit`

## Konfiguration

`config/config.psd1` läses med `Import-PowerShellDataFile`, så filen måste innehålla statiska värden. `ClientName = $null` stöds och betyder att klienten använder lokalt datornamn automatiskt.

Exempel:

```powershell
@{
    SqlServer = 'SQLSERVER.example.test'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433
    UseIntegratedSecurity = $true
    SqlCredential = $null
    ClientName = $null
    ClientGroups = @('IT-TEST')
    AppDeployToolkitModulePath = 'C:\ToastSql\Dependencies\PSAppDeployToolkit\4.1.8'
    Encrypt = $true
    TrustServerCertificate = $false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}
```

### `AppDeployToolkitModulePath`

- obligatorisk för klientkörning när `Show-ADTInstallationPrompt` / `Show-InstallationPrompt` inte redan finns laddad i sessionen
- kan peka på en modulmanifestfil (`.psd1`), modulfil (`.psm1`) eller en katalog som innehåller PSAppDeployToolkit
- bör peka på en versionslåst lokal paketering, inte på dynamisk nedladdning vid logon

Exempel:

```powershell
AppDeployToolkitModulePath = 'C:\ToastSql\Dependencies\PSAppDeployToolkit\4.1.8'
AppDeployToolkitModulePath = 'C:\ToastSql\Dependencies\PSAppDeployToolkit\4.1.8\PSAppDeployToolkit.psd1'
```

## AppDeployToolkit-beteende

### Titel, Subtitle och meddelandetext

Klienten mappar innehållet till ADT-prompten så här:

- `Body` skickas som promptens `Message`
- när promptvarianten använder ett separat `Title`-fält skickas toastens titel dit
- en angiven `Subtitle` skickas separat när promptkommandot stöder parametern
- om en ADT-variant kräver `Subtitle` och ingen underrubrik har angetts används första icke-tomma raden från `Body`; om den saknas används `Notification`
- en saknad frivillig `Subtitle` skickas inte, och `Title` kopieras aldrig till `Subtitle`
- klienten detekterar parameterstöd innan något skickas, så äldre `Show-InstallationPrompt`-varianter inte får okända parametrar

### Acknowledge-knappen (höger knapp)

Prompten visar alltid en kvitteringsknapp till höger. Texten styrs med `-AcknowledgeButtonText`:

- utelämnad eller tom → `Acknowledge` (oförändrat standardbeteende)
- max 200 tecken; inledande/avslutande blanksteg tas bort
- får inte vara samma text som `-ButtonText` (skiftlägesokänsligt), annars går knapparna inte att skilja åt
- värdet sparas i den nullable kolumnen `dbo.ToastMessage.AcknowledgeButtonText`; äldre rader utan värde visar `Acknowledge`

### Action-knapp / protokollknapp (vänster knapp)

Den nuvarande ADT-integrationen stöder **en** valfri action-knapp via vänster knapp i prompten, till vänster om acknowledge-knappen. Används inte `-ButtonText` visas bara acknowledge-knappen.

Krav:

- `ButtonText` måste anges
- `ButtonActivationType` måste vara `Protocol` eller `Dismiss`
- `ButtonArguments` måste vara en **absolut** URI när `ButtonActivationType = 'Protocol'`, antingen som rå URL (`'https://...'`) eller som JSON `'{"url":"https://..."}'`
- endast dessa URI-scheman tillåts: `http`, `https`, `mailto`
- JSON-formatet tolkas av `Send-ToastMessage.ps1`, `url` valideras och normaliseras till den råa URL:en **innan** `dbo.usp_QueueToastMessage` anropas, så SQL lagrar alltid den råa URL:en. Felaktig JSON, saknad/tom `url` eller en ogiltig URL ger ett tydligt fel och inget meddelande köas

Exempel med egen text på acknowledge-knappen (`Stäng`) och en vänsterknapp som öppnar en webbadress i standardwebbläsaren:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Information' `
  -Subtitle 'Projektet' `
  -Body 'Öppna projektet på GitHub.' `
  -ButtonText 'Öppna GitHub' `
  -ButtonArguments 'https://github.com/DambergC/BurntToast-SQLserver' `
  -ButtonActivationType 'Protocol' `
  -AcknowledgeButtonText 'Stäng'
```

Samma knapp med JSON-formatet (`url` extraheras och lagras som `https://github.com/DambergC/BurntToast-SQLserver/tree/main`):

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Information' `
  -Body 'Öppna projektet på GitHub.' `
  -ButtonText 'Öppna GitHub' `
  -ButtonArguments '{"url":"https://github.com/DambergC/BurntToast-SQLserver/tree/main"}' `
  -ButtonActivationType 'Protocol' `
  -AcknowledgeButtonText 'Stäng'
```

Fler exempel:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Portal uppdaterad' `
  -Body 'Klicka på knappen för att öppna intranätets driftstatus.' `
  -ButtonText 'Öppna status' `
  -ButtonArguments 'https://status.contoso.example/' `
  -ButtonActivationType 'Protocol'
```

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\config.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Bekräfta läsning' `
  -Body 'Stäng prompten via vänster knapp.' `
  -ButtonText 'Stäng' `
  -ButtonActivationType 'Dismiss'
```

Beteende:

- `Show-ADTInstallationPrompt` (4.1.8) returnerar texten på den klickade knappen (eller `Timeout`); klick på vänsterknappens text tolkas som action, allt annat som kvittering
- om användaren klickar action-knappen och det är en `Protocol`-knapp valideras URI:n igen och öppnas i användarens standardwebbläsare/standardprogram för schemat — Edge hårdkodas inte:
  - körs klienten redan i den inloggade användarens interaktiva session (inte SYSTEM, inte session 0) öppnas URL:en med `Start-Process -FilePath <url>`
  - körs klienten som SYSTEM eller utanför användarsessionen startas den i den inloggade användarens kontext via PSAppDeployToolkits `Start-ADTProcessAsUser -FilePath explorer.exe -ArgumentList <url> -NoWait` (parametrar som stöds av den medföljande 4.1.8-versionen)
  - saknas `Start-ADTProcessAsUser` i det läget loggas ett fel och leveransen markeras som `Failed`
- om användaren klickar acknowledge-knappen registreras leveransen utan att någon URI öppnas
- om protokollstart misslyckas returneras felet tydligt och meddelandet markeras inte som tyst kvitterat

Begränsningar:

- relativa URL:er som `www.example.com` eller `/path` stöds inte
- endast JSON-objekt med egenskapen `url` stöds; andra omslutna värden stöds inte
- `ButtonLeftText`/`ButtonRightText` skickas bara om promptkommandot (`Show-ADTInstallationPrompt` eller äldre `Show-InstallationPrompt`) stöder parametern; saknas stöd för vänsterknapp loggas en varning och knappen utelämnas
- andra scheman, till exempel `file:` eller anpassade interna URI-scheman, blockeras med avsikt

## `src/Server/Send-ToastMessage.ps1`

Syntax:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath <string> `
  -GroupName <string> `
  -Title <string> `
  -Body <string> `
  [-Subtitle <string>] `
  [-ExpiresUtc <datetime>] `
  [-Urgent] `
  [-RepeatIntervalSeconds <int>] `
  [-RepeatIntervalMinutes <int>] `
  [-RepeatCount <int>] `
  [-ButtonText <string>] `
  [-ButtonArguments <string>] `
  [-ButtonActivationType <string>] `
  [-AcknowledgeButtonText <string>] `
  [-Scenario <string>] `
  [-DisplayMode AppDeployToolkit]
```

`-AcknowledgeButtonText` sätter texten på den högra kvitteringsknappen (default `Acknowledge`). `-ButtonText`, `-ButtonArguments` och `-ButtonActivationType` styr den valfria vänstra action-knappen. `@AcknowledgeButtonText` skickas bara till `dbo.usp_QueueToastMessage` när en egen text anges, så meddelanden med standardknapp fungerar även mot databaser som ännu inte uppgraderats.

Skriptet exponerar ett strömlinjeformat gränssnitt utan bild- och ljudparametrar. `-DisplayMode` accepterar enbart `AppDeployToolkit` och defaultar till det värdet.

Bildkolumnerna (`AppLogoPath`, `HeroImagePath`, `AppLogoBytes`, `AppLogoContentType`, `HeroImageBytes`, `HeroImageContentType`) och motsvarande parametrar i `dbo.usp_QueueToastMessage` samt kolumner i `dbo.usp_GetPendingToast` är borttagna. Kolumnen `Sound` och parametern `@Sound` finns kvar för kompatibilitet men skickas inte av PowerShell-skripten. Anrop som fortfarande skickar bildparametrar till `dbo.usp_QueueToastMessage` måste uppdateras.

## `src/Client/Start-ToastClient.ps1`

Syntax:

```powershell
.\src\Client\Start-ToastClient.ps1 -ConfigPath <string> [-Register] [-Once] [-PollSeconds <int>]
```

Klienten:

- registrerar dator/grupptillhörighet i SQL när `-Register` används
- pollar `dbo.usp_GetPendingToast`
- visar meddelandet via AppDeployToolkit
- kvitterar leverans via `dbo.usp_RecordToastDelivery`
- retry:ar leveranskvittens för tillfälliga transport-/timeoutfel

## SQL-skript

### Rekommenderat

- `sql/Install-BurntToast-SQLserver.sql`
  - skapar saknade bastabeller/index
  - applicerar repeat-/lease-logik
  - applicerar knapp-/display-mode-stöd
  - applicerar lokal tidsrapportering
  - normaliserar `DisplayMode` till `AppDeployToolkit` för `NULL`-värden och rader som fortfarande saknar leveranshistorik vid uppgradering
  - tar i befintliga databaser bort beroenden till de obsoleta bildkolumnerna (t.ex. `IX_ToastMessage_Polling`), tar bort själva kolumnerna, återskapar `IX_ToastMessage_Polling` utan bildkolumner och skapar om procedurerna utan bildparametrar. **Bilddata raderas permanent – ta backup först.** Skriptet kan köras om flera gånger.

### Legacy / stegvis uppgradering

- `sql/001-schema.sql`
- `sql/002-toast-design-repeat.sql`
- `sql/003-toast-button.sql`
- `sql/004-local-time-reporting.sql`

De stegvisa skripten lägger inte längre till bildkolumnerna men tar inte heller bort dem från befintliga databaser; kör det konsoliderade skriptet (efter backup) för att ta bort dem. Kör det konsoliderade skriptet igen vid uppgradering; det lägger till de nullable kolumnerna `Subtitle` och `AcknowledgeButtonText` i befintliga databaser före procedurdefinitionerna. Vid stegvis installation/uppgradering lägger `sql/003-toast-button.sql` till kolumnerna innan de uppdaterade kö- och pollningsprocedurerna skapas. Den nya procedurparametern `@AcknowledgeButtonText` är valfri och ligger sist, så befintliga anrop fungerar oförändrat.

## Migration från äldre visningslägen samt bild- och ljudfunktioner

Den här refaktorn tar bort stöd för:

- `BurntToast`
- `Wpf`
- Bildfunktioner (`AppLogoPath`, `HeroImagePath`, `AppLogoFilePath`, `HeroImageFilePath`, `AppLogoBytes`, `HeroImageBytes`, `AppLogoContentType`, `HeroImageContentType`)
- Ljudfunktioner (`Sound`)
- Obsolet paketerad artefakt `Toast.zip`

Praktiska följder:

- `Send-ToastMessage.ps1` accepterar inte längre bild- eller ljudparametrar
- klientkonfigurationen använder inte längre `InternalPowerShellRepository`
- `Toast.zip` är borttagen och `Dependencies/PSAppDeployToolkit` är det enda beroendet som behålls
- bildkolumnerna tas bort från `dbo.ToastMessage` och procedurerna av `sql/Install-BurntToast-SQLserver.sql` (bilddata raderas permanent – ta backup först); `Sound` ligger kvar som kompatibilitetsfält men skickas inte av PowerShell-skripten
- nya köade meddelanden använder `DisplayMode AppDeployToolkit`
- tester och modulfunktioner för bildhantering och temporärfilshantering är borttagna

## Testning

Kör repositoryts Pester-svit:

```powershell
Invoke-Pester -Path .\tests\ToastSql.Tests.ps1
```

Fokus i testsviten ligger nu på:

- AppDeployToolkit-only rendering
- separat Subtitle-rendering och body-baserad fallback för ADT-varianter som kräver den
- protokollknappar och URI-validering
- konfigurerbar text på acknowledge-knappen och separat vänster protokollknapp
- SQL-kontrakt, leasing och leveransflödeskompatibilitet
