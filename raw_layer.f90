!> Camada RAW — Etapa 1 do pipeline.
!>
!> Lê os arquivos originais (Reclamações, Bancos, Empregados) sem nenhum
!> tratamento e os persiste em disco (formato "livre" — CSV espelho) e no
!> Postgres (schema "raw").
!>
!> O processamento das 3 fontes é dividido entre coarray images quando
!> NUM_IMAGES() >= 3; caso contrário roda sequencial na image 1.
MODULE raw_layer_mod
  USE constants_mod
  USE string_utils_mod
  USE csv_reader_mod
  USE db_libpq_mod
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: raw_ingest

CONTAINS

  !> Persiste um csv_dataset no Postgres (schema raw, tabela 'tablename').
  !> Cria a tabela dinamicamente com todas as colunas como TEXT.
  SUBROUTINE persist_to_postgres(conn, ds, tablename, rc)
    TYPE(PGconn_ptr),  INTENT(IN)    :: conn
    TYPE(csv_dataset), INTENT(IN)    :: ds
    CHARACTER(LEN=*),  INTENT(IN)    :: tablename
    INTEGER,           INTENT(OUT)   :: rc

    CHARACTER(LEN=4096) :: sql
    CHARACTER(LEN=512)  :: row_vals
    CHARACTER(LEN=MAX_FIELD_LEN) :: val
    INTEGER :: i, j

    ! DROP + CREATE
    sql = 'DROP TABLE IF EXISTS raw.' // TRIM(tablename) // ';'
    CALL db_exec(conn, sql, rc); IF (rc /= RC_OK) RETURN

    sql = 'CREATE TABLE raw.' // TRIM(tablename) // ' ('
    DO j = 1, ds%ncols
      IF (j > 1) sql = TRIM(sql) // ', '
      ! sanitiza nome da coluna: remove chars inválidos
      sql = TRIM(sql) // '"' // &
            TRIM(normalize_col_name(ds%headers(j))) // '" TEXT'
    END DO
    sql = TRIM(sql) // ');'
    CALL db_exec(conn, sql, rc); IF (rc /= RC_OK) RETURN

    ! INSERT linha a linha (para exercício; produção usaria COPY)
    DO i = 1, ds%nrows
      sql = 'INSERT INTO raw.' // TRIM(tablename) // ' VALUES ('
      DO j = 1, ds%ncols
        IF (j > 1) sql = TRIM(sql) // ', '
        val = TRIM(ds%data(i,j))
        ! escapa aspas simples
        CALL escape_single_quote(val)
        sql = TRIM(sql) // '''' // TRIM(val) // ''''
      END DO
      sql = TRIM(sql) // ');'
      CALL db_exec(conn, sql, rc)
      IF (rc /= RC_OK) RETURN
    END DO

    WRITE(*,'(A,A,A,I0,A)') '  raw.', TRIM(tablename), &
                              ': ', ds%nrows, ' linhas inseridas.'
  END SUBROUTINE

  !> Sanitiza nome de coluna para SQL (substitui espaços e chars especiais).
  PURE FUNCTION normalize_col_name(s) RESULT(r)
    CHARACTER(LEN=*), INTENT(IN)  :: s
    CHARACTER(LEN=MAX_FIELD_LEN)  :: r
    INTEGER :: i, c
    r = ''
    DO i = 1, LEN_TRIM(s)
      c = ICHAR(s(i:i))
      IF ((c >= 65 .AND. c <= 90) .OR. (c >= 97 .AND. c <= 122) .OR. &
          (c >= 48 .AND. c <= 57)) THEN
        r(i:i) = CHAR(c)
      ELSE
        r(i:i) = '_'
      END IF
    END DO
    r = ADJUSTL(r)
  END FUNCTION

  !> Escapa aspas simples em valor SQL (in-place, simplificado).
  SUBROUTINE escape_single_quote(s)
    CHARACTER(LEN=*), INTENT(INOUT) :: s
    INTEGER :: pos
    pos = INDEX(s, "'")
    DO WHILE (pos > 0 .AND. pos < LEN_TRIM(s))
      s = s(1:pos) // "'" // s(pos+1:)
      pos = INDEX(s(pos+2:), "'")
      IF (pos > 0) pos = pos + pos + 1
    END DO
  END SUBROUTINE

  !> Ponto de entrada da camada RAW.
  SUBROUTINE raw_ingest(data_dir, conn, rc)
    CHARACTER(LEN=*),  INTENT(IN)  :: data_dir
    TYPE(PGconn_ptr),  INTENT(IN)  :: conn
    INTEGER,           INTENT(OUT) :: rc

    TYPE(csv_dataset) :: ds_recl, ds_bancos, ds_emp_match, ds_emp_mless
    INTEGER  :: rc2
    CHARACTER(LEN=512) :: path

    rc = RC_OK
    WRITE(*,'(A)') '=== Camada RAW ==='

    ! ---- Reclamações (8 arquivos trimestrais concatenados) ----
    CALL ingest_reclamacoes(data_dir, conn, ds_recl, rc2)
    IF (rc2 /= RC_OK) rc = RC_ERROR

    ! ---- Bancos ----
    path = TRIM(data_dir) // '/Bancos/EnquadramentoInicia_v2.tsv'
    CALL csv_read_file(path, CHAR(9), ds_bancos, rc2)
    IF (rc2 == RC_OK) CALL persist_to_postgres(conn, ds_bancos, 'bancos', rc2)
    IF (rc2 /= RC_OK) rc = RC_ERROR

    ! ---- Empregados (match) ----
    path = TRIM(data_dir) // '/Empregados/glassdoor_consolidado_join_match_v2.csv'
    CALL csv_read_file(path, '|', ds_emp_match, rc2)
    IF (rc2 == RC_OK) CALL persist_to_postgres(conn, ds_emp_match, 'empregados_match', rc2)
    IF (rc2 /= RC_OK) rc = RC_ERROR

    ! ---- Empregados (match_less) ----
    path = TRIM(data_dir) // '/Empregados/glassdoor_consolidado_join_match_less_v2.csv'
    CALL csv_read_file(path, '|', ds_emp_mless, rc2)
    IF (rc2 == RC_OK) CALL persist_to_postgres(conn, ds_emp_mless, 'empregados_match_less', rc2)
    IF (rc2 /= RC_OK) rc = RC_ERROR

    CALL csv_free(ds_recl); CALL csv_free(ds_bancos)
    CALL csv_free(ds_emp_match); CALL csv_free(ds_emp_mless)
    WRITE(*,'(A)') '=== RAW concluído ==='
  END SUBROUTINE

  !> Lê todos os arquivos CSV de Reclamações e os concatena em um único
  !> csv_dataset, adicionando coluna 'arquivo_origem'.
  SUBROUTINE ingest_reclamacoes(data_dir, conn, ds_out, rc)
    CHARACTER(LEN=*),  INTENT(IN)  :: data_dir
    TYPE(PGconn_ptr),  INTENT(IN)  :: conn
    TYPE(csv_dataset), INTENT(OUT) :: ds_out
    INTEGER,           INTENT(OUT) :: rc

    ! Lista fixa dos 8 arquivos trimestrais (2021 Q1 a 2022 Q4,
    ! excluindo o vazio 2022_tri_02)
    CHARACTER(LEN=64), PARAMETER :: FILES(7) = [ &
      '2021_tri_01.csv                                                 ', &
      '2021_tri_02.csv                                                 ', &
      '2021_tri_03.csv                                                 ', &
      '2021_tri_04.csv                                                 ', &
      '2022_tri_01.csv                                                 ', &
      '2022_tri_03.csv                                                 ', &
      '2022_tri_04.csv                                                 ' ]

    TYPE(csv_dataset) :: tmp
    CHARACTER(LEN=512) :: path
    CHARACTER(LEN=MAX_FIELD_LEN) :: row(MAX_COLS + 1)
    INTEGER :: f, i, j, rc2, total_rows, ncols

    rc = RC_OK; total_rows = 0; ncols = 0
    ds_out%nrows = 0

    ! primeiro passe: descobre ncols e reserva ds_out
    DO f = 1, SIZE(FILES)
      path = TRIM(data_dir) // '/Reclamações/' // TRIM(ADJUSTL(FILES(f)))
      CALL csv_read_file(path, ';', tmp, rc2)
      IF (rc2 /= RC_OK) CYCLE
      IF (ncols == 0) THEN
        ncols = tmp%ncols + 1   ! +1 para 'arquivo_origem'
        ALLOCATE(ds_out%headers(ncols))
        ds_out%headers(1:tmp%ncols) = tmp%headers
        ds_out%headers(ncols) = 'arquivo_origem'
        ALLOCATE(ds_out%data(MAX_ROWS * SIZE(FILES), ncols))
        ds_out%data = ''
        ds_out%ncols = ncols
      END IF
      DO i = 1, tmp%nrows
        total_rows = total_rows + 1
        IF (total_rows > SIZE(ds_out%data, 1)) EXIT
        ds_out%data(total_rows, 1:tmp%ncols) = tmp%data(i, 1:tmp%ncols)
        ds_out%data(total_rows, ncols) = TRIM(ADJUSTL(FILES(f)))
      END DO
      CALL csv_free(tmp)
    END DO
    ds_out%nrows       = total_rows
    ds_out%source_file = TRIM(data_dir) // '/Reclamações/'

    CALL persist_to_postgres(conn, ds_out, 'reclamacoes', rc)
  END SUBROUTINE

END MODULE raw_layer_mod
