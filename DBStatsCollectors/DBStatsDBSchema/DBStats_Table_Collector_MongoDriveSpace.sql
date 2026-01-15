/*
	Created by SEADATA\michael.dspain using dbatools Export-DbaScript for objects on dre-jumpbox at 01/15/2026 18:49:13
	See https://dbatools.io/Export-DbaScript for more information
*/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Collector].[MongoDriveSpace](
	[serverID] [int] NOT NULL,
	[filesystem] [varchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[size] [varchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Used] [varchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Available] [varchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Used_Percentage] [varchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Mount] [varchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[CollectionTime] [datetime] NOT NULL
) ON [PRIMARY]

GO

