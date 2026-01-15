/*
	Created by SEADATA\michael.dspain using dbatools Export-DbaScript for objects on dre-jumpbox at 01/15/2026 18:49:14
	See https://dbatools.io/Export-DbaScript for more information
*/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Collector].[OpenTranInputBuffer](
	[OLDACT_SPID] [int] NULL,
	[OLDACT_UID] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OLDACT_NAME] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OLDACT_RECOVERYUNITID] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OLDACT_LSN] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OLDACT_STARTTIME] [datetime2](7) NULL,
	[OLDACT_SID] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[EventType] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Parameters] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[EventInfo] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RowError] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RowState] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Table] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ItemArray] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[HasErrors] [bit] NULL,
	[CollectionTime] [datetime2](7) NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO

