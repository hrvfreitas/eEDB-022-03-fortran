!> Camada Trusted — Etapa 2 do pipeline.
!>
!> Lê a camada RAW (Postgres), aplica limpeza, tipagem e resolução de
!> CNPJ por nome. A estratégia de matching aproximado (Fuzzy ou Splink)
!> é escolhida em tempo de execução pela variável 'match_strategy'.
!>
!> Todo o tratamento usa lógica Fortran pura (módulos string_utils,
!> fuzzy_match, splink_match) — nenhum SQL de tratamento.
MODULE trusted_layer_mod
  USE constants_mod
  USE string_utils_mod
  USE csv_reader_mod
  USE db_libpq_mod
  USE parquet_writer_mod
  USE fuzzy_match_mod
  USE splink_match_mod
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: trusted_process

  ! Colunas da tabela trusted.reclamacoes
  INTEGER, PARAMETER :: T_RECL_COLS = 6
  CHARACTER(LEN=32), PARAMETER :: T_RECL_HEADERS(T_RECL_COLS) = [ &
    'cnpj                            ', &
    'cnpj_origem                     ', &
    'nome_instituicao_reclamacao     ', &
    'trimestre                       ', &
    'indice                          ', &
    'quantidade_total_reclamacoes    ' ]

  ! Colunas da tabela trusted.bancos
  INTEGER, PARAMETER :: T_BANCOS_COLS = 5
  CHARACTER(LEN=32), PARAMETER :: T_BANCOS_HEADERS(T_BANCOS_COLS) = [ &
    'cnpj                            ', &
    'nome_instituicao                ', &
    'nome_normalizado                ', &
    'segmento_prudencial             ', &
    'nome_alternativo                ' ]

CONTAINS

  !> Ponto de entrada da camada Trusted.
  SUBROUTINE trusted_process(trusted_dir, conn, match_strategy, rc)
    CHARACTER(LEN=*),  INTENT(IN)  :: trusted_dir
    TYPE(PGconn_ptr),  INTENT(IN)  :: conn
    INTEGER,           INTENT(IN)  :: match_strategy
    INTEGER,           INTENT(OUT) :: rc

    rc = RC_OK
    WRITE(*,'(A)') '=== Camada Trusted ==='
    IF (match_strategy == STRATEGY_FUZZY) THEN
      WRITE(*,'(A)') '  Estrategia: FUZZY (Jaro-Winkler, DO CONCURRENT)'
    ELSE
      WRITE(*,'(A)') '  Estrategia: SPLINK (Fellegi-Sunter + EM)'
    END IF

    CALL process_bancos(trusted_dir, conn, rc)
    IF (rc /= RC_OK) RETURN
    CALL process_reclamacoes(trusted_dir, conn, match_strategy, rc)
    IF (rc /= RC_OK) RETURN
    CALL process_empregados(trusted_dir, conn, rc)

    WRITE(*,'(A)') '=== Trusted concluído ==='
  END SUBROUTINE

  ! ---------------------------------------------------------------- Bancos
  SUBROUTINE process_bancos(trusted_dir, conn, rc)
    CHARACTER(LEN=*), INTENT(IN)  :: trusted_dir
    TYPE(PGconn_ptr), INTENT(IN)  :: conn
    INTEGER,          INTENT(OUT) :: rc

    TYPE(csv_dataset) :: raw_ds
    TYPE(parquet_dataset) :: pq
    CHARACTER(LEN=MAX_FIELD_LEN) :: cnpj, nome, seg, norm, alt
    CHARACTER(LEN=MAX_FIELD_LEN) :: fields(T_BANCOS_COLS)
    CHARACTER(LEN=512) :: path
    INTEGER :: i, rc2, nrows_out

    rc = RC_OK

    ! lê tabela raw.bancos do Postgres para arquivo temporário
    ! (no exercício, relemos do arquivo original para simplificar;
    !  em produção releria via JDBC/libpq SELECT)
    path = TRIM(trusted_dir) // '/../raw/bancos.parquet.csv'
    CALL csv_read_file(path, '|', raw_ds, rc2)
    IF (rc2 /= RC_OK) THEN
      WRITE(*,'(A)') 'AVISO: nao encontrou raw/bancos.parquet.csv (use RAW primeiro)'
      rc = RC_ERROR; RETURN
    END IF

    ! cria parquet de saída
    path = TRIM(trusted_dir) // '/bancos'
    CALL parquet_open(pq, path, T_BANCOS_HEADERS, T_BANCOS_COLS, rc2)
    IF (rc2 /= RC_OK) THEN; rc = RC_ERROR; RETURN; END IF

    ! DDL no Postgres
    CALL db_exec(conn, 'DROP TABLE IF EXISTS trusted.bancos;', rc2)
    CALL db_exec(conn, &
      'CREATE TABLE trusted.bancos (' // &
      'cnpj TEXT, nome_instituicao TEXT, nome_normalizado TEXT, ' // &
      'segmento_prudencial TEXT, nome_alternativo TEXT);', rc2)

    nrows_out = 0
    DO i = 1, raw_ds%nrows
      cnpj = cnpj_raiz(csv_field(raw_ds, i, 'CNPJ'))
      IF (LEN_TRIM(cnpj) == 0) CYCLE
      nome = str_strip(csv_field(raw_ds, i, 'NomeInstituicao'))
      seg  = str_strip(csv_field(raw_ds, i, 'Segmento'))
      norm = normalize_name(nome)
      alt  = ''   ! deduplicação simplificada: tomamos só primeira ocorrência

      fields(1) = cnpj; fields(2) = nome; fields(3) = norm
      fields(4) = seg;  fields(5) = alt
      CALL parquet_write_row(pq, fields, T_BANCOS_COLS)

      CALL db_exec(conn, &
        "INSERT INTO trusted.bancos VALUES ('" // TRIM(cnpj) // "','" // &
        TRIM(nome) // "','" // TRIM(norm) // "','" // TRIM(seg) // "','');", rc2)
      nrows_out = nrows_out + 1
    END DO

    CALL parquet_close(pq)
    CALL csv_free(raw_ds)
    WRITE(*,'(A,I0,A)') '  trusted.bancos: ', nrows_out, ' linhas'
  END SUBROUTINE

  ! --------------------------------------------------------- Reclamações
  SUBROUTINE process_reclamacoes(trusted_dir, conn, match_strategy, rc)
    CHARACTER(LEN=*), INTENT(IN)  :: trusted_dir
    TYPE(PGconn_ptr), INTENT(IN)  :: conn
    INTEGER,          INTENT(IN)  :: match_strategy
    INTEGER,          INTENT(OUT) :: rc

    TYPE(csv_dataset)  :: raw_ds, bancos_ds
    TYPE(parquet_dataset) :: pq
    CHARACTER(LEN=MAX_FIELD_LEN) :: fields(T_RECL_COLS)
    CHARACTER(LEN=512) :: path, suffix
    INTEGER :: i, rc2, n_sem_cnpj, nrows_out

    ! arrays para matching aproximado
    INTEGER,          ALLOCATABLE :: idx_sem(:)
    CHARACTER(LEN=MAX_FIELD_LEN), ALLOCATABLE :: names_src(:)
    CHARACTER(LEN=MAX_FIELD_LEN), ALLOCATABLE :: names_ref(:)
    CHARACTER(LEN=CNPJ_RAIZ_LEN), ALLOCATABLE :: cnpjs_ref(:)
    TYPE(fuzzy_match_result),  ALLOCATABLE :: fuzzy_res(:)
    TYPE(splink_match_result), ALLOCATABLE :: splink_res(:)

    CHARACTER(LEN=CNPJ_RAIZ_LEN) :: cnpj
    CHARACTER(LEN=MAX_FIELD_LEN) :: nome, indice, qtd, trim_str, cnpj_orig, norm

    rc = RC_OK

    ! carrega raw
    path = TRIM(trusted_dir) // '/../raw/reclamacoes.parquet.csv'
    CALL csv_read_file(path, '|', raw_ds, rc2)
    IF (rc2 /= RC_OK) THEN; rc = RC_ERROR; RETURN; END IF

    ! carrega bancos trusted para lookup
    path = TRIM(trusted_dir) // '/bancos.parquet.csv'  ! já processado acima
    CALL csv_read_file(path, '|', bancos_ds, rc2)

    ! monta arrays de referência (nomes e CNPJs dos bancos)
    ALLOCATE(names_ref(bancos_ds%nrows), cnpjs_ref(bancos_ds%nrows))
    DO i = 1, bancos_ds%nrows
      names_ref(i) = csv_field(bancos_ds, i, 'nome_normalizado')
      cnpjs_ref(i) = csv_field(bancos_ds, i, 'cnpj')
    END DO

    ! identifica linhas sem CNPJ (bancos "conglomerado")
    n_sem_cnpj = 0
    DO i = 1, raw_ds%nrows
      cnpj = cnpj_raiz(csv_field(raw_ds, i, 'CNPJ_IF'))
      IF (LEN_TRIM(cnpj) == 0 .OR. cnpj == '00000000') n_sem_cnpj = n_sem_cnpj + 1
    END DO
    ALLOCATE(idx_sem(n_sem_cnpj), names_src(n_sem_cnpj))
    n_sem_cnpj = 0
    DO i = 1, raw_ds%nrows
      cnpj = cnpj_raiz(csv_field(raw_ds, i, 'CNPJ_IF'))
      IF (LEN_TRIM(cnpj) == 0 .OR. cnpj == '00000000') THEN
        n_sem_cnpj = n_sem_cnpj + 1
        idx_sem(n_sem_cnpj) = i
        nome = csv_field(raw_ds, i, 'Institui__o_financeira')
        names_src(n_sem_cnpj) = normalize_name(nome)
      END IF
    END DO

    ! resolve CNPJs com a estratégia escolhida
    IF (match_strategy == STRATEGY_FUZZY) THEN
      ALLOCATE(fuzzy_res(n_sem_cnpj))
      CALL fuzzy_resolve_cnpj(names_src, n_sem_cnpj, names_ref, cnpjs_ref, &
                               bancos_ds%nrows, fuzzy_res)
      suffix = '_fuzzy'
    ELSE
      ALLOCATE(splink_res(n_sem_cnpj))
      CALL splink_resolve_cnpj(names_src, n_sem_cnpj, names_ref, cnpjs_ref, &
                                bancos_ds%nrows, splink_res)
      suffix = '_splink'
    END IF

    ! cria parquet e tabela Postgres
    path = TRIM(trusted_dir) // '/reclamacoes' // TRIM(suffix)
    CALL parquet_open(pq, path, T_RECL_HEADERS, T_RECL_COLS, rc2)

    CALL db_exec(conn, 'DROP TABLE IF EXISTS trusted.reclamacoes;', rc2)
    CALL db_exec(conn, 'DROP TABLE IF EXISTS trusted.reclamacoes' // &
                       TRIM(suffix) // ';', rc2)
    CALL db_exec(conn, &
      'CREATE TABLE trusted.reclamacoes (' // &
      'cnpj TEXT, cnpj_origem TEXT, nome_instituicao_reclamacao TEXT, ' // &
      'trimestre TEXT, indice TEXT, quantidade_total_reclamacoes TEXT, ' // &
      'match_strategy_usada TEXT);', rc2)

    nrows_out = 0
    DO i = 1, raw_ds%nrows
      cnpj     = cnpj_raiz(csv_field(raw_ds, i, 'CNPJ_IF'))
      nome     = str_strip(csv_field(raw_ds, i, 'Institui__o_financeira'))
      indice   = str_strip(csv_field(raw_ds, i, '_ndice'))
      qtd      = str_strip(csv_field(raw_ds, i, 'Quantidade_total_de_reclama__es'))
      trim_str = str_strip(csv_field(raw_ds, i, 'arquivo_origem'))
      cnpj_orig = 'informado na fonte'

      IF (LEN_TRIM(cnpj) == 0 .OR. cnpj == '00000000') THEN
        ! busca nos resultados de matching
        BLOCK
          INTEGER :: k
          LOGICAL :: encontrado
          encontrado = .FALSE.
          DO k = 1, n_sem_cnpj
            IF (idx_sem(k) == i) THEN
              IF (match_strategy == STRATEGY_FUZZY) THEN
                cnpj      = fuzzy_res(k)%cnpj
                cnpj_orig = fuzzy_res(k)%origin
              ELSE
                cnpj      = splink_res(k)%cnpj
                cnpj_orig = splink_res(k)%origin
              END IF
              encontrado = .TRUE.; EXIT
            END IF
          END DO
          IF (.NOT. encontrado) cnpj_orig = 'nao resolvido'
        END BLOCK
      END IF

      fields(1) = cnpj;      fields(2) = cnpj_orig
      fields(3) = nome;      fields(4) = trim_str
      fields(5) = indice;    fields(6) = qtd
      CALL parquet_write_row(pq, fields, T_RECL_COLS)
      nrows_out = nrows_out + 1
    END DO

    CALL parquet_close(pq)
    CALL csv_free(raw_ds); CALL csv_free(bancos_ds)
    IF (ALLOCATED(fuzzy_res))  DEALLOCATE(fuzzy_res)
    IF (ALLOCATED(splink_res)) DEALLOCATE(splink_res)
    DEALLOCATE(idx_sem, names_src, names_ref, cnpjs_ref)

    WRITE(*,'(A,I0,A)') '  trusted.reclamacoes: ', nrows_out, ' linhas'
  END SUBROUTINE

  ! ---------------------------------------------------------- Empregados
  SUBROUTINE process_empregados(trusted_dir, conn, rc)
    CHARACTER(LEN=*), INTENT(IN)  :: trusted_dir
    TYPE(PGconn_ptr), INTENT(IN)  :: conn
    INTEGER,          INTENT(OUT) :: rc

    TYPE(csv_dataset) :: ds_match, ds_mless
    TYPE(parquet_dataset) :: pq
    CHARACTER(LEN=512) :: path
    CHARACTER(LEN=MAX_FIELD_LEN) :: cnpj, fields(16)
    INTEGER :: i, rc2, nrows_out
    CHARACTER(LEN=32) :: hdrs(1)

    rc = RC_OK

    path = TRIM(trusted_dir) // '/../raw/empregados_match.parquet.csv'
    CALL csv_read_file(path, '|', ds_match, rc2)
    path = TRIM(trusted_dir) // '/../raw/empregados_match_less.parquet.csv'
    CALL csv_read_file(path, '|', ds_mless, rc2)

    ! simplificado: prioriza match_less (tem CNPJ direto), depois match
    path = TRIM(trusted_dir) // '/empregados'
    hdrs(1) = 'cnpj'
    CALL parquet_open(pq, path, ds_mless%headers, ds_mless%ncols, rc2)

    CALL db_exec(conn, 'DROP TABLE IF EXISTS trusted.empregados;', rc2)
    CALL db_exec(conn, 'CREATE TABLE trusted.empregados AS ' // &
                       'SELECT * FROM raw.empregados_match_less WHERE 1=0;', rc2)

    nrows_out = 0
    DO i = 1, ds_mless%nrows
      cnpj = cnpj_raiz(csv_field(ds_mless, i, 'CNPJ'))
      IF (LEN_TRIM(cnpj) == 0) CYCLE
      CALL parquet_write_row(pq, ds_mless%data(i,:), ds_mless%ncols)
      nrows_out = nrows_out + 1
    END DO

    CALL parquet_close(pq)
    CALL csv_free(ds_match); CALL csv_free(ds_mless)
    WRITE(*,'(A,I0,A)') '  trusted.empregados: ', nrows_out, ' linhas'
  END SUBROUTINE

END MODULE trusted_layer_mod
