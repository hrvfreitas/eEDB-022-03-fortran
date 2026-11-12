!> Camada Delivery — Etapa 3 do pipeline.
!>
!> Lê as 3 tabelas Trusted (Parquet fallback CSV) e realiza o join final
!> por CNPJ em Fortran puro, gerando a tabela final:
!>   delivery.tb_reclamacoes_bancos_funcionarios
!>
!> O join é implementado como nested-loop com busca binária na tabela
!> menor (bancos está ordenado por CNPJ após sort), equivalente ao
!> broadcast join do Spark.
MODULE delivery_layer_mod
  USE constants_mod
  USE string_utils_mod
  USE csv_reader_mod
  USE db_libpq_mod
  USE parquet_writer_mod
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: delivery_build

CONTAINS

  !> Busca binária de CNPJ em array ordenado.
  !> Retorna índice ou 0 se não encontrado.
  PURE FUNCTION binary_search_cnpj(cnpjs, n, key) RESULT(idx)
    INTEGER,          INTENT(IN) :: n
    CHARACTER(LEN=*), INTENT(IN) :: cnpjs(n), key
    INTEGER :: idx
    INTEGER :: lo, hi, mid
    lo = 1; hi = n; idx = 0
    DO WHILE (lo <= hi)
      mid = (lo + hi) / 2
      IF      (cnpjs(mid) == key) THEN; idx = mid; RETURN
      ELSE IF (cnpjs(mid) <  key) THEN; lo  = mid + 1
      ELSE;                              hi  = mid - 1
      END IF
    END DO
  END FUNCTION

  !> Ordena array de CNPJs (insertion sort — n pequeno ~500 bancos).
  SUBROUTINE sort_by_cnpj(cnpjs, indices, n)
    INTEGER,          INTENT(IN)    :: n
    CHARACTER(LEN=*), INTENT(INOUT) :: cnpjs(n)
    INTEGER,          INTENT(INOUT) :: indices(n)
    CHARACTER(LEN=CNPJ_RAIZ_LEN)   :: key_c
    INTEGER :: key_i, i, j
    DO i = 2, n
      key_c = cnpjs(i); key_i = indices(i)
      j = i - 1
      DO WHILE (j >= 1 .AND. cnpjs(j) > key_c)
        cnpjs(j+1)  = cnpjs(j)
        indices(j+1) = indices(j)
        j = j - 1
      END DO
      cnpjs(j+1)  = key_c
      indices(j+1) = key_i
    END DO
  END SUBROUTINE

  !> Ponto de entrada da camada Delivery.
  SUBROUTINE delivery_build(delivery_dir, trusted_dir, conn, rc)
    CHARACTER(LEN=*), INTENT(IN)  :: delivery_dir, trusted_dir
    TYPE(PGconn_ptr), INTENT(IN)  :: conn
    INTEGER,          INTENT(OUT) :: rc

    TYPE(csv_dataset)    :: ds_recl, ds_bancos, ds_emp
    TYPE(parquet_dataset) :: pq
    CHARACTER(LEN=512)   :: path
    CHARACTER(LEN=CNPJ_RAIZ_LEN), ALLOCATABLE :: bancos_cnpjs(:)
    CHARACTER(LEN=CNPJ_RAIZ_LEN), ALLOCATABLE :: emp_cnpjs(:)
    INTEGER, ALLOCATABLE :: bancos_idx(:), emp_idx(:)
    INTEGER :: i, bi, ei, rc2, nrows_out, nb, ne

    ! cabeçalho da tabela final (seleção de colunas)
    INTEGER, PARAMETER :: N_OUT = 10
    CHARACTER(LEN=40), PARAMETER :: OUT_HEADERS(N_OUT) = [ &
      'cnpj                                    ', &
      'nome_instituicao                        ', &
      'segmento_prudencial                     ', &
      'trimestre                               ', &
      'indice                                  ', &
      'quantidade_total_reclamacoes            ', &
      'cnpj_origem                             ', &
      'nota_geral_glassdoor                    ', &
      'recomenda_empresa_pct                   ', &
      'possui_avaliacao_glassdoor              ' ]
    CHARACTER(LEN=MAX_FIELD_LEN) :: out_row(N_OUT)

    rc = RC_OK
    WRITE(*,'(A)') '=== Camada Delivery ==='

    ! lê trusted parquets (fallback CSV)
    CALL csv_read_file(TRIM(trusted_dir)//'/reclamacoes_fuzzy.parquet.csv', &
                       '|', ds_recl, rc2)
    IF (rc2 /= RC_OK) &
      CALL csv_read_file(TRIM(trusted_dir)//'/reclamacoes_splink.parquet.csv', &
                         '|', ds_recl, rc2)
    IF (rc2 /= RC_OK) THEN; rc = RC_ERROR; RETURN; END IF

    CALL csv_read_file(TRIM(trusted_dir)//'/bancos.parquet.csv', &
                       '|', ds_bancos, rc2)
    IF (rc2 /= RC_OK) THEN; rc = RC_ERROR; RETURN; END IF

    CALL csv_read_file(TRIM(trusted_dir)//'/empregados.parquet.csv', &
                       '|', ds_emp, rc2)
    ! empregados pode estar vazio — ok

    ! monta índices ordenados de bancos e empregados por CNPJ
    nb = ds_bancos%nrows
    ALLOCATE(bancos_cnpjs(nb), bancos_idx(nb))
    DO i = 1, nb
      bancos_cnpjs(i) = csv_field(ds_bancos, i, 'cnpj')
      bancos_idx(i)   = i
    END DO
    CALL sort_by_cnpj(bancos_cnpjs, bancos_idx, nb)

    ne = ds_emp%nrows
    ALLOCATE(emp_cnpjs(ne), emp_idx(ne))
    DO i = 1, ne
      emp_cnpjs(i) = cnpj_raiz(csv_field(ds_emp, i, 'CNPJ'))
      emp_idx(i)   = i
    END DO
    IF (ne > 0) CALL sort_by_cnpj(emp_cnpjs, emp_idx, ne)

    ! DDL Postgres
    CALL db_exec(conn, 'DROP TABLE IF EXISTS delivery.tb_reclamacoes_bancos_funcionarios;', rc2)
    CALL db_exec(conn, &
      'CREATE TABLE delivery.tb_reclamacoes_bancos_funcionarios (' // &
      'cnpj TEXT, nome_instituicao TEXT, segmento_prudencial TEXT, ' // &
      'trimestre TEXT, indice TEXT, quantidade_total_reclamacoes TEXT, ' // &
      'cnpj_origem TEXT, nota_geral_glassdoor TEXT, ' // &
      'recomenda_empresa_pct TEXT, possui_avaliacao_glassdoor TEXT);', rc2)

    ! abre parquet de saída
    CALL parquet_open(pq, TRIM(delivery_dir)//'/tb_reclamacoes_bancos_funcionarios', &
                      OUT_HEADERS, N_OUT, rc2)

    nrows_out = 0
    DO i = 1, ds_recl%nrows
      ! inner join com bancos
      bi = binary_search_cnpj(bancos_cnpjs, nb, csv_field(ds_recl, i, 'cnpj'))
      IF (bi == 0) CYCLE   ! sem match em bancos -> fora do Delivery

      out_row(1) = csv_field(ds_recl,   i,           'cnpj')
      out_row(2) = csv_field(ds_bancos, bancos_idx(bi), 'nome_instituicao')
      out_row(3) = csv_field(ds_bancos, bancos_idx(bi), 'segmento_prudencial')
      out_row(4) = csv_field(ds_recl,   i,           'trimestre')
      out_row(5) = csv_field(ds_recl,   i,           'indice')
      out_row(6) = csv_field(ds_recl,   i,           'quantidade_total_reclamacoes')
      out_row(7) = csv_field(ds_recl,   i,           'cnpj_origem')

      ! left join com empregados
      IF (ne > 0) THEN
        ei = binary_search_cnpj(emp_cnpjs, ne, out_row(1))
      ELSE
        ei = 0
      END IF

      IF (ei > 0) THEN
        out_row(8)  = csv_field(ds_emp, emp_idx(ei), 'nota_geral')
        out_row(9)  = csv_field(ds_emp, emp_idx(ei), 'recomenda_empresa_pct')
        out_row(10) = 'TRUE'
      ELSE
        out_row(8) = ''; out_row(9) = ''; out_row(10) = 'FALSE'
      END IF

      CALL parquet_write_row(pq, out_row, N_OUT)

      CALL db_exec(conn, &
        "INSERT INTO delivery.tb_reclamacoes_bancos_funcionarios VALUES ('" // &
        TRIM(out_row(1)) // "','" // TRIM(out_row(2)) // "','" // &
        TRIM(out_row(3)) // "','" // TRIM(out_row(4)) // "','" // &
        TRIM(out_row(5)) // "','" // TRIM(out_row(6)) // "','" // &
        TRIM(out_row(7)) // "','" // TRIM(out_row(8)) // "','" // &
        TRIM(out_row(9)) // "','" // TRIM(out_row(10)) // "');", rc2)

      nrows_out = nrows_out + 1
    END DO

    CALL parquet_close(pq)
    CALL csv_free(ds_recl); CALL csv_free(ds_bancos); CALL csv_free(ds_emp)
    DEALLOCATE(bancos_cnpjs, bancos_idx, emp_cnpjs, emp_idx)

    WRITE(*,'(A,I0,A)') '  delivery.tb_reclamacoes_bancos_funcionarios: ', &
                          nrows_out, ' linhas'
    WRITE(*,'(A)') '=== Delivery concluído ==='
  END SUBROUTINE

END MODULE delivery_layer_mod
