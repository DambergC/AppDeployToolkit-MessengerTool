# Underhåll av databasen

Kör frågorna i SQL Server Management Studio (SSMS) mot den befintliga
applikationsdatabasen. Kontrollera vald server och databas innan du börjar.
Kör ett kodblock i taget, inte hela dokumentet som ett skript.

En **device** är en dator i `dbo.ToastClient`. En **tagg** är ett gruppnamn
(`dbo.ToastGroup.GroupName`), med kopplingar i `dbo.ToastClientGroup`.
En dator utan tagg saknar helt gruppkopplingar; en koppling till en inaktiv
grupp räknas fortfarande som en tagg.

Ta en verifierad backup före borttagning. Pausa AD-importer och annan
administration under rensningen så att urvalet inte ändras mellan granskning
och borttagning. Borttagna datorer kan skapas igen vid nästa AD-import.

Använd ett administrativt databaskonto, inte klientkontot. Frågorna kräver
`SELECT` på de tabeller som läses och `DELETE` på den tabell som rensas.
Rollen `ToastMessageAdmin` har normalt rättigheter för datorrensningen, men
inte `SELECT`/`DELETE` på `dbo.ToastMessage`; en DBA behöver ge underhållskontot
dessa avgränsade rättigheter om de saknas. Ge inte klientrollen fler rättigheter
och använd inte `db_owner` enbart för detta underhåll.

## Meddelandemallar

`dbo.ToastMessageTemplate` skapas vid förstagångsinstallationen och hanteras
med rollen `ToastMessageAdmin`. Varje mall har ett `TemplateId`, obligatoriska
`Title` (högst 200 tecken) och `Body` (högst 4000 tecken) samt valfri `Subtitle`
(högst 200 tecken). Mallens `Name` (högst 200 tecken) och `Description`
(högst 4000 tecken) är valfria och kan vara `NULL`. Titel och brödtext får inte
vara tomma eller enbart blanksteg.
Mallarna är fristående; att spara eller ta bort en mall påverkar inte köade
meddelanden.

### Lägg till kolumner i en befintlig databas

För en befintlig installation där `dbo.ToastMessageTemplate` finns utan
kolumnerna `Name` och `Description` ska en DBA ta en verifierad backup och
köra följande en gång i den valda applikationsdatabasen. Befintliga mallar
behålls och får `NULL` i de nya kolumnerna. Kör inte om installationsskriptet.

```sql
ALTER TABLE dbo.ToastMessageTemplate
ADD Name nvarchar(200) NULL, Description nvarchar(4000) NULL;
```

### Lista mallar

```sql
SELECT TemplateId, Name, Description, Title, Subtitle, Body
FROM dbo.ToastMessageTemplate
ORDER BY TemplateId;
```

### Spara en mall

Låt `@TemplateId` vara `NULL` för att skapa en ny mall. Ange ett befintligt
`TemplateId` från listningen för att uppdatera en mall. Resultatet innehåller
den sparade mallen och dess ID. Ersätt exempeltexterna före körning; `Name`,
`Description` och `Subtitle` kan sättas till `NULL`. Använd SQL-parametrar om
frågan anropas från ett program.

```sql
DECLARE @TemplateId int = NULL;
DECLARE @Name nvarchar(200) = N'Planerat underhåll';
DECLARE @Description nvarchar(4000) = N'Mall för information om planerat underhåll.';
DECLARE @Title nvarchar(200) = N'Planerat underhåll';
DECLARE @Subtitle nvarchar(200) = N'Information från IT';
DECLARE @Body nvarchar(4000) = N'Spara ditt arbete innan underhållet börjar.';

IF @TemplateId IS NULL
BEGIN
    INSERT dbo.ToastMessageTemplate (Name, Description, Title, Subtitle, Body)
    OUTPUT inserted.TemplateId, inserted.Name, inserted.Description, inserted.Title, inserted.Subtitle, inserted.Body
    VALUES (@Name, @Description, @Title, @Subtitle, @Body);
END
ELSE
BEGIN
    UPDATE dbo.ToastMessageTemplate
    SET Name = @Name, Description = @Description, Title = @Title, Subtitle = @Subtitle, Body = @Body
    OUTPUT inserted.TemplateId, inserted.Name, inserted.Description, inserted.Title, inserted.Subtitle, inserted.Body
    WHERE TemplateId = @TemplateId;

    IF @@ROWCOUNT = 0
        THROW 50013, 'Message template was not found.', 1;
END;
```

### Ta bort en mall

Ange valt `TemplateId` från listningen. Borttagningen är permanent och
returnerar den borttagna mallen. `NULL` tar inte bort något och ger ett fel.

```sql
DECLARE @TemplateId int = NULL; -- Ersätt NULL med valt ID.

DELETE FROM dbo.ToastMessageTemplate
OUTPUT deleted.TemplateId, deleted.Name, deleted.Description, deleted.Title, deleted.Subtitle, deleted.Body
WHERE TemplateId = @TemplateId;

IF @@ROWCOUNT = 0
    THROW 50013, 'Message template was not found.', 1;
```

## Lista devices utan tag

Visar både aktiva och inaktiva datorer som saknar gruppkopplingar.

```sql
SELECT c.ClientId, c.ComputerName, c.IsActive, c.CreatedUtc
FROM dbo.ToastClient AS c
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.ToastClientGroup AS cg
    WHERE cg.ClientId = c.ClientId
)
ORDER BY c.ComputerName;
```

## Ta bort devices utan tag

Standardläget visar endast vilka datorer som matchar. Granska resultatet och
ändra sedan `@Execute` till `1` för att köra borttagningen. Alla datorer som
saknar tagg vid borttagningstillfället tas bort, oavsett `IsActive`.
Grupper, gruppkopplingar och meddelanden ändras inte.

```sql
SET XACT_ABORT ON;
DECLARE @Execute bit = 0;

SELECT c.ClientId, c.ComputerName, c.IsActive, c.CreatedUtc
FROM dbo.ToastClient AS c
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.ToastClientGroup AS cg
    WHERE cg.ClientId = c.ClientId
)
ORDER BY c.ComputerName;

IF @Execute = 1
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE c
        FROM dbo.ToastClient AS c
        WHERE NOT EXISTS (
            SELECT 1
            FROM dbo.ToastClientGroup AS cg
            WHERE cg.ClientId = c.ClientId
        );

        SELECT @@ROWCOUNT AS DeletedDevices;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
```

## Lista meddelanden

Visar alla meddelanden, även utgångna och avbrutna, med tagg och `MessageId`
för att kunna välja vilka som ska tas bort. Tidsstämplarna är i UTC.

```sql
SELECT m.MessageId, g.GroupName AS Tag,
       m.Title, m.Subtitle, m.Body, m.AcknowledgeButtonText,
       m.CreatedUtc, m.ExpiresUtc, m.IsCancelled,
       m.RepeatIntervalSeconds, m.RepeatCount
FROM dbo.ToastMessage AS m
INNER JOIN dbo.ToastGroup AS g ON g.GroupId = m.GroupId
ORDER BY m.MessageId DESC;
```

## Ta bort valda meddelanden

Ange de `MessageId` du vill ta bort i `@MessageIds` enligt den kommenterade
exempelraden. Urvalet är tomt från början och `@Execute = 0` ger endast en
förhandsgranskning. Kör hela blocket med dina ID:n, kontrollera resultatet och
kör sedan blocket igen med `@Execute = 1`.

Borttagningen är permanent och gäller bara angivna ID:n, även om meddelandena
fortfarande är giltiga. Den hindrar framtida hämtning av dessa meddelanden,
men stänger inte dialoger som redan visas och rensar inte klienternas lokala
lässtatus i HKLM.

```sql
SET XACT_ABORT ON;
DECLARE @Execute bit = 0;
DECLARE @MessageIds TABLE (MessageId bigint NOT NULL PRIMARY KEY);

-- Ersätt med valda ID:n och avkommentera:
-- INSERT INTO @MessageIds (MessageId) VALUES (123), (456);

SELECT m.MessageId, g.GroupName AS Tag, m.Title, m.Body,
       m.CreatedUtc, m.ExpiresUtc, m.IsCancelled
FROM dbo.ToastMessage AS m
INNER JOIN dbo.ToastGroup AS g ON g.GroupId = m.GroupId
INNER JOIN @MessageIds AS selected ON selected.MessageId = m.MessageId
ORDER BY m.MessageId;

IF @Execute = 1
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE m
        FROM dbo.ToastMessage AS m
        INNER JOIN @MessageIds AS selected ON selected.MessageId = m.MessageId;

        SELECT @@ROWCOUNT AS DeletedMessages;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
```

## Lista devices med vald tag

Byt `IT-TEST` mot önskat gruppnamn. Frågan visar både aktiva och inaktiva
datorer samt om gruppen är aktiv.

```sql
DECLARE @Tag nvarchar(128) = N'IT-TEST';

SELECT c.ClientId, c.ComputerName, c.IsActive AS DeviceIsActive,
       c.CreatedUtc, g.GroupName AS Tag, g.IsActive AS TagIsActive
FROM dbo.ToastClient AS c
INNER JOIN dbo.ToastClientGroup AS cg ON cg.ClientId = c.ClientId
INNER JOIN dbo.ToastGroup AS g ON g.GroupId = cg.GroupId
WHERE g.GroupName = @Tag
ORDER BY c.ComputerName;
```
