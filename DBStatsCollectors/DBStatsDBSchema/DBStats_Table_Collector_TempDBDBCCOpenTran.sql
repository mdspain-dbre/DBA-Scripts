/*
	Created by SEADATA\michael.dspain using dbatools Export-DbaScript for objects on dre-jumpbox at 01/15/2026 18:49:14
	See https://dbatools.io/Export-DbaScript for more information
*/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Collector].[TempDBDBCCOpenTran](
	[ComputerName] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[InstanceName] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SqlInstance] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Database] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DatabaseId] [int] NULL,
	[Cmd] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Output] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Field] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Data] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CollectionTime] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO

