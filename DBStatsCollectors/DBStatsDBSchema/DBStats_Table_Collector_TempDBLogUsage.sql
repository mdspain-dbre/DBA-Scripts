/*
	Created by SEADATA\michael.dspain using dbatools Export-DbaScript for objects on dre-jumpbox at 01/15/2026 18:49:14
	See https://dbatools.io/Export-DbaScript for more information
*/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Collector].[TempDBLogUsage](
	[DataBaseName] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LogSizeMB] [decimal](38, 5) NULL,
	[LogPercentage] [decimal](38, 5) NULL,
	[LogSpaceUsedMB] [decimal](38, 5) NULL,
	[Status] [int] NULL,
	[Collection_Time] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO

