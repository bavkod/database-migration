create schema database_migration;

/* 
     This script will generate create schema, create table and create import statements 
     to load all needed data from a SQL Server database. Automatic datatype conversion is 
     applied whenever needed. Feel free to adjust it. 
*/

create or replace script database_migration.SQLSERVER_TO_EXASOL(
CONNECTION_NAME 				-- name of the database connection inside exasol, e.g. sqlserver_db
,DB2SCHEMA 						-- if true then SQL Server: database.schema.table => EXASOL: database.schema_table; if false then SQLSERVER: schema.table => EXASOL: schema.table
,DB_FILTER 						-- filter for SQLSERVER db, e.g. 'master', 'ma%', 'first_db, second_db', '%'
,SCHEMA_FILTER 					-- filter for the schemas to generate and load, e.g. 'my_schema', 'my%', 'schema1, schema2', '%'
,TABLE_FILTER 					-- filter for the tables to generate and load, e.g. 'my_table', 'my%', 'table1, table2', '%'
,IDENTIFIER_CASE_INSENSITIVE 	-- TRUE if identifiers should be put uppercase
) RETURNS TABLE
AS

exa_upper_begin=''
exa_upper_end=''
if IDENTIFIER_CASE_INSENSITIVE == true then
	exa_upper_begin='upper('
	exa_upper_end=')'
end

if string.match(DB_FILTER, '%%') then	
DB_STR = 		[[like ('']]..DB_FILTER..[['')]]			
else	DB_STR			= [[in ('']]..DB_FILTER:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*',"'',''")..[['')]]			
end

output(DB_STR)

if string.match(SCHEMA_FILTER, '%%') then	
SCHEMA_STR = 	[[like ('']]..SCHEMA_FILTER..[['')]]		
else	SCHEMA_STR		= [[in ('']]..SCHEMA_FILTER:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*',"'',''")..[['')]]		
end

output(SCHEMA_STR)

if string.match(TABLE_FILTER, '%%') then	
TABLE_STR = 		[[like ('']]..TABLE_FILTER..[['')]]			
else	TABLE_STR		= [[in ('']]..TABLE_FILTER:gsub("^%s*(.-)%s*$", "%1"):gsub('%s*,%s*',"'',''")..[['')]]		
end

output(TABLE_STR)

if DB2SCHEMA then 
	schema_column = 'DB_NAME'
	tbl_def = [["' || ]]..exa_upper_begin..[[ DB_NAME ]] ..exa_upper_end..[[ || '"."' || ]]..exa_upper_begin..[[ SCHEMA_NAME ]] ..exa_upper_end..[[ || '_' ||  ]]..exa_upper_begin..[[  table_name ]] ..exa_upper_end..[[  || '" ]]
	tbl_group = [[DB_NAME,SCHEMA_NAME,TABLE_NAME]]
else
	schema_column = 'SCHEMA_NAME'
	tbl_def = [["' || ]]..exa_upper_begin..[[ schema_name ]] ..exa_upper_end..[[ || '"."' || ]]..exa_upper_begin..[[ table_name ]] ..exa_upper_end..[[  || '"]]
	tbl_group = [[SCHEMA_NAME,TABLE_NAME]]
end

success1, res1 = pquery([[	select * from (
								import from jdbc at ]]..CONNECTION_NAME..[[
								statement ' select name from sys.databases where name ]]..DB_STR..[[ ' )
						]],{})
if not success1 then error('Error on getting db list from sqlserver:'..res1.error_message) else output('Successfully received db list from sqlserver. ') end

if (#res1) < 1 then error('No database found.') end

query_str = [[select 	'']]..res1[1][1]..[[''  as DB_NAME,
  	 s.name  as SCHEMA_NAME,
  	 t.name  as TABLE_NAME, 
  	c.column_id as COLUMN_ID,]]..exa_upper_begin..[[c.name]]..exa_upper_end..[[  as COLUMN_NAME, 
  	c.max_length as COL_MAX_LENGTH,
  	c.precision as PRECISION, 
  	c.scale as SCALE, 
  	c.is_nullable as IS_NULLABLE, 
  	c.is_identity as IS_IDENTITY, 
  	c.system_type_id as SYSTEM_TYPE_ID,
  	c.user_type_id as USER_TYPE_ID,
  	ty.name as TYPE_NAME
 		from []]..res1[1][1]..[[].sys.schemas s
  join []]..res1[1][1]..[[].sys.tables t on s.schema_id=t.schema_id 
  join []]..res1[1][1]..[[].sys.columns c on c.object_id=t.object_id 
  join sys.types ty on c.user_type_id = ty.user_type_id
					where s.name ]]..SCHEMA_STR..[[ and t.name ]]..TABLE_STR..' '

output(query_str)

for i = 2, (#res1) do
query_str = query_str..[[
union all 
]].. 
		[[select 	'']]..res1[i][1]..[[''  as DB_NAME,
		            s.name  as SCHEMA_NAME,
					t.name  as TABLE_NAME, 
					c.column_id as COLUMN_ID,]]..exa_upper_begin..[[c.name]]..exa_upper_end..[[  as COLUMN_NAME, 
					c.max_length as COL_MAX_LENGTH,
					c.precision as PRECISION, 
					c.scale as SCALE, 
					c.is_nullable as IS_NULLABLE, 
					c.is_identity as IS_IDENTITY, 
					c.system_type_id as SYSTEM_TYPE_ID,
					c.user_type_id as USER_TYPE_ID,
					ty.name as TYPE_NAME
			from []]..res1[i][1]..[[].sys.schemas s
				join []]..res1[i][1]..[[].sys.tables t on s.schema_id=t.schema_id 
				join []]..res1[i][1]..[[].sys.columns c on c.object_id=t.object_id 
				join sys.types ty on c.user_type_id = ty.user_type_id
			where s.name ]]..SCHEMA_STR..[[ and t.name ]]..TABLE_STR..' '
end

output(query_str)

success, res = pquery([[
with sqlserv_base as( 
	select * from(
		import from jdbc at ]]..CONNECTION_NAME..[[
		statement ']]..query_str..[['
				)
			),
	cr_schemas as ( -- if db=schema then select distinct db_name as schema_name else select distinct schema_name as schema_name
		with all_schemas as (select distinct ]]..schema_column..[[ as schema_name from sqlserv_base )
			select 'create schema "' || ]]..exa_upper_begin..[[ schema_name ]]..exa_upper_end..[[ ||'";' as cr_schema from all_schemas order by schema_name
	),
	cr_tables as ( -- if db=schema then db_name"."schema_name"_"table_name
		select 'create table ]]..tbl_def..[[ ( ' 
				|| cols || '
);' as tbls from (select ]]..tbl_group..[[, 
 			group_concat( 
 				case USER_TYPE_ID -- SQLSERVER datatype system type codes are in system table SYS.TYPES, 
 					--map with USER_TYPE_ID instead of SYSTEM_TYPE_ID ( not unique!!!)
 					when 108 then '"' || column_name || '"' ||' ' || 'DECIMAL(' || PRECISION || ',' || SCALE || ')' --       numeric
 					when 36 then  '"' || column_name || '"' ||' ' ||  'CHAR(36)'										-- uniqueidentifier 
 					when 106 then '"' || column_name || '"' ||' ' ||  'DECIMAL(' || PRECISION || ',' || SCALE || ')'          --decimal
 					when 175  then '"' || column_name || '"' ||' ' ||'CHAR('||COL_MAX_LENGTH || ')'                     --char
 					when 62 then '"' || column_name || '"' ||' ' ||'DOUBLE'         				   --float
 					when 42 then '"' || column_name || '"' ||' ' ||'TIMESTAMP'     				  --datetime2
 					when 239 then '"' || column_name || '"' ||' ' ||'CHAR('|| COL_MAX_LENGTH || ')'                      --nchar
 					when 231  then '"' || column_name || '"' ||' ' ||'VARCHAR('||case when COL_MAX_LENGTH < 1 then 2000000 else COL_MAX_LENGTH end || ')'        --sysname
 					when 127 then '"' || column_name || '"' ||' ' ||'DECIMAL(' || PRECISION || ',' || SCALE || ')'          --bigint
 					when 231 then '"' || column_name || '"' ||' ' ||'VARCHAR('||case when COL_MAX_LENGTH < 1 then 2000000 else COL_MAX_LENGTH end || ')'                     --nvarchar
 					when 52 then '"' || column_name || '"' ||' ' ||'DECIMAL(' || PRECISION || ',' || SCALE || ')'            --smallint
 					when 41 then '"' || column_name || '"' ||' ' ||'TIMESTAMP'       --time
 					when 61 then '"' || column_name || '"' ||' ' ||'TIMESTAMP'       --datetime
 					when 56 then '"' || column_name || '"' ||' ' ||'DECIMAL(' || PRECISION || ',' || SCALE || ')'  --int
 					when 167 then '"' || column_name || '"' ||' ' ||'VARCHAR('||case when COL_MAX_LENGTH < 1 then 2000000 else COL_MAX_LENGTH end || ')'         --varchar
 					when 48 then '"' || column_name || '"' ||' ' ||'DECIMAL(' || PRECISION || ',' || SCALE || ')'            --tinyint
 					when 104 then '"' || column_name || '"' ||' ' || 'DECIMAL(1,0)'										-- bit
 					when 40  then '"' || column_name || '"' ||' ' || 'DATE'											 --date
 					when 35  then '"' || column_name || '"' ||' ' ||'VARCHAR(2000000)' --text
 					when 43 then '"' || column_name || '"' ||' ' ||'TIMESTAMP' --datetimeoffset
 					when 58 then '"' || column_name || '"' ||' ' ||'TIMESTAMP' --smalldatetime
 					when 59 then '"' || column_name || '"' ||' ' ||'DOUBLE' -- real
 					when 60 then '"' || column_name || '"' ||' ' || 'DECIMAL(' || PRECISION || ',' || SCALE || ')' --money
 					when 99 then '"' || column_name || '"' ||' ' ||'VARCHAR(2000000)' --ntext
 					when 122 then '"' || column_name || '"' ||' ' ||'DECIMAL(' || PRECISION || ',' || SCALE || ')' --smallmoney
 					when 127 then '"' || column_name || '"' ||' ' ||'DECIMAL(' || PRECISION || ',' || SCALE || ')'  --bigint
 					when 128 then '"' || column_name || '"' ||' ' ||'VARCHAR(2000000)' --hierarchyid
 					when 129 then '"' || column_name || '"' ||' ' ||'GEOMETRY' --geometry
 					when 130 then '"' || column_name || '"' ||' ' ||'GEOMETRY' --geography
 					when 189 then '"' || column_name || '"' ||' ' ||'TIMESTAMP'  -- timestamp
 					when 241 then '"' || column_name || '"' ||' ' ||'VARCHAR(2000000)' --xml
 					when 256 then '"' || column_name || '"' ||' ' ||'CHAR(128)' --sysname
 					else '-- UNSUPPORTED DATATYPE IN COLUMN ' || column_name || '  MSSQL TYPE INFO: USER_TYPE_ID ' || USER_TYPE_ID || ', SYSTEM_TYPE_ID ' ||  SYSTEM_TYPE_ID || ', NAME ' || TYPE_NAME || ', PRECISION ' || PRECISION || ', SCALE ' || SCALE
 				end
 				|| case when IS_IDENTITY='1' then ' IDENTITY' end
 				|| case when IS_NULLABLE='0' then ' NOT NULL' end
 				
 			order by COLUMN_ID SEPARATOR ', 
' ) as cols 
 			from sqlserv_base group by ]]..tbl_group..[[ ) order by tbls
	),
	cr_import_stmts as (
		select 'import into ]]..tbl_def..[[( ' || group_concat( case USER_TYPE_ID -- SQLSERVER datatype system type codes are in system table SYS.TYPES, 
 					when 108 then '"' || column_name || '"' 
 					when 36 then  '"' || column_name || '"' 
 					when 106 then '"' || column_name || '"' 
 					when 175  then '"' || column_name || '"' 
 					when 62 then '"' || column_name || '"' 
 					when 42 then '"' || column_name || '"' 
 					when 239 then '"' || column_name || '"' 
 					when 231  then '"' || column_name || '"' 
 					when 127 then '"' || column_name || '"' 
 					when 231 then '"' || column_name || '"' 
 					when 52 then '"' || column_name || '"' 
 					when 41 then '"' || column_name || '"' 
 					when 61 then '"' || column_name || '"' 
 					when 56 then '"' || column_name || '"' 
 					when 167 then '"' || column_name || '"' 
 					when 48 then '"' || column_name || '"' 
 					when 104 then '"' || column_name || '"' 
 					when 40  then '"' || column_name || '"' 
 					when 35  then '"' || column_name || '"' 
 					when 43 then '"' || column_name || '"' 
 					when 58 then '"' || column_name || '"' 
 					when 59 then '"' || column_name || '"' 
 					when 60 then '"' || column_name || '"'
 					when 99 then '"' || column_name || '"'
 					when 122 then '"' || column_name || '"' 
 					when 127 then '"' || column_name || '"' 
 					when 128 then '"' || column_name || '"' 
 					when 129 then '"' || column_name || '"' 
 					when 130 then '"' || column_name || '"' 
 					when 189 then '"' || column_name || '"'
 					when 241 then '"' || column_name || '"' 
 					when 256 then '"' || column_name || '"'
 					else '-- UNSUPPORTED DATATYPE IN COLUMN ' || column_name || '  MSSQL TYPE INFO: USER_TYPE_ID ' || USER_TYPE_ID || ', SYSTEM_TYPE_ID ' ||  SYSTEM_TYPE_ID || ', NAME ' || TYPE_NAME || ', PRECISION ' || PRECISION || ', SCALE ' || SCALE
 				end  order by column_id SEPARATOR ',
' ) || '
) 
from jdbc at ]]..CONNECTION_NAME..[[ statement 
''select 
' || group_concat(case USER_TYPE_ID -- SQLSERVER datatype system type codes are in system table SYS.TYPES, 
 					when 108 then '[' || column_name || ']' 
 					when 36 then  '[' || column_name || ']' 
 					when 106 then '[' || column_name || ']' 
 					when 175  then '[' || column_name || ']' 
 					when 62 then '[' || column_name || ']' 
 					when 42 then '[' || column_name || ']' 
 					when 239 then '[' || column_name || ']' 
 					when 231  then '[' || column_name || ']' 
 					when 127 then '[' || column_name || ']' 
 					when 231 then '[' || column_name || ']' 
 					when 52 then '[' || column_name || ']' 
 					when 41 then 'cast([' || column_name || '] as DateTime)'  --time 
 					when 61 then '[' || column_name || ']' 
 					when 56 then '[' || column_name || ']' 
 					when 167 then '[' || column_name || ']' 
 					when 48 then '[' || column_name || ']' 
 					when 104 then '[' || column_name || ']' 
 					when 40  then '[' || column_name || ']' 
 					when 35  then '[' || column_name || ']' 
 					when 43 then 'cast([' || column_name || '] as DateTime)' 
 					when 58 then '[' || column_name || ']' 
 					when 59 then '[' || column_name || ']' 
 					when 60 then '[' || column_name || ']'
 					when 99 then '[' || column_name || ']'
 					when 122 then '[' || column_name || ']' 
 					when 127 then '[' || column_name || ']' 
 					when 128 then '[' || column_name || '].ToString()' 
 					when 129 then '[' || column_name || '].ToString()' 
 					when 130 then '[' || column_name || '].ToString()' 
 					when 189 then 'CAST([' || column_name || '] AS DATETIME)'
 					when 241 then '[' || column_name || ']' 
 					when 256 then '[' || column_name || ']'
 					else '-- UNSUPPORTED DATATYPE IN COLUMN ' || column_name || '  MSSQL TYPE INFO: USER_TYPE_ID ' || USER_TYPE_ID || ', SYSTEM_TYPE_ID ' ||  SYSTEM_TYPE_ID || ', NAME ' || TYPE_NAME || ', PRECISION ' || PRECISION || ', SCALE ' || SCALE
 				end  order by column_id SEPARATOR ',
') || '

from ' ||  '[' || db_name || '].[' || schema_name || '].[' || table_name || ']' || '''
;'  as imp from sqlserv_base group by DB_NAME,SCHEMA_NAME,TABLE_NAME order by imp
	)
select '--This SQL Server is system-wide '|| status || '. There might be exceptions on table or column level.' from (select * from (import from jdbc at ]]..CONNECTION_NAME..[[ statement 'select case when ''A'' = ''a'' then ''NOT CASE SENSITIVE'' else ''CASE SENSITIVE'' end as STATUS'))
union all
select * from cr_schemas
union all
select * from cr_tables
union all
select * from cr_import_stmts

]],{})
output(res.statement_text)
if not success then error(res.error_message) end
return(res)
/

-- Create a connection to the SQLServer database
create or replace CONNECTION sqlserver_connection 
	TO 'jdbc:jtds:sqlserver://192.168.1.42:1433'
	USER 'user'
	IDENTIFIED BY 'exasolRocks!';

-- Finally start the import process
execute script database_migration.SQLSERVER_TO_EXASOL(
    'sqlserver_connection', -- CONNECTION_NAME:             name of the database connection inside exasol -> e.g. sqlserver_db
    true,                   -- DB2SCHEMA:                   if true then SQL Server: database.schema.table => EXASOL: database.schema_table; if false then SQLSERVER: schema.table => EXASOL: schema.table
    'AdventureWorks%',      -- DB_FILTER:                   filter for SQLSERVER db, e.g. 'master', 'ma%', 'first_db, second_db', '%'
    '%',                    -- SCHEMA_FILTER:               filter for the schemas to generate and load e.g. 'my_schema', 'my%', 'schema1, schema2', '%'
    '%',                    -- TABLE_FILTER:                filter for the tables to generate and load e.g. 'my_table', 'my%', 'table1, table2', '%'
    false                   -- IDENTIFIER_CASE_INSENSITIVE: set to TRUE if identifiers should be put uppercase
);


