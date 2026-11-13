/*
Integration checks: run with sqlcmd -b in a disposable application database
after Install-ToastDatabase.sql, or after Enable-ToastMessageAudit.sql on the
previous baseline. Requires DBA permissions. Fixtures are rolled back.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;
    DECLARE @StartedUtc datetime2(7) = SYSUTCDATETIME();
    DECLARE @GroupName nvarchar(128) = N'Audit-test-' + CONVERT(nvarchar(36), NEWID());
    INSERT dbo.ToastGroup (GroupName) VALUES (@GroupName);
    DECLARE @GroupId int = CONVERT(int, SCOPE_IDENTITY());

    CREATE USER ToastAuditTestAdmin WITHOUT LOGIN;
    ALTER ROLE ToastMessageAdmin ADD MEMBER ToastAuditTestAdmin;
    DECLARE @Queued TABLE (MessageId bigint);
    EXEC sys.sp_set_session_context @key = N'DomainUser', @value = N'EXAMPLE\ToastAuditTestAdmin';
    EXECUTE AS USER = 'ToastAuditTestAdmin';
    INSERT @Queued
    EXEC dbo.usp_QueueToastMessage @GroupName = @GroupName,
        @Title = N'Queue title', @Subtitle = N'Subtitle', @Body = N'Queue body',
        @AcknowledgeButtonText = N'Close', @ActiveDuration = 2, @DurationUnit = 'Hours',
        @RepeatIntervalSeconds = 60, @RepeatCount = 3;
    SELECT AuditId FROM dbo.ToastMessageAudit WHERE GroupId = @GroupId;
    IF HAS_PERMS_BY_NAME(N'dbo.ToastMessageAudit', N'OBJECT', N'INSERT') = 1
        OR HAS_PERMS_BY_NAME(N'dbo.ToastMessageAudit', N'OBJECT', N'UPDATE') = 1
        OR HAS_PERMS_BY_NAME(N'dbo.ToastMessageAudit', N'OBJECT', N'DELETE') = 1
        THROW 51000, 'Admins must not be granted audit write permissions.', 1;
    REVERT;
    EXEC sys.sp_set_session_context @key = N'DomainUser', @value = NULL;
    DECLARE @MessageId bigint = (SELECT MessageId FROM @Queued);
    IF (SELECT COUNT(*) FROM dbo.ToastMessageAudit WHERE MessageId = @MessageId) <> 1
        THROW 51001, 'Queueing must create exactly one audit event for the returned MessageId.', 1;
    IF NOT EXISTS (
        SELECT 1 FROM dbo.ToastMessageAudit
        WHERE MessageId = @MessageId AND EventType = 'INSERT'
          AND EventUtc BETWEEN @StartedUtc AND SYSUTCDATETIME()
          AND SqlUser = ORIGINAL_LOGIN()
          AND DomainUser = N'EXAMPLE\ToastAuditTestAdmin'
          AND SqlServer = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName'))
          AND (SenderHost = HOST_NAME() OR (SenderHost IS NULL AND HOST_NAME() IS NULL))
          AND GroupId = @GroupId AND GroupName = @GroupName
          AND Title = N'Queue title' AND Subtitle = N'Subtitle' AND Body = N'Queue body'
          AND AcknowledgeButtonText = N'Close' AND RepeatIntervalSeconds = 60
          AND RepeatCount = 3 AND IsCancelled = 0
          AND ExpiresUtc = DATEADD(HOUR, 2, CreatedUtc)
    )
        THROW 51002, 'Queue audit must snapshot message details, UTC time, identity, and server.', 1;

    INSERT dbo.ToastMessage (GroupId, Title, Body, ExpiresUtc)
    VALUES (@GroupId, N'Bulk one', N'Body one', DATEADD(DAY, 1, SYSUTCDATETIME())),
           (@GroupId, N'Bulk two', N'Body two', DATEADD(DAY, 1, SYSUTCDATETIME()));
    IF (SELECT COUNT(*) FROM dbo.ToastMessageAudit WHERE GroupId = @GroupId AND EventType = 'INSERT') <> 3
        THROW 51003, 'Multi-row inserts must log every message.', 1;

    UPDATE dbo.ToastMessage SET IsCancelled = 1, Body = N'Updated body' WHERE GroupId = @GroupId;
    IF (SELECT COUNT(*) FROM dbo.ToastMessageAudit
        WHERE GroupId = @GroupId AND EventType = 'UPDATE' AND IsCancelled = 1 AND Body = N'Updated body') <> 3
        THROW 51004, 'Multi-row updates must snapshot updated message values.', 1;
    DELETE dbo.ToastMessage WHERE GroupId = @GroupId;
    DELETE dbo.ToastGroup WHERE GroupId = @GroupId;
    IF (SELECT COUNT(*) FROM dbo.ToastMessageAudit
        WHERE GroupId = @GroupId AND GroupName = @GroupName AND EventType = 'DELETE' AND Body = N'Updated body') <> 3
        THROW 51005, 'Audit history must survive message and group deletion.', 1;

    SAVE TRANSACTION AuditRollback;
    INSERT dbo.ToastGroup (GroupName) VALUES (@GroupName);
    SET @GroupId = CONVERT(int, SCOPE_IDENTITY());
    INSERT dbo.ToastMessage (GroupId, Title, Body, ExpiresUtc)
    VALUES (@GroupId, N'Rollback', N'Rollback body', DATEADD(DAY, 1, SYSUTCDATETIME()));
    SET @MessageId = CONVERT(bigint, SCOPE_IDENTITY());
    ROLLBACK TRANSACTION AuditRollback;
    IF EXISTS (SELECT 1 FROM dbo.ToastMessageAudit WHERE MessageId = @MessageId)
        THROW 51006, 'Rolled-back handling must not leave a success audit event.', 1;

    CREATE USER ToastAuditTestClient WITHOUT LOGIN;
    ALTER ROLE ToastClientReader ADD MEMBER ToastAuditTestClient;
    EXECUTE AS USER = 'ToastAuditTestClient';
    IF HAS_PERMS_BY_NAME(N'dbo.ToastMessageAudit', N'OBJECT', N'SELECT') = 1
        OR HAS_PERMS_BY_NAME(N'dbo.ToastMessageAudit', N'OBJECT', N'INSERT') = 1
        OR HAS_PERMS_BY_NAME(N'dbo.ToastMessageAudit', N'OBJECT', N'UPDATE') = 1
        OR HAS_PERMS_BY_NAME(N'dbo.ToastMessageAudit', N'OBJECT', N'DELETE') = 1
        THROW 51007, 'Client roles must not have access to server audit data.', 1;
    REVERT;
    ROLLBACK TRANSACTION;
    PRINT 'ToastMessageAudit integration checks passed.';
END TRY
BEGIN CATCH
    IF USER_NAME() IN (N'ToastAuditTestAdmin', N'ToastAuditTestClient') REVERT;
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
