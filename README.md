# AppDeployToolkit-MessengerTool

Gruppbaserade SQL-köade notifieringar för Windows-klienter med **AppDeployToolkit** som enda stödda presentationslager.

SQL lagrar meddelanden och administratörshanterad grupptillhörighet. Klienterna har enbart läsåtkomst och visar meddelanden via `Show-ADTInstallationPrompt` / `Show-InstallationPrompt`. Lässtatus och repeat-schema sparas per dator i Windows-registret (HKLM), inte per användare eller i databasen.

## Quick start

> **Varning – ta backup först:** Vid uppgradering av en befintlig databas tar `sql/Install-BurntToast-SQLserver.sql` bort kolumnerna `AppLogoPath`, `HeroImagePath`, `AppLogoBytes`, `AppLogoContentType`, `HeroImageBytes` och `HeroImageContentType` från `dbo.ToastMessage`. All bilddata i dessa kolumner raderas **permanent**. Ta en fullständig backup av databasen (t.ex. `BACKUP DATABASE ... TO DISK = ...`) innan skriptet körs.

1. Kör det konsoliderade SQL-skriptet i databasen:

```sql
:r sql/Install-BurntToast-SQLserver.sql
```

2. Kopiera klientkonfigurationen. På administrationsdatorn skapar du även en separat administratörskonfiguration (distribuera den inte till klienterna):

```powershell
Copy-Item .\config\config.example.psd1 .\config\config.psd1
# Endast på administrationsdatorn:
Copy-Item .\config\config.example.psd1 .\config\admin.psd1
```

3. Fyll i SQL-inställningar i båda filerna, samt klientnamn och `AppDeployToolkitModulePath` i klientfilen. Konfigurationerna ska peka på samma databas. Använd separata SQL-identiteter för administration och klienter och tilldela klientidentiteten rollen `ToastClientReader` enligt avsnittet **SQL-behörigheter** innan klienten startas. Med integrerad säkerhet används identiteten som kör respektive skript; filnamnet `admin.psd1` ger i sig inga extra rättigheter.

4. Importera datorer från AD på administrationsdatorn (RSAT-modulen `ActiveDirectory` krävs):

```powershell
.\src\Server\Import-ToastADComputers.ps1 -ConfigPath .\config\admin.psd1 `
  -Tag 'IT-TEST' -SearchBase 'OU=Workstations,DC=example,DC=test' -Filter 'Enabled -eq $true' -WhatIf

# Kör utan -WhatIf när urvalet har kontrollerats:
.\src\Server\Import-ToastADComputers.ps1 -ConfigPath .\config\admin.psd1 `
  -Tag 'IT-TEST' -SearchBase 'OU=Workstations,DC=example,DC=test' -Filter 'Enabled -eq $true'
```

> `Tag` är SQL-notifieringsgruppens namn, inte ett AD-attribut. Klienten registrerar sig aldrig själv; `-Register` har tagits bort.

5. Köa ett testmeddelande:

```powershell
.\src\Server\Send-ToastMessage.ps1 `
  -ConfigPath .\config\admin.psd1 `
  -GroupName 'IT-TEST' `
  -Title 'Testmeddelande' `
  -Subtitle 'Valfri underrubrik' `
  -Body 'Detta är ett test.'
```

6. Förbered maskinens registerlagring en gång från **64-bitars PowerShell som administratör** på varje klientdator:

```powershell
.\deploy\Initialize-ToastReadState.ps1
```

Skriptet ger gruppen INTERACTIVE (SID `S-1-5-4`, oberoende av Windows-språk) läsning, skrivning av värden och skapande av undernycklar endast under `HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState`, med arv till undernycklar. Det ger inte klienterna administratörsrättigheter, ändringsrätt till ACL eller skrivrätt till föräldern `Software`, programfiler eller konfiguration. Behåll program- och konfigurationsfiler administratörsskyddade. Alla interaktiva användare kan ändra den delade lässtatusen; den är inte ett manipulationsskyddat kvittens-/revisionsregister. Saknade eller nekade rättigheter ger fel; klienten försöker inte höja behörighet eller falla tillbaka till HKCU.

7. Kör klienten **utan elevation** i användarens session, med 64-bitars PowerShell:

```powershell
.\src\Client\Start-ToastClient.ps1 -ConfigPath .\config\config.psd1 -Once
```

8. För kontinuerlig polling:

```powershell
.\src\Client\Start-ToastClient.ps1 -ConfigPath .\config\config.psd1 -PollSeconds 30
```

`deploy/Register-ToastClientTask.ps1` registrerar ett logon-task som startar PowerShell med `-STA`. ADT-prompten kräver inte längre WPF-koden som tidigare fanns i repot, men `-STA` är fortfarande ett bra standardval för interaktiva klientstarter.

### Automatisk start vid inloggning

Efter ett lyckat engångstest, kör följande i den avsedda användarens **icke-eleverade 64-bitars PowerShell** från den installerade projektkatalogen:

```powershell
$scriptPath = (Resolve-Path .\src\Client\Start-ToastClient.ps1).Path
$configPath = (Resolve-Path .\config\config.psd1).Path
.\deploy\Register-ToastClientTask.ps1 -ScriptPath $scriptPath -ConfigPath $configPath
```

Använd beständiga lokala sökvägar, inte en temporär utrullningskatalog. Upprepa taskregistreringen för varje användare som ska kunna visa meddelanden; HKLM-provisioneringen görs däremot bara en gång per dator. Tasken startar vid nästa inloggning. Stoppa eventuell manuellt startad polling före test av tasken.

### Kontrollera att lässtatus delas per dator

1. Köa ett nytt testmeddelande utan repeat-parametrar med administratörsidentiteten och notera dess `MessageId`.
2. Kör klienten med `-Once` och kvittera prompten. Timeout eller renderingsfel ska inte räknas som läst.
3. Läs maskinens status från 64-bitars PowerShell:

```powershell
Import-Module .\src\Module\ToastSql.psm1 -Force
$config = Import-ToastConfig -Path .\config\config.psd1 -ResolveClientName
$statePath = Get-ToastReadStatePath -Server $config.SqlServer -Port $config.SqlPort `
  -Database $config.SqlDatabase -ComputerName $config.ClientName
# Ersätt 42 med MessageId från ditt test:
Get-ToastReadState -StatePath $statePath -MessageId 42
```

För ett kvitterat engångsmeddelande ska `Read` vara `True`, `ShowCount` vara `1` och `NextShowUtc` vara tomt. Kör `-Once` igen, sedan från en annan användares interaktiva session med samma SQL-server/port, databas och klientnamn: samma meddelande ska inte visas igen. Båda användarna behöver SQL-läsbehörighet. Lässtatus skickas aldrig tillbaka till SQL.

### Felsökning

| Symptom | Kontroll |
| --- | --- |
| Fel om 32-bitars process | Starta 64-bitars PowerShell; klienten avvisar 32-bitars registervyn. |
| `Machine read state is not provisioned` eller åtkomst nekas till HKLM | Kör `deploy/Initialize-ToastReadState.ps1` som administratör i 64-bitars PowerShell på klientdatorn. Kör sedan klienten utan elevation; ge inte skrivåtkomst till hela `Software` eller programkatalogen. |
| SQL-inloggning eller EXECUTE nekas | Kontrollera körande användares SQL-identitet, nätverksåtkomst och medlemskap i `ToastClientReader`. Använd separat administratörsidentitet för import och köning, inte utökade klienträttigheter. |
| Inga meddelanden visas | Kontrollera att AD-datorns `Name` matchar `ClientName`, att dator/grupp är aktiva, att gruppmedlemskapet finns och att meddelandet inte är utgånget, avbrutet eller redan lokalt kvitterat. En annan sessions öppna prompt kan hålla maskinlåset; `-Once` hoppar då över omgången. |
| Gamla meddelanden visas efter uppgradering | Tidigare HKCU-status och SQL-leveranshistorik importeras inte till HKLM. Se migrationsavsnitten innan utrullning; radera inte delad status som rutinmässig felsökning eftersom kvitterade meddelanden då kan visas igen. |

## Arkitektur

- Administratören köar ett meddelande till en grupp i SQL Server.
- Klienterna pollar SQL Server över TCP 1433.
- Klientscriptet körs i användarens interaktiva session och visar meddelandet via AppDeployToolkit.
- Explicit kvittering (eller lyckad action/dismiss) sparas i datorns delade HKLM-register; timeout, okänt promptresultat och fel räknas inte som lästa.

SQL Server är meddelandelager, inte presentationskanal eller aktuellt leveransrapporteringssystem.

## Förutsättningar

### Server / administration

- Windows PowerShell 5.1 eller PowerShell 7
- SQL Server
- rättigheter att köra SQL-installationsskript och att köa meddelanden
- nätverksåtkomst till SQL Server

### Klient

- 64-bitars Windows och 64-bitars Windows PowerShell 5.1 eller PowerShell 7 (32-bitars klientprocesser avvisas för att undvika separata registervyer)
- interaktiv användarsession (inte Session 0 / `SYSTEM`)
- engångsprovisionering av HKLM-nyckeln som administratör enligt quick start; därefter körs klienten utan administratörsrättigheter
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

- `Show-ADTInstallationPrompt` (4.1.8) returnerar texten på den klickade knappen (eller `Timeout`); kända knappresultat tolkas som action eller kvittering. `Timeout`, tomt och okänt resultat lämnar meddelandet oläst
- om användaren klickar action-knappen och det är en `Protocol`-knapp valideras URI:n igen och öppnas i användarens standardwebbläsare/standardprogram för schemat — Edge hårdkodas inte:
  - körs klienten redan i den inloggade användarens interaktiva session (inte SYSTEM, inte session 0) öppnas URL:en med `Start-Process -FilePath <url>`
  - körs klienten som SYSTEM eller utanför användarsessionen startas den i den inloggade användarens kontext via PSAppDeployToolkits `Start-ADTProcessAsUser -FilePath explorer.exe -ArgumentList <url> -NoWait` (parametrar som stöds av den medföljande 4.1.8-versionen)
  - saknas `Start-ADTProcessAsUser` i det läget loggas ett fel och meddelandet lämnas oläst (klientskriptet ska alltid köras interaktivt)
- om användaren klickar acknowledge-knappen sparas lässtatus lokalt utan att någon URI öppnas
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
.\src\Client\Start-ToastClient.ps1 -ConfigPath <string> [-Once] [-PollSeconds <int>]
```

Klienten:

- registrerar aldrig dator/grupptillhörighet i SQL; gamla `ClientGroups`-inställningar ignoreras
- pollar den SELECT-baserade `dbo.usp_GetPendingToast` utan registrering, LastSeen-uppdatering, leases eller leveranskvittens
- visar meddelandet via AppDeployToolkit
- sparar `Read`, `ShowCount` och UTC-`NextShowUtc` som ett JSON-registervärde per meddelande under `HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState\<scope-hash>` i 64-bitars registervyn
- scopet omfattar SQL-server/port, databas och datornamn, **inte användar-SID**. Tillståndet delas av alla interaktiva användare på datorn och överlever användarbyten och omstarter. En användares kvittering undertrycker därför samma engångsmeddelande för övriga användare; repetitionernas räknare och nästa visning delas också. Borttagna registervärden eller en återskapad databas med återanvända meddelande-ID:n kan medföra att gamla meddelanden visas igen eller undertrycks; rensa scopet vid sådan databasåterställning
- `RepeatCount` inkluderar första kvitteringen; nästa visning schemaläggs från senaste lyckade kvittering. Timeout/fel förbrukar ingen repetition och försöks igen vid nästa pollning
- läser alla aktiva meddelanden för nuvarande grupptillhörighet, brådskande först, sedan MessageId. Lokalt kvitterade meddelanden kan inte blockera andra genom en TOP-20-gräns
- kontrollerar medlemskap, avbrott och utgångstid igen före varje prompt. En redan öppen prompt stängs inte automatiskt vid serveravbrott/utgång
- avbryter med fel om registerlagring misslyckas, även efter kvittering; tillstånd som inte kunde sparas kan visas igen vid nästa start. Renderings-/protokollfel varnas och lämnas olästa

En global mutex med explicit INTERACTIVE-behörighet serialiserar en pollnings-/visningsomgång per maskinscope över användarsessioner. Låset hålls medan prompten är öppen men släpps före pollningsvilan, även vid fel. En upptagen klient hoppar över omgången och försöker vid nästa pollning (`-Once` avslutas utan visning om låset är upptaget). En redan öppen prompt i en inaktiv session kan fördröja andra sessioner tills den stängs/timeout; samtidiga klienter garanteras inte rättvis fördelning av visningar. Klienter som startats före uppgraderingen ska stoppas först, även för att ta bort gamla mutexobjekt med tidigare behörigheter.

Logon-tasken registreras fortfarande **per användare för interaktiv UI**, inte för separat lässtatus, med interaktiv inloggning och utan administratörsrättigheter; distribuera per användare, inte som SYSTEM. Standardnamnet på tasken inkluderar användar-SID enbart för att undvika taskkollisioner på delade datorer.

### Migration från HKCU

Stoppa äldre klientversioner och kör HKLM-provisioneringen ovan innan de nya klienterna startas. Befintlig per-användarstatus under HKCU migreras **inte automatiskt**, slås inte ihop och läses inte av klienten. Fortfarande aktiva meddelanden kan därför visas på nytt en gång per dator (med eventuella delade repetitioner). Gamla HKCU-värden kan tas bort separat efter verifierad utrullning. Använd inte gamla och nya klienter parallellt.

### AD-import (endast administration)

`src/Server/Import-ToastADComputers.ps1 -ConfigPath <admin.psd1> -Tag <gruppnamn> [-Filter <AD-filter>] [-SearchBase <OU-DN>] [-WhatIf] [-Confirm]`

`Filter` använder `Get-ADComputer -Filter`-syntax (default `*`); utan SearchBase används AD:s standardsökbas. Förhandsgranska alltid urval med `-WhatIf`. Datorns `Name` (inte DNSHostName) lagras och ska matcha klientens `ClientName` (default datornamnet). Tag trimmas och valideras till 1–128 tecken, datornamn till 1–256. Parametriserade, transaktionella och idempotenta INSERT lägger till saknad grupp, dator och medlemskap utan dubbletter. Befintliga medlemskap tas inte bort och inaktiva datorer/grupper återaktiveras inte. Importen ändrar inga AD-objekt. Nyimporterade datorer får gruppens fortfarande aktiva, ej utgångna meddelanden även om de köades före importen.

### SQL-behörigheter

Installationen skapar `ToastClientReader` med EXECUTE endast på den läsande pollningsproceduren, nekar INSERT/UPDATE/DELETE samt EXECUTE på kö- och gamla rapporteringsprocedurer. Tilldela klientanvändare (eller en Windows-användargrupp) endast denna roll:

```sql
CREATE USER [EXAMPLE\ToastUsers] FOR LOGIN [EXAMPLE\ToastUsers];
ALTER ROLE ToastClientReader ADD MEMBER [EXAMPLE\ToastUsers];
```

Skapa login separat enligt lokal SQL-policy. Ta bort gamla skrivroller, db_owner, db_datawriter, breda EXECUTE/CONTROL-grants och motsvarande rättigheter via andra grupper/public; rollen återkallar inte redan existerande behörigheter. Ge aldrig klienter administratörskonfigurationen. AD-importens separata adminidentitet behöver SELECT/INSERT på ToastGroup, ToastClient och ToastClientGroup; avsändaren behöver EXECUTE på usp_QueueToastMessage. Inga nya klienter behöver SELECT direkt på tabeller. Datornamnet är ett urval, inte en autentiseringsgräns mellan klienter; en klientidentitet kan begära en annan registrerad dators meddelanden.

## SQL-skript

### Rekommenderat

- `sql/Install-BurntToast-SQLserver.sql`
  - skapar saknade bastabeller/index
  - behåller historiska delivery-tabeller men använder lokal repeat-/lässtatus
  - applicerar knapp-/display-mode-stöd
  - applicerar lokal tidsrapportering
  - normaliserar `DisplayMode` till `AppDeployToolkit` för `NULL`-värden och rader som fortfarande saknar leveranshistorik vid uppgradering
  - tar i befintliga databaser bort beroenden till de obsoleta bildkolumnerna (t.ex. `IX_ToastMessage_Polling`), tar bort själva kolumnerna, återskapar `IX_ToastMessage_Polling` utan bildkolumner och skapar om procedurerna utan bildparametrar. **Bilddata raderas permanent – ta backup först.** Skriptet kan köras om flera gånger.

### Legacy / stegvis uppgradering

- `sql/001-schema.sql`
- `sql/002-toast-design-repeat.sql`
- `sql/003-toast-button.sql`
- `sql/004-local-time-reporting.sql`
- `sql/005-read-only-clients.sql` **måste köras sist**, även vid uppgradering av redan installerade databaser. Den ersätter polling med SELECT, tar bort nya delivery-rader från köproceduren, spärrar gammal rapportering och installerar klientrollen. Kör inte 001–004 igen utan att avsluta med 005.

Gamla `ToastDelivery`-rader, `LastSeenUtc` och delivery-vyer/funktioner behålls enbart som historik; de uppdateras inte av nya klienter och får inte användas som aktuell leverans-/läsrapport. `usp_RecordToastDelivery` ger nu ett uttryckligt migreringsfel. Befintlig SQL-deliveryhistorik importeras inte till HKLM; vid övergång visas fortfarande aktiva meddelanden på nytt per dator. Sätt utgångstid/IsCancelled på gamla meddelanden före klientutrullning om det inte önskas. Uppgradera SQL före klienten och stoppa äldre klientversioner.

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
- läsande SQL-kontrakt, lokal registerstatus, repeat, timeout/fel och AD-import
