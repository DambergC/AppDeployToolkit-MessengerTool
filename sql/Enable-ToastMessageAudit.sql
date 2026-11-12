/*
Add server message auditing to an existing installation, SQL Server 2016+.
Run as DBA in the application database after a verified backup.
Requires the current ToastMessage schema and ToastMessageAdmin role.
No historical events are backfilled. Refuses existing audit objects.
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
        OR DATABASE_PRINCIPAL_ID(N'ToastMessageAdmin') IS NULL
        THROW 50001, 'An existing Toast database with the current message schema and admin role is required.', 1;
    IF OBJECT_ID(N'dbo.ToastMessageAudit') IS NOT NULL
        OR OBJECT_ID(N'dbo.tr_ToastMessage_Audit') IS NOT NULL
        THROW 50002, 'Message audit objects already exist. No changes were made.', 1;

    EXEC sys.sp_executesql N'
CREATE TABLE dbo.ToastMessageAudit (
    AuditId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ToastMessageAudit PRIMARY KEY,
    EventType varchar(6) NOT NULL CONSTRAINT CK_ToastMessageAudit_EventType CHECK (EventType IN (''INSERT'', ''UPDATE'', ''DELETE'')),
    EventUtc datetime2(7) NOT NULL CONSTRAINT DF_ToastMessageAudit_EventUtc DEFAULT (SYSUTCDATETIME()),
    SqlUser nvarchar(128) NOT NULL,
    SqlServer nvarchar(128) NOT NULL,
    SenderHost nvarchar(128) NULL,
    MessageId bigint NOT NULL,
    GroupId int NOT NULL,
    GroupName nvarchar(128) NOT NULL,
    Title nvarchar(200) NOT NULL,
    Subtitle nvarchar(200) NULL,
    Body nvarchar(4000) NOT NULL,
    AcknowledgeButtonText nvarchar(200) NOT NULL,
    CreatedUtc datetime2(7) NOT NULL,
    ExpiresUtc datetime2(7) NOT NULL,
    RepeatIntervalSeconds int NULL,
    RepeatCount int NULL,
    IsCancelled bit NOT NULL
);
CREATE INDEX IX_ToastMessageAudit_Message ON dbo.ToastMessageAudit(MessageId, AuditId);
';

    EXEC sys.sp_executesql N'
CREATE TRIGGER dbo.tr_ToastMessage_Audit ON dbo.ToastMessage
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.ToastMessageAudit (
        EventType, SqlUser, SqlServer, SenderHost, MessageId, GroupId, GroupName,
        Title, Subtitle, Body, AcknowledgeButtonText, CreatedUtc, ExpiresUtc,
        RepeatIntervalSeconds, RepeatCount, IsCancelled
    )
    SELECT CASE WHEN d.MessageId IS NULL THEN ''INSERT'' ELSE ''UPDATE'' END,
        ORIGINAL_LOGIN(), CONVERT(nvarchar(128), SERVERPROPERTY(''ServerName'')), HOST_NAME(),
        i.MessageId, i.GroupId, g.GroupName, i.Title, i.Subtitle, i.Body,
        i.AcknowledgeButtonText, i.CreatedUtc, i.ExpiresUtc,
        i.RepeatIntervalSeconds, i.RepeatCount, i.IsCancelled
    FROM inserted AS i
    LEFT JOIN deleted AS d ON d.MessageId = i.MessageId
    INNER JOIN dbo.ToastGroup AS g ON g.GroupId = i.GroupId
    UNION ALL
    SELECT ''DELETE'',
        ORIGINAL_LOGIN(), CONVERT(nvarchar(128), SERVERPROPERTY(''ServerName'')), HOST_NAME(),
        d.MessageId, d.GroupId, g.GroupName, d.Title, d.Subtitle, d.Body,
        d.AcknowledgeButtonText, d.CreatedUtc, d.ExpiresUtc,
        d.RepeatIntervalSeconds, d.RepeatCount, d.IsCancelled
    FROM deleted AS d
    INNER JOIN dbo.ToastGroup AS g ON g.GroupId = d.GroupId
    WHERE NOT EXISTS (SELECT 1 FROM inserted AS i WHERE i.MessageId = d.MessageId);
END;
';

    GRANT SELECT ON OBJECT::dbo.ToastMessageAudit TO ToastMessageAdmin;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
