/*
	Created by SEADATA\michael.dspain using dbatools Export-DbaScript for objects on dre-jumpbox at 01/15/2026 18:49:13
	See https://dbatools.io/Export-DbaScript for more information
*/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Collector].[MongoDBHealthStatus](
	[ServerID] [int] NOT NULL,
	[RsStatusName] [varchar](60) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[Health] [smallint] NULL,
	[NodeState] [varchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CollectionTime] [datetime] NOT NULL
) ON [PRIMARY]

GO

