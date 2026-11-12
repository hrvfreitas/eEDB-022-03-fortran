!> Programa principal do pipeline ETL em Fortran 2023.
!>
!> Arquivo com extensão .F90 (maiúsculo) para ativar o pré-processador
!> CPP, permitindo a flag -DSTRATEGY=SPLINK em tempo de compilação
!> como alternativa à variável de ambiente MATCH_STRATEGY em tempo de
!> execução (ambas são suportadas; a variável de ambiente tem prioridade).
!>
!> Paralelismo via coarrays:
!>   image 1 -> ingestão RAW + camada Trusted + Delivery
!>   images 2..N -> reservadas para processamento de partições de arquivos
!>                  (extensão futura: dividir os CSVs de Reclamações entre images)
!>
!> Compilação:
!>   gfortran -fcoarray=lib -lcaf_mpi -lpq ... pipeline.F90
!>   ou modo single-image (mais simples):
!>   gfortran -fcoarray=single -lpq       ... pipeline.F90
PROGRAM pipeline
  USE constants_mod
  USE db_libpq_mod
  USE raw_layer_mod
  USE trusted_layer_mod
  USE delivery_layer_mod
  IMPLICIT NONE

  ! ---- configuração (lida de variáveis de ambiente) ----
  CHARACTER(LEN=512) :: data_dir, trusted_dir, delivery_dir
  CHARACTER(LEN=16)  :: strategy_env
  INTEGER :: match_strategy, rc, me, nprocs, length, status

  me     = THIS_IMAGE()
  nprocs = NUM_IMAGES()

  ! ---- lê variáveis de ambiente ----
  CALL GET_ENVIRONMENT_VARIABLE('RAW_ORIGEM_DIR', data_dir,    length, status)
  IF (status /= 0 .OR. length == 0) data_dir = './data/raw/origem'

  CALL GET_ENVIRONMENT_VARIABLE('TRUSTED_OUT_DIR', trusted_dir, length, status)
  IF (status /= 0 .OR. length == 0) trusted_dir = './data/trusted'

  CALL GET_ENVIRONMENT_VARIABLE('DELIVERY_OUT_DIR', delivery_dir, length, status)
  IF (status /= 0 .OR. length == 0) delivery_dir = './data/delivery'

  ! ---- estratégia de matching ----
#ifdef STRATEGY
  ! definida em tempo de compilação via -DSTRATEGY=SPLINK
#  define STRATEGY_STR "SPLINK (definida em compilacao)"
  match_strategy = STRATEGY_SPLINK
#else
  CALL GET_ENVIRONMENT_VARIABLE('MATCH_STRATEGY', strategy_env, length, status)
  IF (status /= 0 .OR. length == 0) strategy_env = 'fuzzy'
  IF (TRIM(str_upper_local(strategy_env)) == 'SPLINK') THEN
    match_strategy = STRATEGY_SPLINK
  ELSE
    match_strategy = STRATEGY_FUZZY
  END IF
#endif

  ! ---- banner ----
  IF (me == 1) THEN
    WRITE(*,'(A)') '============================================'
    WRITE(*,'(A)') ' Pipeline ETL em Fortran 2023'
    WRITE(*,'(A)') ' Case: Reclamações BACEN + Bancos + Glassdoor'
    WRITE(*,'(A)') '============================================'
    WRITE(*,'(A,I0,A)') ' Rodando com ', nprocs, ' coarray image(s)'
    IF (match_strategy == STRATEGY_FUZZY) THEN
      WRITE(*,'(A)') ' Match strategy: FUZZY (Jaro-Winkler + DO CONCURRENT)'
    ELSE
      WRITE(*,'(A)') ' Match strategy: SPLINK (Fellegi-Sunter + EM)'
    END IF
    WRITE(*,'(A)') '============================================'
  END IF

  ! ---- conexão com Postgres (cada image abre a sua) ----
  BLOCK
    TYPE(PGconn_ptr) :: conn
    CHARACTER(LEN=64) :: pg_host, pg_port, pg_db, pg_user, pg_pass
    INTEGER :: l, s

    CALL GET_ENVIRONMENT_VARIABLE('DB_HOST',     pg_host, l, s); IF(l==0) pg_host='localhost'
    CALL GET_ENVIRONMENT_VARIABLE('DB_PORT',     pg_port, l, s); IF(l==0) pg_port='5432'
    CALL GET_ENVIRONMENT_VARIABLE('DB_NAME',     pg_db,   l, s); IF(l==0) pg_db='eedb'
    CALL GET_ENVIRONMENT_VARIABLE('DB_USER',     pg_user, l, s); IF(l==0) pg_user='postgres'
    CALL GET_ENVIRONMENT_VARIABLE('DB_PASSWORD', pg_pass, l, s); IF(l==0) pg_pass='postgres'

    IF (me == 1) THEN
      CALL db_connect(TRIM(pg_host), TRIM(pg_port), TRIM(pg_db), &
                      TRIM(pg_user), TRIM(pg_pass), conn, rc)
      IF (rc /= RC_OK) STOP 1

      ! Garante que os schemas existem
      CALL db_exec(conn, 'CREATE SCHEMA IF NOT EXISTS raw;',      rc)
      CALL db_exec(conn, 'CREATE SCHEMA IF NOT EXISTS trusted;',  rc)
      CALL db_exec(conn, 'CREATE SCHEMA IF NOT EXISTS delivery;', rc)

      ! ---- Etapa 1: RAW ----
      CALL raw_ingest(TRIM(data_dir), conn, rc)
      IF (rc /= RC_OK) THEN
        WRITE(*,'(A)') 'ERRO na camada RAW. Abortando.'
        CALL db_close(conn); STOP 1
      END IF

      SYNC ALL   ! sinaliza para demais images que RAW terminou

      ! ---- Etapa 2: Trusted ----
      CALL trusted_process(TRIM(trusted_dir), conn, match_strategy, rc)
      IF (rc /= RC_OK) THEN
        WRITE(*,'(A)') 'ERRO na camada Trusted. Abortando.'
        CALL db_close(conn); STOP 1
      END IF

      ! ---- Etapa 3: Delivery ----
      CALL delivery_build(TRIM(delivery_dir), TRIM(trusted_dir), conn, rc)
      IF (rc /= RC_OK) THEN
        WRITE(*,'(A)') 'ERRO na camada Delivery.'
      ELSE
        WRITE(*,'(A)') ''
        WRITE(*,'(A)') '============================================'
        WRITE(*,'(A)') ' Pipeline concluido com sucesso!'
        WRITE(*,'(A)') '============================================'
      END IF

      CALL db_close(conn)

    ELSE
      ! Images extras aguardam o sinal de RAW concluído
      SYNC ALL
      ! (aqui entrariam sub-pipelines de partições paralelas em versão
      !  estendida do exercício)
      WRITE(*,'(A,I0,A)') ' Image ', me, ': em standby (extensao futura).'
    END IF
  END BLOCK

CONTAINS

  !> Versão local de str_upper (sem USE do módulo, para o bloco CONTAINS).
  PURE FUNCTION str_upper_local(s) RESULT(r)
    CHARACTER(LEN=*), INTENT(IN) :: s
    CHARACTER(LEN=LEN(s))        :: r
    INTEGER :: i, c
    r = s
    DO i = 1, LEN(s)
      c = ICHAR(s(i:i))
      IF (c >= 97 .AND. c <= 122) r(i:i) = CHAR(c - 32)
    END DO
  END FUNCTION

END PROGRAM pipeline
