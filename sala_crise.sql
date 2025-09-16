{ ## MS SQL SERVER ##



{CHECAR VERSÃO
# -- Alguns scripts e funcionalidades só estão disponíveis em algumas versões
select @@version;
}

{VERIFICAR O QUE ESTÁ RODANDO NO BANCO DE DADOS (sp_who2)

EXECUTAR: sp_who2 (qualquer comando similar que retorne  para verificar o que está em execução no banco) A partir daí devem ser iniciadas as análises. Deve ser observado:

  •	O banco retorna algum bloqueio de processo?
  •	Alguma ausência ou tentativa de criação de índice?
  •	Algum processo em execução há muito tempo?
  •	Enumerar o que está em execução no banco (job, carga, consulta). Avaliar se pode ser ofensor.
  •	Verificar por meio do suporte – em paralelo- os serviços da máquina como mem, cpu e disco.
  •	Buscar pela consulta que mais consumiu recurso. Buscar índice de fragmentação/necessidade de índice/processos zumbis. 

  
EXEC sp_who2 '53'; -- mostra apenas a sessão SPID 53

}

{VERIFICAR TEMPO DO SQL

SELECT last_startup_time
FROM sys.dm_server_services
WHERE ServiceName LIKE 'SQL Server (%' 


}

{VERIFICAR INDEX FRAGMENTADO

* Recomendações do fabricante (Microsoft):
 • Até 30%: reorganizar (REORGANIZE).
 • Acima de 30%: reconstruir o índice (REBUILD).


SELECT OBJECT_NAME(ind.OBJECT_ID) AS TableName,
ind.name AS IndexName, indexstats.index_type_desc AS IndexType,
indexstats.avg_fragmentation_in_percent
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, NULL) indexstats
INNER JOIN sys.indexes ind 
ON ind.object_id = indexstats.object_id
AND ind.index_id = indexstats.index_id
WHERE indexstats.avg_fragmentation_in_percent > 30 --You can specify the percent as you want
ORDER BY indexstats.avg_fragmentation_in_percent DESC;

}

{VERIFICAR ACESSOS NA BASE

IF EXISTS (SELECT * FROM TEMPDB.dbo.sysobjects WHERE NAME IN ('##Users')) 
BEGIN
 DROP TABLE ##Users
END
GO

IF EXISTS (SELECT * FROM TEMPDB.dbo.sysobjects WHERE NAME IN (N'##ACESSO')) 
BEGIN
 DROP TABLE ##ACESSO
END
GO

CREATE TABLE ##Users (
[sid] varbinary(100) NULL,
[Login Name] varchar(100) NULL
)

CREATE TABLE ##ACESSO ([uSER ID] VARCHAR(MAX), [sERVER LOGIN] VARCHAR(MAX), [DATABASE ROLE] VARCHAR(MAX), [DATABASE] VARCHAR(MAX))

declare @cmd1 nvarchar(500)
declare @cmd2 nvarchar(500)
set @cmd1 = '
INSERT INTO ##Users ([sid],[Login Name]) SELECT sid, loginname FROM master.dbo.syslogins

INSERT INTO ##ACESSO 
SELECT su.[name] ,  
u.[Login Name]  , 
 sug.name   , ''?''
 FROM [?].[dbo].[sysusers] su 
 LEFT OUTER JOIN ##Users u 
 ON su.sid = u.sid 
 LEFT OUTER JOIN ([?].[dbo].[sysmembers] sm  
 INNER JOIN [?].[dbo].[sysusers] sug 
 ON sm.groupuid = sug.uid) 
 ON su.uid = sm.memberuid  
 WHERE su.hasdbaccess = 1 
 AND su.[name] != ''dbo''
'
exec sp_MSforeachdb @command1=@cmd1

SELECT * FROM ##ACESSO 
where [Database] = 'nome da base'
GROUP BY 
[uSER ID] , [sERVER LOGIN]  , [DATABASE ROLE]  , [DATABASE];

}

{QUERY QUE MAIS UTILIZA CPU

SELECT TOP 20
GETDATE() AS 'Collection Date',
qs.execution_count AS 'Execution Count',
SUBSTRING(qt.text,qs.statement_start_offset/2 +1,
(CASE WHEN qs.statement_end_offset = -1
THEN LEN(CONVERT(NVARCHAR(MAX), qt.text)) * 2
ELSE qs.statement_end_offset END -
qs.statement_start_offset
)/2
) AS 'Query Text',
DB_NAME(qt.dbid) AS 'DB Name',
qs.total_worker_time AS 'Total CPU Time',
qs.total_worker_time/qs.execution_count AS 'Avg CPU Time (ms)',
qs.total_physical_reads AS 'Total Physical Reads',
qs.total_physical_reads/qs.execution_count AS 'Avg Physical Reads',
qs.total_logical_reads AS 'Total Logical Reads',
qs.total_logical_reads/qs.execution_count AS 'Avg Logical Reads',
qs.total_logical_writes AS 'Total Logical Writes',
qs.total_logical_writes/qs.execution_count AS 'Avg Logical Writes',
qs.total_elapsed_time AS 'Total Duration',
qs.total_elapsed_time/qs.execution_count AS 'Avg Duration (ms)',
qp.query_plan AS 'Plan'
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE
qs.execution_count > 50 OR
qs.total_worker_time/qs.execution_count > 100 OR
qs.total_physical_reads/qs.execution_count > 1000 OR
qs.total_logical_reads/qs.execution_count > 1000 OR
qs.total_logical_writes/qs.execution_count > 1000 OR
qs.total_elapsed_time/qs.execution_count > 1000
ORDER BY
qs.execution_count DESC,
qs.total_elapsed_time/qs.execution_count DESC,
qs.total_worker_time/qs.execution_count DESC,
qs.total_physical_reads/qs.execution_count DESC,
qs.total_logical_reads/qs.execution_count DESC,
qs.total_logical_writes/qs.execution_count DESC;

}

{VERIFICAR TABELAS QUE PRECISAM DE INDEX

SELECT
    sys.objects.name,
    (avg_total_user_cost * avg_user_impact) * (user_seeks + user_scans) AS Impact,
    'CREATE NONCLUSTERED INDEX ix_IndexName ON ' + sys.objects.name COLLATE DATABASE_DEFAULT + ' ( ' + ISNULL(mid.equality_columns, '') + CASE
        WHEN mid.inequality_columns IS NULL THEN ''
        ELSE CASE
                WHEN mid.equality_columns IS NULL THEN ''
                ELSE ','
            END + mid.inequality_columns
    END + ' ) ' + CASE
        WHEN mid.included_columns IS NULL THEN ''
        ELSE 'INCLUDE (' + mid.included_columns + ')'
    END + ';' AS CreateIndexStatement,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns
FROM sys.dm_db_missing_index_group_stats AS migs
INNER JOIN sys.dm_db_missing_index_groups AS mig
    ON migs.group_handle = mig.index_group_handle
INNER JOIN sys.dm_db_missing_index_details AS mid
    ON mig.index_handle = mid.index_handle
    AND mid.database_id = DB_ID()
INNER JOIN sys.objects WITH (NOLOCK)
    ON mid.OBJECT_ID = sys.objects.OBJECT_ID
WHERE (
    migs.group_handle IN (
        SELECT TOP (500) group_handle
        FROM sys.dm_db_missing_index_group_stats WITH (NOLOCK)
        ORDER BY (avg_total_user_cost * avg_user_impact) * (user_seeks + user_scans) DESC
    )
)
AND OBJECTPROPERTY(sys.objects.OBJECT_ID, 'isusertable') = 1
ORDER BY 2 DESC, 3 DESC;

}

{VERIFICAR TAMANHO DAS TABELAS

# • Tabelas muito grandes podem onerar o banco de dados.
# • Planejar fragmentação de tabelas para facilitar rotinas de manutenção.

SELECT TOP 100
    s.[name] AS [schema],
    t.[name] AS [table_name],
    p.[rows] AS [row_count],
    CAST(ROUND(((SUM(a.total_pages) * 8) / 1024.00), 2) AS NUMERIC(36, 2)) AS [size_mb],
    CAST(ROUND(((SUM(a.used_pages) * 8) / 1024.00), 2) AS NUMERIC(36, 2)) AS [used_mb], 
    CAST(ROUND(((SUM(a.total_pages) - SUM(a.used_pages)) * 8) / 1024.00, 2) AS NUMERIC(36, 2)) AS [unused_mb]
FROM 
    sys.tables t
    JOIN sys.indexes i ON t.[object_id] = i.[object_id]
    JOIN sys.partitions p ON i.[object_id] = p.[object_id] AND i.index_id = p.index_id
    JOIN sys.allocation_units a ON p.[partition_id] = a.container_id
    LEFT JOIN sys.schemas s ON t.[schema_id] = s.[schema_id]
WHERE 
    t.is_ms_shipped = 0
    AND i.[object_id] > 255 
GROUP BY
    t.[name], 
    s.[name], 
    p.[rows]
ORDER BY 
    [size_mb] DESC;

}

{VERIFICAR AS MAIORES TABELAS

CREATE TABLE #tamanho_tabelas (
    [database]   NVARCHAR(256),
    [schema]     NVARCHAR(256),
    [table_name] NVARCHAR(256),
    [row_count]  BIGINT,
    [size_mb]    DECIMAL(36, 2),
    [used_mb]    DECIMAL(36, 2),
    [unused_mb]  DECIMAL(36, 2)
)
 
INSERT INTO #tamanho_tabelas
EXEC sys.[sp_MSforeachdb] '
IF (''?'' NOT IN (''model'', ''master'', ''tempdb'', ''msdb''))
BEGIN
 
    SELECT TOP 100
        ''?'' AS [database],
        s.[name] AS [schema],
        t.[name] AS [table_name],
        p.[rows] AS [row_count],
        CAST(ROUND(((SUM(a.total_pages) * 8) / 1024.00), 2) AS NUMERIC(36, 2)) AS [size_mb],
        CAST(ROUND(((SUM(a.used_pages) * 8) / 1024.00), 2) AS NUMERIC(36, 2)) AS [used_mb], 
        CAST(ROUND(((SUM(a.total_pages) - SUM(a.used_pages)) * 8) / 1024.00, 2) AS NUMERIC(36, 2)) AS [unused_mb]
    FROM 
        [?].sys.tables t
        JOIN [?].sys.indexes i ON t.[object_id] = i.[object_id]
        JOIN [?].sys.partitions p ON i.[object_id] = p.[object_id] AND i.index_id = p.index_id
        JOIN [?].sys.allocation_units a ON p.[partition_id] = a.container_id
        LEFT JOIN [?].sys.schemas s ON t.[schema_id] = s.[schema_id]
    WHERE 
        t.is_ms_shipped = 0
        AND i.[object_id] > 255 
    GROUP BY
        t.[name], 
        s.[name], 
        p.[rows]
    ORDER BY
        5 DESC
        
END'
 
SELECT TOP 100 * 
FROM [#tamanho_tabelas]
ORDER BY [size_mb] DESC;

}

{OBS. SOBRE REINICIAR INSTÂNCIA

• Não reiniciar a instância/servidor sem verificar processos em execução no banco. Qualquer processo de escrita/atualização pode colocar o banco no modo RECOVERY em caso de restart.

• Caso exista escrita no banco aguarde a finalização ou informe ao gestor o risco da execução. Banco em recovery não executa nenhuma transação. E demora aproximadamente o mesmo tempo de escrita para desfazer o que foi escrito. 

• É possível acompanhar o processo de recovery pelo log do banco.  SSMS > Expandir Server > Management > Logs do SQL Server


}

{ ***** ADICIONAIS *****
{QUAIS AS QUERIES QUE CADA LOGIN ESTÁ EXECUTANDO NO MOMENTO

SELECT
ES.session_id,
ES.login_name,
UPPER(ES.[Status]) AS [Status],
(SELECT DB_NAME(ER.database_id)) as databasename,
ES.last_request_end_time,
(SELECT [Text] FROM master.sys.dm_exec_sql_text(EC.most_recent_sql_handle )) as sqlscript,
ES.last_request_start_time,
ES.[host_name],
ES.[program_name],
ES.client_interface_name,
ES.cpu_time,
ES.total_scheduled_time,
ES.total_elapsed_time,
EC.net_transport,
ES.nt_domain,
ES.nt_user_name,
EC.client_net_address,
EC.local_net_address,
ER.wait_type,
ER.wait_time,
ER.wait_resource,
blocking_session_id 
FROM
sys.dm_exec_sessions ES
INNER JOIN 
sys.dm_exec_connections EC
ON 
EC.session_id = ES.session_id
INNER JOIN 
sys.dm_exec_requests ER 
ON
EC.session_id = ER.session_id
WHERE 
UPPER(ES.[Status])not in ('SLEEPING','DORMANT')
ORDER BY
Status ASC, last_request_start_time desc

}

{VERIFICA TRANSAÇÕES ATIVAS
#-- transações ativas
select * from sys.dm_tran_active_transactions;

#-- locks ativos
select * from sys.dm_tran_locks;
}

{VER PROCESSAMENTO SQL SERVER

SELECT er.start_time, datediff(ms, er.start_time, getdate()) elapsed_time_ms,
er.session_id, er.wait_type, er.wait_time,
SUBSTRING(st.text, (er.statement_start_offset/2)+1,
((CASE er.statement_end_offset
WHEN -1 THEN DATALENGTH(st.text)
ELSE er.statement_end_offset
END - er.statement_start_offset)/2) + 1) AS statement_text,
CONVERT(XML, qp.query_plan) query_plan,
CASE WHEN sum(eqp.estimate_row_count) > 0 THEN
100 * SUM(eqp.row_count)/SUM(eqp.estimate_row_count)
ELSE
NULL
END AS percent_done
FROM sys.dm_exec_requests er
INNER JOIN sys.dm_exec_query_profiles eqp ON er.session_id = eqp.session_id
AND er.request_id = eqp.request_id
CROSS APPLY sys.dm_exec_sql_text(er.sql_handle) st
CROSS APPLY sys.dm_exec_text_query_plan(er.plan_handle, er.statement_start_offset, er.statement_end_offset) qp
WHERE er.session_id > 50 and er.session_id != @@spid
GROUP BY er.start_time, er.session_id, er.wait_type, er.wait_time, st.text,
er.statement_start_offset, er.statement_end_offset, qp.query_plan
HAVING SUM(eqp.estimate_row_count) > 0

}

{ESTÁ EM EXECUÇÃO NO SQL SERVER E USANDO MUITOS RECURSOS!!!

# OPÇÃO 1:

SELECT
    r.session_id,
	--DATEDIFF(MILSECOND, r.start_time, GETDATE()) AS tempo_exec
    r.start_time,
    r.status,
    r.command,
    r.blocking_session_id,
    DB_NAME(r.database_id) AS database_name,
    s.program_name,
    c.client_net_address,
    sql_text.text,
    query_plan.query_plan
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
JOIN sys.dm_exec_connections c ON r.session_id = c.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS sql_text
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) AS query_plan
WHERE s.is_user_process = 1;


# OPÇÃO 2  -- Rodar na MASTER
--Utilizando as DMVs e DMFs da categoria sys.dm_exec, podemos listar informações
--detalhadas sobre as conexões existentes em uma instância de SQL Server, inclusive
--quais as queries que cada Login está executando no momento

SELECT
ES.session_id,
ES.login_name,
UPPER(ES.[Status]) AS [Status],
(SELECT DB_NAME(ER.database_id)) as databasename,
ES.last_request_end_time,
(SELECT [Text] FROM master.sys.dm_exec_sql_text(EC.most_recent_sql_handle )) as sqlscript,
ES.last_request_start_time,
ES.[host_name],
ES.[program_name],
ES.client_interface_name,
ES.cpu_time,
ES.total_scheduled_time,
ES.total_elapsed_time,
EC.net_transport,
ES.nt_domain,
ES.nt_user_name,
EC.client_net_address,
EC.local_net_address,
ER.wait_type,
ER.wait_time,
ER.wait_resource,
blocking_session_id 
FROM
sys.dm_exec_sessions ES
INNER JOIN 
sys.dm_exec_connections EC
ON 
EC.session_id = ES.session_id
INNER JOIN 
sys.dm_exec_requests ER 
ON
EC.session_id = ER.session_id
WHERE 
UPPER(ES.[Status])not in ('SLEEPING','DORMANT')
ORDER BY
Status ASC, last_request_start_time desc

}

{SESSÕES QUE MAIS ESTÃO USANDO CPU E MEMÓRIA 

-- VERIFICAR SESSÕES ATIVAS POR DATABASE (com data do ultimo login do usuário)
SELECT
    s.session_id AS SID,
    s.login_name AS USERNAME,
    s.login_time AS LOGON_TIME,
    s.status AS STATUS,
    s.original_login_name AS OSUSER,
    s.host_name AS MACHINE,
    s.program_name AS PROGRAM,
    d.name AS DATABASE_NAME,
	s.cpu_time AS CPU_TIME,
	s.memory_usage AS MEMORY_USAGE
FROM sys.dm_exec_sessions s
JOIN sys.databases d ON s.database_id = d.database_id order by cpu_time desc;
--where name = '';
}

{VERIFICA ERROS
#-- log de erros
select * from sys.dm_error_log;

#-- log de eventos
select * from sys.event_log;
}

{VERIFICA HÁ QUANTO TEMPO A INSTÂNCIA FOI INICIADA PELA ÚLTIMA VEZ

select sqlserver_start_time FROM sys.dm_os_sys_info;
--
select 'Instância '+@@SERVICENAME+' está à '+CAST(DATEDIFF(DD, sqlserver_start_time, GETDATE()) AS VARCHAR(2))+' dias ligada' FROM sys.dm_os_sys_info;

}

{VERIFICA STATUS DO BANCO/BASE

select name, user_access_desc, state_desc, recovery_model_desc from sys.databases where name ='GISDB002';

}

***************** JOBS *****************

{VERIFICA O STATUS DE EXECUÇÃO DE UM JOB
USE msdb;
GO

SELECT
    job.name AS JobName,
    job.job_id AS JobID,
    job.enabled AS IsEnabled,
    CASE
        WHEN jobh.run_status = 0 THEN 'Failed'
        WHEN jobh.run_status = 1 THEN 'Succeeded'
        WHEN jobh.run_status = 2 THEN 'Retry'
        WHEN jobh.run_status = 3 THEN 'Canceled'
        WHEN jobh.run_status = 4 THEN 'In Progress'
    END AS RunStatus,
    jobh.run_date AS LastRunDate,
    jobh.run_time AS LastRunTime
FROM
    sysjobs job
LEFT JOIN
    sysjobhistory jobh ON job.job_id = jobh.job_id
WHERE
    jobh.instance_id IN (
        SELECT MAX(instance_id)
        FROM sysjobhistory
        GROUP BY job_id
    )
ORDER BY
    job.name;

}

{VERIFICA O LOG DETALHADO DE EXECUÇÃO DE UM JOB

USE msdb;
GO
-- Verifica os logs de execução de um job específico
SELECT
    job.name AS JobName,
    jobh.step_name AS StepName,
    CASE
        WHEN jobh.run_status = 0 THEN 'Failed'
        WHEN jobh.run_status = 1 THEN 'Succeeded'
        WHEN jobh.run_status = 2 THEN 'Retry'
        WHEN jobh.run_status = 3 THEN 'Canceled'
        WHEN jobh.run_status = 4 THEN 'In Progress'
    END AS RunStatus,
    jobh.run_date AS RunDate,
    jobh.run_time AS RunTime,
    jobh.sql_message_id AS MessageID,
    jobh.sql_severity AS Severity,
    jobh.message AS Message
FROM
    sysjobs job
INNER JOIN
    sysjobhistory jobh ON job.job_id = jobh.job_id
WHERE
    job.name = 'NomeDoSeuJob'
ORDER BY
    jobh.run_date DESC, jobh.run_time DESC;

}

{VERIFICA OS JOBS EXISTENTES

USE msdb;
GO

SELECT
    job_id,
    name AS job_name,
    enabled,
    description,
    date_created,
    date_modified
FROM
    dbo.sysjobs;
GO

# Verificando os Scripts Shell (Steps dos Jobs)
USE msdb;
GO

SELECT
    job_id,
    step_id,
    step_name,
    subsystem,
    command
FROM
    dbo.sysjobsteps;
GO

# Combinando Informações de Jobs e Steps
USE msdb;
GO

SELECT
    j.job_id,
    j.name AS job_name,
    j.enabled,
    j.description,
    j.date_created,
    j.date_modified,
    s.step_id,
    s.step_name,
    s.subsystem,
    s.command
FROM
    dbo.sysjobs j
JOIN
    dbo.sysjobsteps s ON j.job_id = s.job_id;
GO

# jobs que executam scripts shell (por exemplo, scripts `.bat` ou `.sh`), você pode filtrar pelo `subsystem` na tabela `sysjobsteps`
USE msdb;
GO

SELECT
    j.job_id,
    j.name AS job_name,
    s.step_id,
    s.step_name,
    s.subsystem,
    s.command
FROM
    dbo.sysjobs j
JOIN
    dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE
    s.subsystem = 'CmdExec'; -- 'CmdExec' é o subsistema para comandos do shell
GO


}

{CONSULTAR LOG DE EVENTOS (SQL SERVER LOGS)

No SQL Server Management Studio (SSMS):

    Vá até Management > SQL Server Logs.
    Clique com o botão direito e selecione View SQL Server Log.
    Use Ctrl + F para buscar por:
}

}
}


{ ## ORACLE ##

{VERIFICAÇÕES INICIAIS

# Status do banco
srvctl status database -d NOME_DO_BANCO

# Testar conectividade (verifica se o listener está respondendo)
tnsping nome_do_servico

lsnrctl status

 
# OCUPACAO DE FILESYSTEMS
df -h

# VMSTAT
vmstat 2 5; exit

#IOSTAT
iostat -x 2 5 | awk '{if($10 > 1 || $9 > 1) print}'; exit

#FREE -G
free -g
 
}
 
{DATABASE

-- # Verificar se está logado no banco certo e com a role certa
-- # E, sendo possível, se o problema é no primário ou standby

SELECT NAME,DATABASE_ROLE,OPEN_MODE FROM V$DATABASE;

}
 
{INSTÂNCIAS

# --verificar se houve stop/start de instancia e se todas as instancias estão ativas

set linesize 400
set feed off
Alter Session Set Nls_Date_Format = 'dd/mm/yyyy hh24:mi:ss';
select inst_id, instance_name, version, startup_time, status, logins, database_status, blocked from gv$instance order by 1;
   

 }
 
{HOSTNAME E USUÁRIO 

col session_user for a20
col hostname for a50
SELECT 
    SYS_CONTEXT('USERENV', 'SESSION_USER') AS SESSION_USER, SYS_CONTEXT('USERENV', 'HOST') AS HOSTNAME FROM DUAL;
	
}

{SERVIÇOS

# -- verificar se os serviços necessários estão ativos

!  for INST in `grep -i orap /etc/oratab | cut -c 1-8`; do echo "============================>   $INST   <============================"; srvctl status service -d $INST; echo -e /n ;done;

# -- caso não tenha acesso ao sistema operacional do servidor de banco utilizar o comando abaixo
        
col NETWORK_NAME for a40
col name for a20
select INST_ID,NAME, NETWORK_NAME from gV$ACTIVE_SERVICES order by name, inst_id;

# Observar:

# • Verifique se os serviços estão balanceados entre os nós do cluster.
# • Um serviço crítico rodando em apenas uma instância pode indicar falha de failover ou configuração incorreta
# • Compare com a lista de serviços esperados. A ausência de um serviço pode indicar que ele não foi iniciado ou que a instância onde ele deveria estar está fora.
# • Use essa consulta junto com o comando srvctl status service -d <db_name> para validar se os serviços estão ativos e habilitados conforme a configuração.
		
}

{COMPARAR RECURSOS UTILIZADOS COM SEUS LIMITES

col limite_configurado for a30
col DISPLAY_VALUE for a30
col NAME for a30
col RESOURCE_NAME for a20
select rs.inst_id,resource_name,current_utilization, max_utilization,value limite_configurado
from 
  (select inst_id,resource_name, current_utilization, max_utilization from gv$resource_limit where  regexp_like(resource_name, 'transactions|sessions|processes|locks')) rs,
  (select inst_id, name, value from GV$PARAMETER where name in ('sessions','transactions','processes','locks')) par
where rs.resource_name= par.name
and rs.inst_id= par.inst_id
order by resource_name, inst_id;


# OBSERVAÇÕES:
********************************************************************************************************************************************************
 • Essa query permite monitorar recursos fundamentais de instância que, se esgotados, podem causar indisponibilidade ou degradação severa de desempenho.
 
# Recursos monitorados:
 • sessions –---- número de sessões simultâneas.
 • transactions – número de transações simultâneas.
 • processes ---– número de processos Oracle (sessões + background).
 • locks -------– número de locks simultâneos.

# Principais pontos a observar:
--------------------------------------------------------------------------------------------------------------------------------------| 
Recurso      | O que observar                                           | Possíveis problemas se atingir o limite                     |
-------------|----------------------------------------------------------|-------------------------------------------------------------| 
processes    | Se current_utilization estiver próximo de value          | Erros como ORA-00020: maximum number of processes exceeded  |
sessions     | Se o número de sessões ativas está crescendo rapidamente | ORA-00018: maximum number of sessions exceeded              |
transactions | Se há muitas transações simultâneas                      | Pode indicar travamentos ou aplicações mal otimizadas       |
locks        | Se o número de locks está alto                           | Pode indicar contenção, deadlocks ou esperas                |

********************************************************************************************************************************************************
}

{PGA

-- # PGA CONFIGURADA

set lines 200 pages 200
col name for a30
col value for a30
col DISPLAY_VALUE for a30
select inst_id, name, value/1024/1024/1024, DISPLAY_VALUE from GV$SPPARAMETER
where name like '%pga%';

 -- # PGA USADA

set pages 200 lines 200
select INST_ID, sum(PGA_ALLOC_MEM)/1024/1024/1024 PGA_ALOCADA, sum(PGA_USED_MEM)/1024/1024/1024 PGA_USADA
from gv$process group by INST_ID;


# PGA (Program Global Area) - área de memória usada por processos em segundo plano e sessões para operações como ordenações, joins, hash, etc.

## Objetivo: Verificar quanto de PGA está sendo alocada e efetivamente usada por processos em cada instância.
## Comparar configuração vs. uso: Verifique se o valor de pga_aggregate_target está compatível com a carga atual.
## Se a PGA usada estiver próxima ou ultrapassando o pga_aggregate_limit, pode haver problemas de performance ou erros ORA-4030 (falta de memória para operações em memória).

## Uso excessivo de PGA: Se a PGA alocada estiver muito acima da usada, pode indicar ineficiência ou vazamento de memória. Sessões com uso excessivo de PGA podem estar executando queries mal otimizadas (ex: grandes ordenações ou joins sem índices).

## Ambiente RAC: Compare entre instâncias (inst_id). Um uso desbalanceado pode indicar problemas de distribuição de carga.



}

{OBJETOS INVÁLIDOS

-- # Objetos invalidos podem ou não ser a causa de um problema atual, podem existir objetos inválidos há muito tempo que não são usados pela aplicação;

set lines 1000 pages 200
col OWNER for a10
col OBJECT_NAME for a35
col SUBOBJECT_NAME for a30
--OBJETOS INVALIDOS
select OWNER, OBJECT_NAME, SUBOBJECT_NAME,OBJECT_ID,
 DATA_OBJECT_ID, OBJECT_TYPE,
 CREATED,
LAST_DDL_TIME,
TIMESTAMP,
STATUS, TEMPORARY,GENERATED, NAMESPACE
from dba_objects
	where status <> 'VALID'
 order by OBJECT_NAME,SUBOBJECT_NAME,TIMESTAMP;

		 
# Procedures, packages ou views inválidas podem impedir a execução de partes da aplicação. Se um objeto inválido for chamado por uma transação crítica, pode gerar erros em tempo de execução.

# Alguns objetos podem estar inválidos há muito tempo e não são utilizados pela aplicação. Por isso, é importante cruzar com logs de erro ou chamadas recentes para saber se estão relacionados ao incidente.


	
}

{ÍNDICES INVÁLIDOS

# **Índices invalidos podem ou não ser a causa de um problema atual, podem existir Índices inválidos há muito tempo que não são usados pela aplicação;

col OWNER      FOR a20
col INDEX_NAME FOR a40
select owner,INDEX_NAME, STATUS from dba_indexes where STATUS not in  ('VALID','N/A')
union all
select index_owner,INDEX_NAME, STATUS from dba_ind_partitions where STATUS not in ('USABLE','N/A' )
union all
select index_owner,INDEX_NAME, STATUS from dba_ind_subpartitions where STATUS <> 'USABLE';

## Se um índice está UNUSABLE, o otimizador pode ignorá-lo, forçando full table scans, o que pode causar lentidão severa.
## Operações como INSERT, UPDATE, DELETE podem falhar ou ficar lentas se tentarem usar índices INVÁLIDOS.
## Índices UNUSABLE geralmente precisam ser reconstruídos (REBUILD)

##Verificar se são usados pela aplicação
#### Nem todo índice inválido é um problema imediato. Alguns podem estar obsoletos ou não utilizados.
#### Cruzar com estatísticas de uso (V$SEGMENT_STATISTICS, DBA_HIST_SQL_PLAN) pode ajudar a priorizar.


}

{USUÁRIOS EXPIRADOS/BLOQUEADOS

-- # verificar as colunas ACCOUNT_STATUS, LOCK_DATE, EXPIRY_DATE
-- # verificar usuários q ficaram expirados ou bloqueados recentemente, incluir na query quem está nesse status a mais de 40 dias

col username for a30
col profile for a30
set lines 200 pages 200
select USERNAME,profile, ACCOUNT_STATUS, LOCK_DATE, EXPIRY_DATE from dba_users where NOT REGEXP_LIKE (username, '^[C|P][0-9][0-9][0-9][0-9][0-9][0-9]')
and username not in (
'SYS','SYSTEM','XS$NULL','APPQOSSYS','GSMCATUSER','SYSBACKUP','REMOTE_SCHEDULER_AG','DBSFWUSER','GSMUSER','GGSYS','ANONYMOUS','SYSRAC','AUDSYS','REMOTE_SCHEDULER_AGENT','GSMADMIN_INTERNAL','DIP','SYSKM','OUTLN','ORACLE_OCM','SYS$UMF','XDB','SYSDG','WMSYS','DBSNMP')
and EXPIRY_DATE is not null
order by EXPIRY_DATE desc;            

}

{NÚMERO DE SESSÕES POR USUÁRIO

-- # Quantidade de sessões ativas aumentando ou proxímo da qtd de sessões inativas normalmente indica existencia de problemas

set lines 200 pages 200
col username for a20
select * from  (select username,status from gv$session where username is not null)
                                pivot
                                (count(status) for status in ('ACTIVE','INACTIVE')) order by 1;

								
------------------------------------------------------------------------------------------------
-- # Análise:
								
✅ 1. Se o número de sessões ACTIVE estiver muito alto ou crescendo rapidamente, pode indicar:
#----- Gargalo de recursos (CPU, I/O, locks).
#----- Problemas de aplicação (loops, consultas mal otimizadas).
#----- Deadlocks ou sessões presas.

✅ 2. Sessões INACTIVE em excesso
#----- Muitas sessões INACTIVE podem indicar:
#----- Aplicações que não encerram conexões corretamente.
#----- Falta de gerenciamento de pool de conexões.
#----- Sessões zumbis (sem uso, mas ainda abertas).

✅ 3. Relação entre ACTIVE e INACTIVE
#----- Um equilíbrio saudável é esperado.
#----- Se a quantidade de ACTIVE se aproxima ou ultrapassa a de INACTIVE, pode ser sinal de sobrecarga ou comportamento anômalo.
	
✅ 4. Usuários específicos com muitos ACTIVE
#----- Identificar se um único USERNAME está gerando muitas sessões ativas pode ajudar a isolar o problema para uma aplicação ou serviço específico.


								
}

{NÚMERO DE SESSOES POR CLIENT
 

set lines 200 pages 200
col username for a20
select * from  (select machine,status from gv$session where username is not null)
                                pivot
                                (count(status) for status in ('ACTIVE','INACTIVE')) order by 1;

------------------------------------------------------------------------------------------------
-- # Análise:

✅ 1. Identificação de máquinas com excesso de sessões ACTIVE
#----- Se uma máquina estiver com muitas sessões ACTIVE, isso pode indicar:
#----- Aplicação em loop ou com erro.
#----- Sobrecarga de processamento.
#----- Problemas de rede ou lentidão que fazem as sessões ficarem presas.

✅ 2. Máquinas com muitas sessões INACTIVE pode indicar:
#----- Aplicações que não liberam conexões corretamente.
#----- Falta de gerenciamento de pool de conexões.
#----- Sessões zumbis que ocupam recursos desnecessariamente.

✅ 3. Comparação entre máquinas
#----- Permite identificar qual servidor de aplicação está gerando mais carga no banco.
#----- Útil para isolar problemas em ambientes com múltiplas instâncias de aplicação (ex: WebLogic, Tomcat, etc.).

✅ 4. Correlação com eventos recentes
#----- Se uma máquina específica começou a gerar muitas sessões após uma mudança (deploy, atualização, etc.), isso pode ser um indicador direto da causa raiz.



}

{NÚMERO DE SESSÕES POR INSTÂNCIA

set lines 200 pages 200
col username for a20
select * from  (select INST_ID,status from gv$session where username NOT IN ('DBSNMP','SYS','PUBLIC','SYSRAC'))
                                pivot
                                (count(status) for status in ('ACTIVE','INACTIVE')) order by 1;


------------------------------------------------------------------------------------------------
-- # Análise:

✅ 1. Distribuição desigual de sessões entre instâncias, pode indicar:
#----- Problemas de balanceamento de carga.
#----- Aplicações conectando preferencialmente a uma instância.
#----- Falha ou lentidão em outras instâncias.

✅ 2. Crescimento repentino de sessões ACTIVE pode indicar:
#----- Gargalo de recursos (CPU, I/O, locks).
#----- Consultas mal otimizadas ou loops em aplicações.
#----- Sessões presas ou em espera.

✅ 3. Sessões INACTIVE em excesso pode indicar:
#----- Aplicações que não encerram conexões corretamente.
#----- Falta de reaproveitamento de conexões (pool mal configurado).
#----- Sessões zumbis que ocupam recursos.

✅ 4. Instâncias com poucas sessões pode indicar:
#----- Problemas de conectividade.
#----- Instância fora do ar ou com serviços parciais.
#----- Falha no listener ou no balanceamento de conexões.

}

{SESSÕES ATIVAS QUE ESTÃO HÁ MAIS TEMPO EM EXECUÇÃO

-- # Sessões mais demoradas podem apontar a causa de um eventual problema

col USERNAME for a15
select * from (select INST_ID,username,last_call_et from gv$session where username is not null and username not like 'SYS%'
and status = 'ACTIVE'
order by last_call_et desc)
where rownum <= 10  ;


------------------------------------------------------------------------------------------------
-- # Análise:
-- Retorna apenas as 10 sessões mais demoradas.

✅ 1. Sessões com last_call_et muito alto
#----- Indica que a sessão está executando há muito tempo, o que pode significar:
#----- SQLs pesados ou mal otimizados.
#----- Sessões presas ou em espera por recursos.
#----- Problemas de rede ou travamentos.

✅ 2. Sessões que não finalizam
#----- Podem estar em loop, esperando por locks, ou executando operações de I/O intensas.

✅ 3. Correlação com instância (INST_ID)
#----- Se as sessões mais demoradas estão concentradas em uma única instância, pode indicar:
#----- Problemas de balanceamento.
#----- Sobrecarga ou falha parcial em um nó do RAC.

✅ 4. Identificação de usuários ou aplicações
#----- Saber qual usuário está gerando sessões demoradas ajuda a isolar o problema para uma aplicação ou serviço específico.


}

{SESSÕES POR EVENTO DE ESPERA

# ** Sessões mais demoradas podem apontar a causa de um eventual problema

col WAIT_CLASS for a20
col event for a60
select wait_class,event, count(*) from gv$session where status ='ACTIVE' group by wait_class,event order by wait_class,event;

-----------------------------------------------------------------------------------------------------------------------------
# Análise:

✅ 1. Eventos com maior número de sessões
#----- Eventos com muitos count(*) indicam gargalos ou contenções.
#----- Exemplo: muitas sessões esperando por db file sequential read podem indicar lentidão de I/O.

✅ 2. Classes de espera críticas
#----- Concurrency: pode indicar locks ou contenções em recursos compartilhados.
#----- User I/O: pode indicar problemas de leitura ou escrita em disco.
#----- Application: pode indicar problemas na lógica da aplicação ou espera por recursos externos.
#----- Network: pode indicar problemas de comunicação entre instâncias ou com clientes.

✅ 3. Presença de eventos como enq: TX - row lock contention
#----- Indica contenção por linhas bloqueadas, comum em transações simultâneas.

✅ 4. Eventos de Idle
#----- Sessões em espera Idle geralmente não estão causando problemas, mas podem ser analisadas se houver excesso.

}


Em um ambiente de banco de dados oracle de um grande banco do setor bancário, onde os DBAs são acionados em sala de crise para verificação do banco, me explique o que a consulta abaixo faz e os principais pontos a serem observados para identificação e resolução de problemas:


{QUERIES MAIS EXECUTADAS

# ** Aumento na quantidade de execuções de uma query pode ser indicio de problema, assim esse é um ponto a ser avaliado com cuidado. 

col USERNAME for a10
select ses.inst_id, ses.username, ses.sql_id, count (*)  from gv$session ses
where status <> 'INACTIVE'
and username is not null
AND USERNAME <> (SELECT SYS_CONTEXT ('USERENV', 'CURRENT_USER') FROM DUAL)
group by ses.inst_id,username,ses.sql_id
order by count (*) desc ,ses.username,ses.inst_id;
 

}

{BLOQUEADORAS PRINCIPAIS

set long 1000
set lines 2000 pages 100
set colsep ";"
col username for a13
col SQL_FULLTEXT for a2000
col SERVICE_NAME for a15
col machine for a30
col PROGRAMA for a30
col PROCESS for a15
col EVENT for a35
col WAIT_CLASS for a20
col p1text for a20
col p2text for a20
col p3text for a20
col sqlt for a1000
col exec_start for a20
col "login_time" for a20
col resource_group for a15
col SQL_PROFILE for a20
select username
,ses.sql_id
--,PREV_SQL_ID,sql.SQL_PROFILE
        ,SUBSTR(machine,1,30) machine
        --,SUBSTR(program,1,30) programa
        -- , resource_consumer_group as resource_group, service_name
        ,status
        ,ses.process,ses.inst_id, ses.sid, ses.serial#
        ,to_char(LOGON_TIME,'DD/MM/YY HH24:MI:SS') as "login_time"
        ,last_call_et
        --,to_char(SQL_EXEC_START,'DD/MM/YY HH24:MI:SS')as  exec_start
--      ,ses.PROCESS,BLOCKING_SESSION_STATUS, BLOCKING_INSTANCE, BLOCKING_SESSION
        ,wait_class,event,seconds_in_wait,state,PQ_STATUS
        --,ROW_WAIT_OBJ#,ROW_WAIT_FILE#,ROW_WAIT_BLOCK#,ROW_WAIT_ROW#
        ,FINAL_BLOCKING_SESSION_STATUS,FINAL_BLOCKING_INSTANCE,FINAL_BLOCKING_SESSION
        --,p1,p1text,p2,p2text,p3,p3text
        --,SES.SQL_ADDRESS ,SES.SQL_HASH_VALUE,SQL_CHILD_NUMBER,sql.PLAN_HASH_VALUE
        --,SQL_FULLTEXT
,substr(SQL_TEXT,1,1000) as sqlt
from  gv$session ses , gv$sql sql
where ses.sql_id=sql.sql_id
and ses.inst_id=sql.inst_id
                and SES.SQL_ADDRESS    = SQL.ADDRESS
                and SES.SQL_HASH_VALUE = SQL.HASH_VALUE
and ses.sid in (select FINAL_BLOCKING_SESSION from  ----INCLUIR INST ID
(
        select FINAL_BLOCKING_SESSION, count(*) QTD
        from gv$session ses
        where FINAL_BLOCKING_SESSION is not null
        --and username like '%GMS%'
        group by FINAL_BLOCKING_SESSION
        order by QTD desc
)
where rownum <= 10)
order by last_call_et;

}

{SQL COM MAIOR TEMPO DE EXECUCAO INDIVIDUAL

# **Essa query mostra os comandos com maior tempo de execução por execução, verificar a coluna "tempo por exec(microseg)"

set lines 2000 pages 200
col data for a30
col PARSING_SCHEMA_NAME for a20
col CPU_T for 9999999999999999999
col elap_T for 999999999999999999
col TEMPO_por_exec head 'tempo por exec(microseg)'
select * from (select to_char(sysdate, 'dd/mm/yy hh24:mi:ss') DATA,PARSING_SCHEMA_NAME,SQL_ID,PLAN_HASH_VALUE,sum(CPU_TIME) cpu_t,sum(ELAPSED_TIME) elap_t,sum(DISK_READS),sum(BUFFER_GETS),sum(EXECUTIONS),trunc(sum(ELAPSED_TIME)/sum(EXECUTIONS)) TEMPO_por_exec
from gv$sql
where executions >0
and PARSING_SCHEMA_NAME not in ('SYS')
group by PARSING_SCHEMA_NAME,SQL_ID,PLAN_HASH_VALUE,OPTIMIZER_COST
order by TEMPO_por_exec desc) where rownum <= 20;


}

{SQL COM MAIOR TEMPO ACUMULADO DE EXECUÇÃO

# **Essa query mostra os comandos com maior tempo de execução acumulado, verificar a coluna "ELAP_T"

set lines 200 pages 200
col data for a30
col PARSING_SCHEMA_NAME for a20
col CPU_T for 9999999999999999999
col elap_T for 999999999999999999
select * from (select to_char(sysdate, 'dd/mm/yy hh24:mi:ss') DATA ,PARSING_SCHEMA_NAME,SQL_ID,PLAN_HASH_VALUE,sum(CPU_TIME) cpu_t,sum(ELAPSED_TIME) elap_t,sum(DISK_READS),sum(BUFFER_GETS),sum(EXECUTIONS),trunc(sum(ELAPSED_TIME)/sum(EXECUTIONS),1) TEMPO_por_exec
from gv$sql
where executions >0
and PARSING_SCHEMA_NAME not like '%SYS%'
group by PARSING_SCHEMA_NAME,SQL_ID,PLAN_HASH_VALUE,OPTIMIZER_COST
order by sum(ELAPSED_TIME) desc) where rownum <= 10;

}

{QUERIES MAIS DEMORADAS


set long 1000
	set lines 2000 pages 100
	set colsep ";"
	col username for a20
	col SQL_FULLTEXT for a2000
	col SERVICE_NAME for a15 
	col machine for a50
	col PROGRAMA for a30
	col PROCESS for a15
	col EVENT for a40
	col WAIT_CLASS for a20
	col p1text for a20
	col p2text for a20
	col p3text for a20
	col sqlt for a1000
	col exec_start for a20
	col "login_time" for a20
	col resource_group for a15
	col SQL_PROFILE for a20
	select username
	,ses.sql_id
	,PREV_SQL_ID,sql.SQL_PROFILE
	,SUBSTR(machine,1,30) machine
	,SUBSTR(program,1,30) programa
	-- , resource_consumer_group as resource_group, service_name
	,status
	,ses.process,ses.inst_id, ses.sid, ses.serial#
	,to_char(LOGON_TIME,'DD/MM/YY HH24:MI:SS') as "login_time"
	,last_call_et
	--,to_char(SQL_EXEC_START,'DD/MM/YY HH24:MI:SS')as  exec_start
	--	,ses.PROCESS,BLOCKING_SESSION_STATUS, BLOCKING_INSTANCE, BLOCKING_SESSION
	,wait_class,event,seconds_in_wait,state,PQ_STATUS
	--,ROW_WAIT_OBJ#,ROW_WAIT_FILE#,ROW_WAIT_BLOCK#,ROW_WAIT_ROW# 
	,FINAL_BLOCKING_SESSION_STATUS,FINAL_BLOCKING_INSTANCE,FINAL_BLOCKING_SESSION,LOCKWAIT
	,p1,p1text,p2,p2text,p3,p3text
	--,SES.SQL_ADDRESS ,SES.SQL_HASH_VALUE,SQL_CHILD_NUMBER,sql.PLAN_HASH_VALUE
	--,SQL_FULLTEXT
	,substr(SQL_TEXT,1,1000) as sqlt
	from  gv$session ses , gv$sql sql
	where ses.sql_id=sql.sql_id
	and ses.inst_id=sql.inst_id
	and SES.SQL_ADDRESS    = SQL.ADDRESS 
	and SES.SQL_HASH_VALUE = SQL.HASH_VALUE
	and status <> 'INACTIVE' and username <> 'C062667' 
	and username is not null 
	order by last_call_et desc 
	FETCH NEXT 50 ROWS ONLY;
	
}

{QUERIES (SQL_ID) COM MAIS DE UM PLANO DE EXECUÇÃO(PLAN_HASH_VALUE)

# EM MEMÓRIA

		
		SELECT inst_id, sql_id,COUNT(DISTINCT plan_hash_value) AS num_planos
		FROM GV$SQL_PLAN
		GROUP BY sql_id,inst_id
		HAVING COUNT(DISTINCT plan_hash_value) > 1
		order by sql_id;	
		
		

# NO HISTÓRICO

			
			SELECT sql_id, COUNT(DISTINCT plan_hash_value) AS num_planos
			FROM dba_hist_sql_plan
			GROUP BY sql_id
			HAVING COUNT(DISTINCT plan_hash_value) > 1
			order by sql_id;	


}

{TAMANHO/OCUPACAO DOS DISKGROUPS

# Atentar para a coluna "USABLE_FILE_MB"

set lines 200 pages 200
select NAME, STATE, TOTAL_MB, FREE_MB, (TOTAL_MB-FREE_MB) USED_MB,case TOTAL_MB when  0 then 0 else  trunc(((TOTAL_MB-FREE_MB)/TOTAL_MB) * 100)  end "%_USED" , REQUIRED_MIRROR_FREE_MB, USABLE_FILE_MB from V$ASM_DISKGROUP;

}

{TAMANHO/OCUPACAO DAS TABLESPACES

# **Verificar as colunas PCT_USED_ALOCADO e PCT_USED_TOTAL, a primeira mostra o espaço alocado já utilizado a segunda mostra o espaço usado considerando
# **a possibilidade de alocação do banco desde de que exista espaço no diskgroup.

                set lines 200 pages 200
                column max_mb format 999,999,999,999
                column total_mb format 999,999,999,999
                column used_mb format 999,999,999,999
                column free_mb format 999,999,999
                column pct_used_alocado format 999.99
                column pct_used_total format 999.99
                column status format a10
                compute sum of max_mb on report
                compute sum of total_mb on report
                compute sum of used_mb on report
                compute sum of free_mb on report
                break on report
select  total.ts tablespace,
DECODE(total.mb,null,'OFFLINE',dbat.status) status,
Trunc(total.mxmb) max_mb,
Trunc(total.mb) total_mb,
Trunc(NVL(total.mb - free.mb,total.mb)) used_mb,
Trunc(NVL(free.mb,0)) free_mb,
DECODE(total.mb,NULL,0,NVL(ROUND((total.mb - free.mb)/(total.mb)*100,2),100)) pct_used_alocado,
DECODE(total.mxmb,0,1,NVL(ROUND((total.mb - free.mb)/(total.mxmb)*100,2),100)) pct_used_total
from
(select tablespace_name ts, sum(bytes)/1024/1024 mb,sum(maxbytes)/1024/1024 mxmb from dba_data_files group by tablespace_name) total,
(select tablespace_name ts, sum(bytes)/1024/1024 mb from dba_free_space group by tablespace_name) free,
dba_tablespaces dbat
where total.ts=free.ts(+) and total.ts=dbat.tablespace_name
--and (((total.mb - free.mb)/total.mb) > 0.90 or ((DECODE(total.mxmb,0,1,NVL(ROUND((total.mb - free.mb)/(total.mxmb)*100,2),100))) > 0.9)   or (STATUS <> 'ONLINE'))
--and total.ts like 'NDA%'
order by total.ts;
prompt
--TEMP
select  sh.tablespace_name,'TEMP',
SUM(sh.bytes_used+sh.bytes_free)/1024/1024/1024 total_gb,
SUM(sh.bytes_used)/1024/1024/1024 used_gb,
SUM(sh.bytes_free)/1024/1024 free_mb,
ROUND(SUM(sh.bytes_used)/SUM(sh.bytes_used+sh.bytes_free)*100,2) pct_used
FROM v$temp_space_header sh
GROUP BY tablespace_name;

}

{UTILIZAÇÃO DE SEQUENCES

# ** Verificar a coluna "% UTILIZADO" para identificar sequences que alcançaram o limite configurado

col SEQUENCE_OWNER for a20                                                                                                                  
col SEQUENCE_NAME  for a30
col MAX_VALUE for 9999999999999999999999999999999999
col LAST_NUMBER for 9999999999999999999999999999999999
select SEQUENCE_OWNER, SEQUENCE_NAME,MAX_VALUE,INCREMENT_BY,CACHE_SIZE,LAST_NUMBER,TRUNC(LAST_NUMBER/MAX_VALUE*100,2) "% UTILIZADO", CYCLE_FLAG from dba_sequences
where sequence_owner not in ('SYS','SYSTEM','DBSNMP','GSMADMIN_INTERNAL','SQLTXPLAIN','XDB','WMSYS')
order by "% UTILIZADO" desc;


}

{DELAY DE REPLICACAO  


set linesize 300
col name for a30

select  case when ARC_DIFF <= 3 then ':)'  when ARC_DIFF > 3 AND ARC_DIFF <=8  then ':|' ELSE ':('  END ST
,  z.DATABASE_ROLE, z.PROTECTION_MODE, z.SWITCHOVER_STATUS, z.name, z.thread, z.STANDBY_LAST_RECEIVED
,  z.STANDBY_LAST_APPLIED, z.STANDBY_DT_LAST_APP, /*z.data_atual,*/ z.MINUTOS, z.ARC_DIFF
from (
SELECT /*+ PARALLEL(8) */
       c.DATABASE_ROLE,
       c.PROTECTION_MODE,
       C.SWITCHOVER_STATUS,
           a.DEST_ID,
          (select max(nvl2(xx.name,xx.DEST_ID||' - '||xx.name,null))
             from v$archived_log xx
                where xx.DEST_ID = a.DEST_ID
                  and xx.resetlogs_change#=(SELECT resetlogs_change# FROM v$database)
                  and SEQUENCE#  = (select max(yy.SEQUENCE#)
                                      from v$archived_log yy
                                                         where yy.resetlogs_change#=(SELECT resetlogs_change# FROM v$database)
                                                          and yy.DEST_ID = xx.DEST_ID)) as name,
           a.thread# thread,
       b. last_seq STANDBY_LAST_RECEIVED ,
       a.applied_seq STANDBY_LAST_APPLIED,
       TO_CHAR(a.last_app_timestamp,'DD/MM/YYYY HH24:MI:SS') as STANDBY_DT_LAST_APP,
           TO_CHAR(sysdate,'DD/MM/YYYY HH24:MI:SS') as data_atual,
           (sysdate - a.last_app_timestamp) *24*60  as MINUTOS,
       b.last_seq - a.applied_seq ARC_DIFF
FROM   (SELECT /*+ PARALLEL(8) */
               DEST_ID,thread#,
               Max(sequence#) applied_seq,
               Max(next_time) last_app_timestamp
        FROM   gv$archived_log
        WHERE  applied = 'YES'
                and resetlogs_change#=(SELECT resetlogs_change# FROM v$database)
        GROUP  BY DEST_ID,thread#) a,
       (SELECT /*+ PARALLEL(8) */
                   DEST_ID,thread#,
               Max (sequence#) last_seq
        FROM   gv$archived_log
                where resetlogs_change#=(SELECT resetlogs_change# FROM v$database)
        GROUP  BY DEST_ID,thread#) b,
                (SELECT DATABASE_ROLE, DB_UNIQUE_NAME INSTANCE, OPEN_MODE, PROTECTION_MODE, PROTECTION_LEVEL, SWITCHOVER_STATUS FROM V$DATABASE) c
WHERE  a.thread# = b.thread#
and a.DEST_ID = b.DEST_ID) z
where UPPER(z.NAME) NOT LIKE '%ARCHIVELOG%'
and ((z.DATABASE_ROLE = 'PRIMARY'and (z.thread,z.DEST_ID ) in (SELECT INST_ID thread#, DEST_ID FROM GV$ARCHIVE_DEST_STATUS WHERE STATUS <> 'INACTIVE')) or (z.DATABASE_ROLE <> 'PRIMARY'))
order by z.name, z.thread;

}

{UTILIZACAO DE REDO

set lines 200 pages 200
column day format a10
col day for a20
column Switches_per_day format 9999
column 00 format 999
column 01 format 999
column 02 format 999
column 03 format 999
column 04 format 999
column 05 format 999
column 06 format 999
column 08 format 999
column 07 format 999
column 09 format 999
column 10 format 999
column 11 format 999
column 12 format 999
column 13 format 999
column 14 format 999
column 15 format 999
column 16 format 999
column 17 format 999
column 18 format 999
column 19 format 999
column 20 format 999
column 21 format 999
column 22 format 999
column 23 format 999
select to_char(first_time,'DD-MON') day,
sum(decode(to_char(first_time,'hh24'),'00',1,0)) "00",
sum(decode(to_char(first_time,'hh24'),'01',1,0)) "01",
sum(decode(to_char(first_time,'hh24'),'02',1,0)) "02",
sum(decode(to_char(first_time,'hh24'),'03',1,0)) "03",
sum(decode(to_char(first_time,'hh24'),'04',1,0)) "04",
sum(decode(to_char(first_time,'hh24'),'05',1,0)) "05",
sum(decode(to_char(first_time,'hh24'),'06',1,0)) "06",
sum(decode(to_char(first_time,'hh24'),'07',1,0)) "07",
sum(decode(to_char(first_time,'hh24'),'08',1,0)) "08",
sum(decode(to_char(first_time,'hh24'),'09',1,0)) "09",
sum(decode(to_char(first_time,'hh24'),'10',1,0)) "10",
sum(decode(to_char(first_time,'hh24'),'11',1,0)) "11",
sum(decode(to_char(first_time,'hh24'),'12',1,0)) "12",
sum(decode(to_char(first_time,'hh24'),'13',1,0)) "13",
sum(decode(to_char(first_time,'hh24'),'14',1,0)) "14",
sum(decode(to_char(first_time,'hh24'),'15',1,0)) "15",
sum(decode(to_char(first_time,'hh24'),'16',1,0)) "16",
sum(decode(to_char(first_time,'hh24'),'17',1,0)) "17",
sum(decode(to_char(first_time,'hh24'),'18',1,0)) "18",
sum(decode(to_char(first_time,'hh24'),'19',1,0)) "19",
sum(decode(to_char(first_time,'hh24'),'20',1,0)) "20",
sum(decode(to_char(first_time,'hh24'),'21',1,0)) "21",
sum(decode(to_char(first_time,'hh24'),'22',1,0)) "22",
sum(decode(to_char(first_time,'hh24'),'23',1,0)) "23",
count(to_char(first_time,'MM-DD')) Switches_per_day
from gv$log_history
where trunc(first_time) between trunc(sysdate) - 6 and trunc(sysdate)
group by to_char(first_time,'DD-MON')
order by to_char(first_time,'DD-MON') ;

}

{ALERT

set lines 300
col HOST_ID for a40
col ORIGINATING_TIMESTAMP for a40
col MESSAGE_ARGUMENTS for a40
col message_text for a100
select ORIGINATING_TIMESTAMP,
--HOST_ID,
MESSAGE_TYPE, MESSAGE_LEVEL,
--MESSAGE_ARGUMENTS,
message_text
from  v$diag_alert_ext
where ORIGINATING_TIMESTAMP >= sysdate -1/24 --ultimas duas horas
--and MESSAGE_LEVEL <> 16
--and message_level = 1
order by ORIGINATING_TIMESTAMP;



--srvctl config scan
cd $ORACLE_HOME
cd network/admin/
cat tnsnames.ora
lsnrctl status


### {VERIFICAR ALERT NO DIRETORIO abaixo:
 ==========================================================================================

col VALUE for a60
SELECT value
FROM V$DIAG_INFO
where name like 'Diag Trace';
}

}



