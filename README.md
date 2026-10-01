# BurntToast-SQLserver

Gruppbaserade SQL-köade notifieringar för Windows-klienter med **AppDeployToolkit** som enda stödda presentationslager.

Projektet behåller SQL-kö, klientregistrering, polling, leasing, repeat-logik och leveranskvittens, men klienten visar nu meddelanden enbart via `Show-ADTInstallationPrompt` / `Show-InstallationPrompt`.

## Quick start

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
- `ButtonArguments` måste vara en **absolut** URI när `ButtonActivationType = 'Protocol'`
- endast dessa URI-scheman tillåts: `http`, `https`, `mailto`

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

- om användaren klickar action-knappen och det är en `Protocol`-knapp öppnas URI:n via `Start-Process`, dvs. i standardwebbläsaren/standardprogrammet för schemat
- om användaren klickar acknowledge-knappen registreras leveransen utan att någon URI öppnas
- om protokollstart misslyckas returneras felet tydligt och meddelandet markeras inte som tyst kvitterat

Begränsningar:

- relativa URL:er som `www.example.com` eller `/path` stöds inte
- JSON eller andra omslutna värden, t.ex. `'{"url":"https://..."}'`, stöds inte; skicka URL:en direkt
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

Tidigare bild- och ljudkolumner i SQL-databasen (`AppLogoPath`, `HeroImagePath`, `AppLogoBytes`, `HeroImageBytes`, `AppLogoContentType`, `HeroImageContentType`, `Sound`) samt parametrarna i `dbo.usp_QueueToastMessage` finns kvar som bakåtkompatibilitetsfält för befintliga installationer, men PowerShell-skripten skickar inte längre bild- eller ljuddata och lämnar dessa värden som `NULL`.

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

### Legacy / stegvis uppgradering

- `sql/001-schema.sql`
- `sql/002-toast-design-repeat.sql`
- `sql/003-toast-button.sql`
- `sql/004-local-time-reporting.sql`

Kör det konsoliderade skriptet igen vid uppgradering; det lägger till de nullable kolumnerna `Subtitle` och `AcknowledgeButtonText` i befintliga databaser före procedurdefinitionerna. Vid stegvis installation/uppgradering lägger `sql/003-toast-button.sql` till kolumnerna innan de uppdaterade kö- och pollningsprocedurerna skapas. Den nya procedurparametern `@AcknowledgeButtonText` är valfri och ligger sist, så befintliga anrop fungerar oförändrat.

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
- SQL-kompatibilitetsfält för bild och ljud ligger kvar i `dbo.ToastMessage` och procedurer för att inte bryta befintliga databaser, men PowerShell-skripten skickar inte längre bild- eller ljuddata
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
