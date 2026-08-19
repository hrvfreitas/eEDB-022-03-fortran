!> Interface com o PostgreSQL via libpq (ISO_C_BINDING).
!> Expõe apenas o necessário para o pipeline:
!>   - conectar, executar comando, executar query, fechar.
!>
!> Compilação requer: -lpq  (e -I$(pg_config --includedir))
MODULE db_libpq_mod
  USE ISO_C_BINDING
  USE constants_mod
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: db_connect, db_exec, db_exec_query, db_close, PGconn_ptr

  !> Ponteiro opaco para a conexão libpq (PGconn*).
  TYPE :: PGconn_ptr
    TYPE(C_PTR) :: ptr = C_NULL_PTR
  END TYPE

  ! ---- bindings C para libpq ----
  INTERFACE
    FUNCTION c_PQconnectdb(conninfo) BIND(C, NAME='PQconnectdb')
      IMPORT :: C_PTR, C_CHAR
      CHARACTER(KIND=C_CHAR), INTENT(IN) :: conninfo(*)
      TYPE(C_PTR) :: c_PQconnectdb
    END FUNCTION

    FUNCTION c_PQstatus(conn) BIND(C, NAME='PQstatus')
      IMPORT :: C_PTR, C_INT
      TYPE(C_PTR), VALUE :: conn
      INTEGER(C_INT) :: c_PQstatus
    END FUNCTION

    FUNCTION c_PQexec(conn, query) BIND(C, NAME='PQexec')
      IMPORT :: C_PTR, C_CHAR
      TYPE(C_PTR), VALUE             :: conn
      CHARACTER(KIND=C_CHAR), INTENT(IN) :: query(*)
      TYPE(C_PTR) :: c_PQexec
    END FUNCTION

    FUNCTION c_PQresultStatus(res) BIND(C, NAME='PQresultStatus')
      IMPORT :: C_PTR, C_INT
      TYPE(C_PTR), VALUE :: res
      INTEGER(C_INT) :: c_PQresultStatus
    END FUNCTION

    SUBROUTINE c_PQclear(res) BIND(C, NAME='PQclear')
      IMPORT :: C_PTR
      TYPE(C_PTR), VALUE :: res
    END SUBROUTINE

    SUBROUTINE c_PQfinish(conn) BIND(C, NAME='PQfinish')
      IMPORT :: C_PTR
      TYPE(C_PTR), VALUE :: conn
    END SUBROUTINE

    FUNCTION c_PQntuples(res) BIND(C, NAME='PQntuples')
      IMPORT :: C_PTR, C_INT
      TYPE(C_PTR), VALUE :: res
      INTEGER(C_INT) :: c_PQntuples
    END FUNCTION

    FUNCTION c_PQgetvalue(res, row, col) BIND(C, NAME='PQgetvalue')
      IMPORT :: C_PTR, C_INT
      TYPE(C_PTR),     VALUE :: res
      INTEGER(C_INT),  VALUE :: row, col
      TYPE(C_PTR) :: c_PQgetvalue
    END FUNCTION
  END INTERFACE

  ! PQstatus retorna 0 (CONNECTION_OK) em caso de sucesso
  INTEGER(C_INT), PARAMETER :: CONNECTION_OK    = 0_C_INT
  ! PQresultStatus: PGRES_COMMAND_OK=1, PGRES_TUPLES_OK=2
  INTEGER(C_INT), PARAMETER :: PGRES_COMMAND_OK = 1_C_INT
  INTEGER(C_INT), PARAMETER :: PGRES_TUPLES_OK  = 2_C_INT

CONTAINS

  !> Abre conexão com o Postgres.
  SUBROUTINE db_connect(host, port, dbname, user, password, conn, rc)
    CHARACTER(LEN=*), INTENT(IN)    :: host, port, dbname, user, password
    TYPE(PGconn_ptr), INTENT(OUT)   :: conn
    INTEGER,          INTENT(OUT)   :: rc
    CHARACTER(LEN=512)              :: connstr
    CHARACTER(KIND=C_CHAR, LEN=513) :: c_connstr

    WRITE(connstr, '(5(A,A))') &
      'host=',     TRIM(host),     ' ',  &
      'port=',     TRIM(port),     ' ',  &
      'dbname=',   TRIM(dbname),   ' ',  &
      'user=',     TRIM(user),     ' ',  &
      'password=', TRIM(password)

    c_connstr = TRIM(connstr) // C_NULL_CHAR
    conn%ptr  = c_PQconnectdb(c_connstr)

    IF (c_PQstatus(conn%ptr) /= CONNECTION_OK) THEN
      WRITE(*,'(A)') 'ERRO: falha ao conectar no PostgreSQL.'
      rc = RC_ERROR
    ELSE
      rc = RC_OK
    END IF
  END SUBROUTINE

  !> Executa um comando SQL sem retorno de linhas (CREATE, INSERT, etc.).
  SUBROUTINE db_exec(conn, sql, rc)
    TYPE(PGconn_ptr), INTENT(IN)  :: conn
    CHARACTER(LEN=*), INTENT(IN)  :: sql
    INTEGER,          INTENT(OUT) :: rc
    CHARACTER(KIND=C_CHAR, LEN=LEN(sql)+1) :: c_sql
    TYPE(C_PTR) :: res
    INTEGER(C_INT) :: status

    c_sql = TRIM(sql) // C_NULL_CHAR
    res   = c_PQexec(conn%ptr, c_sql)
    status = c_PQresultStatus(res)
    IF (status /= PGRES_COMMAND_OK .AND. status /= PGRES_TUPLES_OK) THEN
      WRITE(*,'(A,A)') 'ERRO SQL: ', TRIM(sql(1:MIN(120,LEN_TRIM(sql))))
      rc = RC_ERROR
    ELSE
      rc = RC_OK
    END IF
    CALL c_PQclear(res)
  END SUBROUTINE

  !> Executa uma query SELECT e retorna o número de linhas.
  !> (Versão simplificada — para o pipeline, o SELECT é usado só
  !>  internamente em testes de validação.)
  SUBROUTINE db_exec_query(conn, sql, nrows, rc)
    TYPE(PGconn_ptr), INTENT(IN)  :: conn
    CHARACTER(LEN=*), INTENT(IN)  :: sql
    INTEGER,          INTENT(OUT) :: nrows, rc
    CHARACTER(KIND=C_CHAR, LEN=LEN(sql)+1) :: c_sql
    TYPE(C_PTR) :: res

    c_sql  = TRIM(sql) // C_NULL_CHAR
    res    = c_PQexec(conn%ptr, c_sql)
    nrows  = INT(c_PQntuples(res))
    rc     = RC_OK
    CALL c_PQclear(res)
  END SUBROUTINE

  !> Fecha a conexão com o Postgres.
  SUBROUTINE db_close(conn)
    TYPE(PGconn_ptr), INTENT(INOUT) :: conn
    IF (C_ASSOCIATED(conn%ptr)) CALL c_PQfinish(conn%ptr)
    conn%ptr = C_NULL_PTR
  END SUBROUTINE

END MODULE db_libpq_mod
