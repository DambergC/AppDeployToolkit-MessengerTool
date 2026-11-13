/*
Add Windows-user attribution to an existing message audit installation.
Run as DBA in the application database after a verified backup.
Run the entire file as one batch (no GO separators).
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb')
        THROW 50000, 'Select the application database, not a system database.', 1;
    IF OBJECT_ID(N'dbo.ToastMessage', N'U') IS NULL
        OR OBJECT_ID(N'dbo.ToastGroup', N'U') IS NULL
        OR OBJECT_ID(N'dbo.ToastMessageAudit', N'U') IS NULL
        OR OBJECT_ID(N'dbo.tr_ToastMessage_Audit', N'TR') IS NULL
        THROW 50001, 'An existing Toast database with message audit installed is required.', 1;

    IF COL_LENGTH(N'dbo.ToastMessageAudit', N'DomainUser') IS NULL
        ALTER TABLE dbo.ToastMessageAudit ADD DomainUser nvarchar(256) NULL;

    EXEC sys.sp_executesql N'
ALTER TRIGGER dbo.tr_ToastMessage_Audit ON dbo.ToastMessage
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.ToastMessageAudit (
        EventType, SqlUser, DomainUser, SqlServer, SenderHost, MessageId, GroupId, GroupName,
        Title, Subtitle, Body, AcknowledgeButtonText, CreatedUtc, ExpiresUtc,
        RepeatIntervalSeconds, RepeatCount, IsCancelled
    )
    SELECT CASE WHEN d.MessageId IS NULL THEN ''INSERT'' ELSE ''UPDATE'' END,
        ORIGINAL_LOGIN(), CONVERT(nvarchar(256), SESSION_CONTEXT(N''DomainUser'')),
        CONVERT(nvarchar(128), SERVERPROPERTY(''ServerName'')), HOST_NAME(),
        i.MessageId, i.GroupId, g.GroupName, i.Title, i.Subtitle, i.Body,
        i.AcknowledgeButtonText, i.CreatedUtc, i.ExpiresUtc,
        i.RepeatIntervalSeconds, i.RepeatCount, i.IsCancelled
    FROM inserted AS i
    LEFT JOIN deleted AS d ON d.MessageId = i.MessageId
    INNER JOIN dbo.ToastGroup AS g ON g.GroupId = i.GroupId
    UNION ALL
    SELECT ''DELETE'',
        ORIGINAL_LOGIN(), CONVERT(nvarchar(256), SESSION_CONTEXT(N''DomainUser'')),
        CONVERT(nvarchar(128), SERVERPROPERTY(''ServerName'')), HOST_NAME(),
        d.MessageId, d.GroupId, g.GroupName, d.Title, d.Subtitle, d.Body,
        d.AcknowledgeButtonText, d.CreatedUtc, d.ExpiresUtc,
        d.RepeatIntervalSeconds, d.RepeatCount, d.IsCancelled
    FROM deleted AS d
    INNER JOIN dbo.ToastGroup AS g ON g.GroupId = d.GroupId
    WHERE NOT EXISTS (SELECT 1 FROM inserted AS i WHERE i.MessageId = d.MessageId);
END;
';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
