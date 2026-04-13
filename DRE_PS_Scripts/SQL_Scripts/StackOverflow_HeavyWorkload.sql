/*
    StackOverflow Heavy Workload Generator
    Purpose: Stress-test SQL Server using the StackOverflow database.
    WARNING: This WILL consume significant CPU, memory, I/O, and tempdb resources.
             Do NOT run on production systems.
    
    Database: StackOverflow (https://www.brentozar.com/archive/2015/10/how-to-download-the-stack-overflow-database-via-bittorrent/)
*/

USE StackOverflow;
GO

---------------------------------------------------------------
-- 1) CPU: Large cross join with string manipulation
---------------------------------------------------------------
SELECT TOP 0
    HASHBYTES('SHA2_256', CONCAT(p.Title, c.Text, u.DisplayName)),
    UPPER(REVERSE(p.Body)),
    LEN(REPLACE(REPLACE(c.Text, ' ', ''), '<', ''))
FROM Posts p
CROSS JOIN Comments c
CROSS JOIN Users u
WHERE p.Id BETWEEN 1 AND 500
  AND c.Id BETWEEN 1 AND 500
  AND u.Id BETWEEN 1 AND 500;
GO

---------------------------------------------------------------
-- 2) I/O: Full table scans with no useful index
---------------------------------------------------------------
SELECT COUNT(*)
FROM Posts p
INNER JOIN Comments c ON CAST(p.Body AS NVARCHAR(MAX)) LIKE '%' + LEFT(c.Text, 20) + '%'
WHERE p.PostTypeId = 1
  AND p.CreationDate > '2010-01-01';
GO

---------------------------------------------------------------
-- 3) tempdb: Large sort + hash match with spills
---------------------------------------------------------------
SELECT 
    u.DisplayName,
    u.Location,
    p.Title,
    p.Body,
    p.Score,
    p.ViewCount,
    ROW_NUMBER() OVER (PARTITION BY u.Id ORDER BY p.Body DESC) AS rn
FROM Users u
INNER JOIN Posts p ON u.Id = p.OwnerUserId
WHERE u.Reputation > 1
ORDER BY p.Body, u.Location, p.Title;
GO

---------------------------------------------------------------
-- 4) CPU + Memory: Expensive aggregation with window functions
---------------------------------------------------------------
SELECT 
    p.OwnerUserId,
    p.PostTypeId,
    COUNT(*) OVER (PARTITION BY p.OwnerUserId) AS UserPostCount,
    SUM(p.Score) OVER (PARTITION BY p.OwnerUserId ORDER BY p.CreationDate 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RunningScore,
    AVG(p.ViewCount * 1.0) OVER (PARTITION BY p.PostTypeId ORDER BY p.CreationDate
        ROWS BETWEEN 1000 PRECEDING AND CURRENT ROW) AS MovingAvgViews,
    DENSE_RANK() OVER (ORDER BY p.Score DESC) AS ScoreRank,
    NTILE(100) OVER (ORDER BY p.ViewCount DESC) AS ViewPercentile
FROM Posts p
WHERE p.CreationDate > '2008-01-01';
GO

---------------------------------------------------------------
-- 5) I/O + tempdb: Multi-table hash joins on large tables
---------------------------------------------------------------
SELECT 
    u.DisplayName,
    u.Reputation,
    PostStats.TotalPosts,
    PostStats.AvgScore,
    CommentStats.TotalComments,
    BadgeStats.TotalBadges
FROM Users u
INNER JOIN (
    SELECT OwnerUserId, 
           COUNT(*) AS TotalPosts, 
           AVG(Score * 1.0) AS AvgScore,
           MAX(LEN(Body)) AS MaxBodyLength
    FROM Posts
    GROUP BY OwnerUserId
) PostStats ON u.Id = PostStats.OwnerUserId
INNER JOIN (
    SELECT UserId, 
           COUNT(*) AS TotalComments,
           MAX(LEN(Text)) AS MaxCommentLength
    FROM Comments
    GROUP BY UserId
) CommentStats ON u.Id = CommentStats.UserId
INNER JOIN (
    SELECT UserId, 
           COUNT(*) AS TotalBadges,
           COUNT(DISTINCT Name) AS UniqueBadges
    FROM Badges
    GROUP BY UserId
) BadgeStats ON u.Id = BadgeStats.UserId
ORDER BY PostStats.TotalPosts DESC, CommentStats.TotalComments DESC;
GO

---------------------------------------------------------------
-- 6) CPU: Recursive CTE generating large result set
---------------------------------------------------------------
WITH Numbers AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM Numbers WHERE n < 1000
),
PostCrossNumbers AS (
    SELECT p.Id, p.Score, p.ViewCount, n.n,
           p.Score * n.n AS ComputedVal,
           SQRT(CAST(p.ViewCount AS FLOAT) * n.n) AS SqrtVal
    FROM Posts p
    CROSS JOIN Numbers n
    WHERE p.Id <= 5000
)
SELECT AVG(ComputedVal), STDEV(SqrtVal), COUNT(*)
FROM PostCrossNumbers
OPTION (MAXRECURSION 1000);
GO

---------------------------------------------------------------
-- 7) I/O: Triangle join (explosive intermediate result set)
---------------------------------------------------------------
SELECT COUNT(*)
FROM Posts p1
INNER JOIN Posts p2 ON p1.OwnerUserId = p2.OwnerUserId
                   AND p1.Id < p2.Id
INNER JOIN Posts p3 ON p2.OwnerUserId = p3.OwnerUserId
                   AND p2.Id < p3.Id
WHERE p1.PostTypeId = 1
  AND p1.Score > 5;
GO

---------------------------------------------------------------
-- 8) tempdb: Massive implicit spool via correlated subquery
---------------------------------------------------------------
SELECT p.Id, p.Title, p.Score,
    (SELECT COUNT(*) FROM Comments c WHERE c.PostId = p.Id) AS CommentCount,
    (SELECT MAX(Score) FROM Posts p2 WHERE p2.OwnerUserId = p.OwnerUserId) AS UserMaxScore,
    (SELECT COUNT(DISTINCT Name) FROM Badges b WHERE b.UserId = p.OwnerUserId) AS UniqueBadges,
    (SELECT SUM(Score) FROM Posts p3 WHERE p3.ParentId = p.Id) AS ChildScoreSum
FROM Posts p
WHERE p.PostTypeId = 1
ORDER BY p.ViewCount DESC;
GO

---------------------------------------------------------------
-- 9) Memory Grant: Huge sorts with wide rows
---------------------------------------------------------------
SELECT 
    p.Id, p.Body, p.Title, p.Tags,
    c.Text,
    u.DisplayName, u.AboutMe, u.Location,
    REPLICATE('X', 4000) AS Padding
FROM Posts p
INNER JOIN Comments c ON p.Id = c.PostId
INNER JOIN Users u ON p.OwnerUserId = u.Id
ORDER BY p.Body DESC, c.Text DESC, u.AboutMe DESC;
GO

---------------------------------------------------------------
-- 10) Parallelism + CPU: String aggregation across large set
---------------------------------------------------------------
SELECT 
    u.Id,
    u.DisplayName,
    STRING_AGG(CAST(p.Title AS NVARCHAR(MAX)), ' | ') AS AllTitles,
    STRING_AGG(CAST(LEFT(p.Body, 200) AS NVARCHAR(MAX)), ' | ') AS BodyPreviews
FROM Users u
INNER JOIN Posts p ON u.Id = p.OwnerUserId
WHERE u.Reputation > 100
GROUP BY u.Id, u.DisplayName
HAVING COUNT(*) > 10
ORDER BY COUNT(*) DESC;
GO
