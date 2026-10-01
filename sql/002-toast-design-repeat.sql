SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ServerLocalTimeZone sysname = NULL;

BEGIN TRY
    EXEC sp_executesql
        N'SELECT @ResolvedTimeZone = CONVERT(sysname, CURRENT_TIMEZONE())',
        N'@ResolvedTimeZone sysname OUTPUT',
        @ResolvedTimeZone = @ServerLocalTimeZone OUTPUT;
END TRY
BEGIN CATCH
    SET @ServerLocalTimeZone = NULL;
END CATCH;

-- CURRENT_TIMEZONE() kan returnera ett lokalt visningsnamn, t.ex.
-- "(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna".
-- AT TIME ZONE kräver däremot ett giltigt SQL Server tidszonsnamn.
IF @ServerLocalTimeZone IS NOT NULL
BEGIN
    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.time_zone_info
        WHERE name = @ServerLocalTimeZone
    )
    BEGIN
        SET @ServerLocalTimeZone = NULL;
    END;
END;

-- Fallback: matcha giltig zon via aktuell UTC-offset och DST-status.
IF @ServerLocalTimeZone IS NULL
BEGIN
    SELECT TOP (1)
        @ServerLocalTimeZone = name
    FROM sys.time_zone_info
    WHERE current_utc_offset = DATENAME(TZOFFSET, SYSDATETIMEOFFSET())
    ORDER BY
        CASE WHEN is_currently_dst = 1 THEN 0 ELSE 1 END,
        name;
END;

-- Sista fallback om ingen zon kan bestämmas.
IF @ServerLocalTimeZone IS NULL
BEGIN
    SET @ServerLocalTimeZone = N'UTC';
END;

IF COL_LENGTH('dbo.ToastMessage', 'Subtitle') IS NULL
    ALTER TABLE dbo.ToastMessage ADD Subtitle nvarchar(200) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'Sound') IS NULL
    ALTER TABLE dbo.ToastMessage ADD Sound varchar(20) NULL;

IF COL_LENGTH('dbo.ToastMessage', 'IsUrgent') IS NULL
    ALTER TABLE dbo.ToastMessage ADD IsUrgent bit NOT NULL CONSTRAINT DF_ToastMessage_IsUrgent DEFAULT (0) WITH VALUES;

IF COL_LENGTH('dbo.ToastMessage', 'RepeatIntervalSeconds') IS NULL
    ALTER TABLE dbo.ToastMessage ADD RepeatIntervalSeconds int NULL;

IF COL_LENGTH('dbo.ToastMessage', 'RepeatCount') IS NULL
    ALTER TABLE dbo.ToastMessage ADD RepeatCount int NULL;

IF COL_LENGTH('dbo.ToastDelivery', 'NextShowUtc') IS NULL
    ALTER TABLE dbo.ToastDelivery ADD NextShowUtc datetime2(0) NOT NULL CONSTRAINT DF_ToastDelivery_NextShowUtc DEFAULT (SYSDATETIME()) WITH VALUES;
ELSE
BEGIN
    BEGIN TRY
        BEGIN TRAN;

        DECLARE @NextShowUtcDefaultConstraintName sysname;
        DECLARE @NextShowUtcDefaultDefinition nvarchar(max);

        SELECT
            @NextShowUtcDefaultConstraintName = dc.name,
            @NextShowUtcDefaultDefinition = dc.definition
        FROM sys.default_constraints dc
        INNER JOIN sys.columns c
            ON c.default_object_id = dc.object_id
        WHERE dc.parent_object_id = OBJECT_ID('dbo.ToastDelivery')
          AND c.name = 'NextShowUtc';

        IF @NextShowUtcDefaultDefinition LIKE '%SYSUTCDATETIME%'
        BEGIN
            IF @ServerLocalTimeZone IS NULL
                THROW 50013, 'Unable to resolve SQL Server local Windows time zone name for UTC-to-local timestamp migration.', 1;

            UPDATE dbo.ToastDelivery
            SET
                NextShowUtc = CAST(((NextShowUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0)),
                LeaseExpiresUtc = CASE
                    WHEN LeaseExpiresUtc IS NULL THEN NULL
                    ELSE CAST(((LeaseExpiresUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0))
                END
            WHERE NextShowUtc IS NOT NULL
               OR LeaseExpiresUtc IS NOT NULL;

            UPDATE dbo.ToastDelivery
            SET
                LastAttemptUtc = CASE
                    WHEN LastAttemptUtc IS NULL THEN NULL
                    ELSE CAST(((LastAttemptUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0))
                END,
                DeliveredUtc = CASE
                    WHEN DeliveredUtc IS NULL THEN NULL
                    ELSE CAST(((DeliveredUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0))
                END
            WHERE LastAttemptUtc IS NOT NULL
               OR DeliveredUtc IS NOT NULL;

            UPDATE dbo.ToastClient
            SET LastSeenUtc = CAST(((LastSeenUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0))
            WHERE LastSeenUtc IS NOT NULL;

            UPDATE dbo.ToastMessage
            SET
                CreatedUtc = CAST(((CreatedUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0)),
                ExpiresUtc = CASE
                    WHEN ExpiresUtc IS NULL THEN NULL
                    ELSE CAST(((ExpiresUtc AT TIME ZONE 'UTC') AT TIME ZONE @ServerLocalTimeZone) AS datetime2(0))
                END
            WHERE CreatedUtc IS NOT NULL
               OR ExpiresUtc IS NOT NULL;
        END;

        IF @NextShowUtcDefaultConstraintName IS NOT NULL
        BEGIN
            DECLARE @DropNextShowUtcDefaultConstraintSql nvarchar(max);
            SET @DropNextShowUtcDefaultConstraintSql =
                N'ALTER TABLE dbo.ToastDelivery DROP CONSTRAINT '
                + QUOTENAME(@NextShowUtcDefaultConstraintName)
                + N';';

            EXEC sp_executesql @DropNextShowUtcDefaultConstraintSql;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM sys.default_constraints dc
            INNER JOIN sys.columns c
                ON c.default_object_id = dc.object_id
            WHERE dc.parent_object_id = OBJECT_ID('dbo.ToastDelivery')
              AND c.name = 'NextShowUtc'
        )
            ALTER TABLE dbo.ToastDelivery
                ADD CONSTRAINT DF_ToastDelivery_NextShowUtc DEFAULT (SYSDATETIME()) FOR NextShowUtc;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK;

        THROW;
    END CATCH
END;

IF COL_LENGTH('dbo.ToastDelivery', 'ShowCount') IS NULL
    ALTER TABLE dbo.ToastDelivery ADD ShowCount int NOT NULL CONSTRAINT DF_ToastDelivery_ShowCount DEFAULT (0) WITH VALUES;

IF COL_LENGTH('dbo.ToastDelivery', 'LeaseId') IS NULL
    ALTER TABLE dbo.ToastDelivery ADD LeaseId uniqueidentifier NULL;

IF COL_LENGTH('dbo.ToastDelivery', 'LeaseExpiresUtc') IS NULL
    ALTER TABLE dbo.ToastDelivery ADD LeaseExpiresUtc datetime2(0) NULL;

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_ToastDelivery_Status' AND parent_object_id = OBJECT_ID('dbo.ToastDelivery'))
    ALTER TABLE dbo.ToastDelivery DROP CONSTRAINT CK_ToastDelivery_Status;

ALTER TABLE dbo.ToastDelivery
    ADD CONSTRAINT CK_ToastDelivery_Status CHECK (Status IN ('Pending','InProgress','Delivered','Failed','Cancelled'));

IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ToastDelivery') AND name = 'IX_ToastDelivery_Client_Status')
    DROP INDEX IX_ToastDelivery_Client_Status ON dbo.ToastDelivery;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ToastDelivery') AND name = 'IX_ToastDelivery_Client_Status')
    CREATE INDEX IX_ToastDelivery_Client_Status ON dbo.ToastDelivery(ClientId, Status, NextShowUtc, LeaseExpiresUtc, MessageId);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ToastMessage') AND name = 'IX_ToastMessage_Polling')
    CREATE INDEX IX_ToastMessage_Polling
        ON dbo.ToastMessage(MessageId)
        INCLUDE (IsCancelled, ExpiresUtc, Title, Body, Sound, IsUrgent, RepeatIntervalSeconds, RepeatCount);

GO

CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage
    @GroupName nvarchar(128),
    @Title nvarchar(200),
    @Body nvarchar(4000),
    @ExpiresUtc datetime2(0) = NULL,
    @Sound varchar(20) = NULL,
    @IsUrgent bit = 0,
    @RepeatIntervalSeconds int = NULL,
    @RepeatCount int = NULL,
    @Subtitle nvarchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF (@RepeatIntervalSeconds IS NULL AND @RepeatCount IS NOT NULL) OR (@RepeatIntervalSeconds IS NOT NULL AND @RepeatCount IS NULL)
        THROW 50002, 'RepeatIntervalSeconds and RepeatCount must both be provided for repeating messages.', 1;

    IF @RepeatIntervalSeconds IS NOT NULL AND @RepeatIntervalSeconds < 1
        THROW 50003, 'RepeatIntervalSeconds must be greater than zero.', 1;

    IF @RepeatCount IS NOT NULL AND @RepeatCount < 2
        THROW 50004, 'RepeatCount must be 2 or greater because it includes the first display.', 1;

    DECLARE @GroupId int = (SELECT GroupId FROM dbo.ToastGroup WHERE GroupName = @GroupName AND IsActive = 1);
    IF @GroupId IS NULL THROW 50001, 'Active toast group was not found.', 1;

    BEGIN TRAN;

    INSERT dbo.ToastMessage(
        GroupId,
        Title,
        Subtitle,
        Body,
        ExpiresUtc,
        Sound,
        IsUrgent,
        RepeatIntervalSeconds,
        RepeatCount
    )
    VALUES(
        @GroupId,
        @Title,
        NULLIF(LTRIM(RTRIM(@Subtitle)), ''),
        @Body,
        @ExpiresUtc,
        NULLIF(@Sound, ''),
        ISNULL(@IsUrgent, 0),
        @RepeatIntervalSeconds,
        @RepeatCount
    );

    DECLARE @MessageId bigint = SCOPE_IDENTITY();

    INSERT dbo.ToastDelivery(MessageId, ClientId)
        SELECT @MessageId, ClientId
        FROM dbo.ToastClientGroup
        WHERE GroupId = @GroupId;

    COMMIT;

    SELECT @MessageId AS MessageId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPendingToast
    @ComputerName nvarchar(256)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ClientId int = (SELECT ClientId FROM dbo.ToastClient WHERE ComputerName = @ComputerName AND IsActive = 1);
    IF @ClientId IS NULL RETURN;

    DECLARE @Now datetime2(0) = SYSDATETIME();
    DECLARE @LeaseSeconds int = 120;

    UPDATE dbo.ToastClient
    SET LastSeenUtc = @Now
    WHERE ClientId = @ClientId;

    ;WITH DueMessages AS (
        SELECT TOP (20) d.ClientId, d.MessageId
        FROM dbo.ToastDelivery d WITH (UPDLOCK, READPAST, ROWLOCK)
        INNER JOIN dbo.ToastMessage m ON m.MessageId = d.MessageId
        WHERE d.ClientId = @ClientId
          AND m.IsCancelled = 0
          AND (m.ExpiresUtc IS NULL OR m.ExpiresUtc > @Now)
          AND d.NextShowUtc <= @Now
          AND (
                d.Status = 'Pending'
                OR (d.Status = 'InProgress' AND d.LeaseExpiresUtc IS NOT NULL AND d.LeaseExpiresUtc <= @Now)
              )
        ORDER BY d.MessageId
    )
    UPDATE d
    SET Status = 'InProgress',
        LeaseId = NEWID(),
        LeaseExpiresUtc = DATEADD(second, @LeaseSeconds, @Now),
        ErrorMessage = NULL
    OUTPUT inserted.MessageId,
           inserted.LeaseId,
           m.Title,
           m.Subtitle,
           m.Body,
           m.Sound,
           m.IsUrgent,
           m.RepeatIntervalSeconds,
           m.RepeatCount,
           m.ExpiresUtc,
           inserted.ShowCount
    FROM dbo.ToastDelivery d
    INNER JOIN DueMessages x ON x.ClientId = d.ClientId AND x.MessageId = d.MessageId
    INNER JOIN dbo.ToastMessage m ON m.MessageId = d.MessageId
    WHERE d.ClientId = @ClientId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RecordToastDelivery
    @ComputerName nvarchar(256),
    @MessageId bigint,
    @Status varchar(20),
    @ErrorMessage nvarchar(2000) = NULL,
    @LeaseId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ClientId int = (SELECT ClientId FROM dbo.ToastClient WHERE ComputerName = @ComputerName);
    IF @ClientId IS NULL RETURN;
    IF @LeaseId IS NULL THROW 50005, 'LeaseId is required when recording a toast delivery.', 1;
    IF @Status NOT IN ('Delivered','Failed','Cancelled') THROW 50007, 'Status must be Delivered, Failed, or Cancelled.', 1;

    DECLARE @Now datetime2(0) = SYSDATETIME();
    DECLARE @RepeatIntervalSeconds int;
    DECLARE @RepeatCount int;
    DECLARE @ExpiresUtc datetime2(0);
    DECLARE @ShowCount int;
    DECLARE @FailureShowCount int;
    DECLARE @FailureNextShowUtc datetime2(0);
    DECLARE @FailureStatus varchar(20);

    SELECT
        @RepeatIntervalSeconds = m.RepeatIntervalSeconds,
        @RepeatCount = m.RepeatCount,
        @ExpiresUtc = m.ExpiresUtc,
        @ShowCount = d.ShowCount
    FROM dbo.ToastDelivery d
    INNER JOIN dbo.ToastMessage m ON m.MessageId = d.MessageId
    WHERE d.MessageId = @MessageId
      AND d.ClientId = @ClientId
      AND d.LeaseId = @LeaseId;

    IF @ShowCount IS NULL THROW 50006, 'Toast delivery lease was not found or is no longer active for this client.', 1;

    IF @Status = 'Delivered'
    BEGIN
        DECLARE @NewShowCount int = @ShowCount + 1;
        DECLARE @NextShowUtc datetime2(0) = NULL;

        IF @RepeatIntervalSeconds IS NOT NULL AND @RepeatCount IS NOT NULL AND @NewShowCount < @RepeatCount
        BEGIN
            SET @NextShowUtc = DATEADD(second, @RepeatIntervalSeconds, @Now);

            IF @ExpiresUtc IS NOT NULL AND @NextShowUtc >= @ExpiresUtc
                SET @NextShowUtc = NULL;
        END;

        UPDATE dbo.ToastDelivery
        SET Status = CASE WHEN @NextShowUtc IS NULL THEN 'Delivered' ELSE 'Pending' END,
            Attempts = Attempts + 1,
            ShowCount = @NewShowCount,
            LastAttemptUtc = @Now,
            DeliveredUtc = CASE WHEN @NextShowUtc IS NULL THEN @Now ELSE NULL END,
            NextShowUtc = CASE WHEN @NextShowUtc IS NULL THEN @Now ELSE @NextShowUtc END,
            ErrorMessage = NULL,
            LeaseId = NULL,
            LeaseExpiresUtc = NULL
        WHERE MessageId = @MessageId
          AND ClientId = @ClientId
          AND LeaseId = @LeaseId;

        IF @@ROWCOUNT = 0 THROW 50006, 'Toast delivery lease was not found or is no longer active for this client.', 1;

        RETURN;
    END;

    SET @FailureStatus = @Status;
    SET @FailureNextShowUtc = @Now;
    SET @FailureShowCount = @ShowCount;

    IF @Status = 'Failed'
    BEGIN
        SET @FailureShowCount = @ShowCount + 1;

        IF @RepeatIntervalSeconds IS NOT NULL AND @RepeatCount IS NOT NULL AND @FailureShowCount < @RepeatCount
        BEGIN
            SET @FailureNextShowUtc = DATEADD(second, @RepeatIntervalSeconds, @Now);

            IF @ExpiresUtc IS NULL OR @FailureNextShowUtc < @ExpiresUtc
                SET @FailureStatus = 'Pending';
            ELSE
                SET @FailureNextShowUtc = @Now;
        END;
    END;

    UPDATE dbo.ToastDelivery
    SET Status = @FailureStatus,
        Attempts = Attempts + 1,
        ShowCount = @FailureShowCount,
        LastAttemptUtc = @Now,
        DeliveredUtc = NULL,
        NextShowUtc = @FailureNextShowUtc,
        ErrorMessage = @ErrorMessage,
        LeaseId = NULL,
        LeaseExpiresUtc = NULL
    WHERE MessageId = @MessageId
      AND ClientId = @ClientId
      AND LeaseId = @LeaseId;

    IF @@ROWCOUNT = 0 THROW 50006, 'Toast delivery lease was not found or is no longer active for this client.', 1;
END;
GO