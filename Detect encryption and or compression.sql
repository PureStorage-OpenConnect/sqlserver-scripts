-- Show any databases that might be using TDE
SELECT d.name FROM sys.databases d
WHERE d.is_encrypted = 1;

-- Show if any databases have any partitions with PAGE/ROW/ColumnStore compression

EXECUTE sys.sp_MSforeachdb N'USE ?; SELECT DISTINCT DB_NAME() + ''.'' + SCHEMA_NAME(o.schema_id) + ''.'' + OBJECT_NAME(p.object_id) As TableName, p.data_compression_desc As TypeOfCompression
									FROM sys.partitions p 
									JOIN sys.objects o ON p.object_id = o.object_id
									WHERE p.data_compression_desc <> ''NONE''
									AND o.is_ms_shipped = 0' 

-- Note: sp_MSforeachdb has some issues running against databases with "exotic" characters. 
-- Use the code below to run on individual databases that might fit that criteria :)

/*

USE <myDatabaseName>;

SELECT DISTINCT DB_NAME() + ''.'' + SCHEMA_NAME(o.schema_id) + ''.'' + OBJECT_NAME(p.object_id) As TableName, p.data_compression_desc As TypeOfCompression
FROM sys.partitions p 
JOIN sys.objects o ON p.object_id = o.object_id
WHERE p.data_compression_desc <> ''NONE''
AND o.is_ms_shipped = 0

*/

-- Potential high entropy columns (may or may not be encryption)

EXECUTE sys.sp_MSforeachdb N'USE ?; SELECT DISTINCT DB_NAME() + ''.'' + SCHEMA_NAME(o.schema_id) + ''.'' + OBJECT_NAME(c.object_id) + ''::'' + c.name
									FROM sys.columns c 
									JOIN sys.types t ON c.system_type_id = t.system_type_id
									JOIN sys.objects o ON c.object_id = o.object_id 
									WHERE t.name IN (''binary'', ''varbinary'')
									AND o.is_ms_shipped = 0'


-- Same as above, use the manual query if you have databases with exotic names

/*

USE <MyDatabaseName>;

SELECT DISTINCT DB_NAME() + ''.'' + SCHEMA_NAME(o.schema_id) + ''.'' + OBJECT_NAME(c.object_id) + ''::'' + c.name
FROM sys.columns c 
JOIN sys.types t ON c.system_type_id = t.system_type_id
JOIN sys.objects o ON c.object_id = o.object_id 
WHERE t.name IN (''binary'', ''varbinary'')
AND o.is_ms_shipped = 0';

*/
