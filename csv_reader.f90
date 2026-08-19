!> Leitor de CSV/TSV genérico.
!> Lê arquivos linha a linha, divide pelos separadores configurados,
!> retorna os dados como arrays de strings alocáveis.
MODULE csv_reader_mod
  USE constants_mod
  USE string_utils_mod
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: csv_dataset, csv_read_file, csv_field, csv_free

  !> Representa um arquivo CSV carregado em memória.
  TYPE :: csv_dataset
    INTEGER :: nrows = 0
    INTEGER :: ncols = 0
    CHARACTER(LEN=MAX_FIELD_LEN), ALLOCATABLE :: headers(:)      !< nomes das colunas
    CHARACTER(LEN=MAX_FIELD_LEN), ALLOCATABLE :: data(:,:)       !< data(row, col)
    CHARACTER(LEN=256)            :: source_file = ''
  END TYPE

CONTAINS

  !> Lê um arquivo CSV/TSV completo para um csv_dataset.
  !> sep: separador (ex.: ';', TAB=CHAR(9), '|')
  !> skip_empty: ignora linhas sem dados
  SUBROUTINE csv_read_file(filename, sep, dataset, rc)
    CHARACTER(LEN=*),   INTENT(IN)    :: filename, sep
    TYPE(csv_dataset),  INTENT(OUT)   :: dataset
    INTEGER,            INTENT(OUT)   :: rc

    INTEGER  :: unit, ios, row
    CHARACTER(LEN=MAX_LINE_LEN)       :: line
    CHARACTER(LEN=MAX_FIELD_LEN)      :: fields(MAX_COLS)
    INTEGER  :: nf
    CHARACTER(LEN=MAX_FIELD_LEN), ALLOCATABLE :: buf(:,:)
    CHARACTER(LEN=MAX_FIELD_LEN), ALLOCATABLE :: hdr_buf(:)

    rc  = RC_OK
    row = 0

    OPEN(NEWUNIT=unit, FILE=TRIM(filename), STATUS='OLD', &
         ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      WRITE(*,'(A,A)') 'ERRO: nao foi possivel abrir ', TRIM(filename)
      rc = RC_ERROR; RETURN
    END IF

    ! -- lê cabeçalho
    READ(unit, '(A)', IOSTAT=ios) line
    IF (ios /= 0) THEN
      rc = RC_ERROR; CLOSE(unit); RETURN
    END IF
    CALL str_split(line, sep, fields, nf)
    ALLOCATE(hdr_buf(nf))
    hdr_buf(1:nf) = fields(1:nf)

    ! -- pré-aloca buffer de dados
    ALLOCATE(buf(MAX_ROWS, nf))
    buf = ''

    ! -- lê linhas de dados
    DO
      READ(unit, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (LEN_TRIM(line) == 0) CYCLE
      CALL str_split(line, sep, fields, nf)
      row = row + 1
      IF (row > MAX_ROWS) THEN
        WRITE(*,'(A,I0,A)') 'AVISO: arquivo excede MAX_ROWS=', MAX_ROWS, &
                              ', truncando.'
        row = MAX_ROWS; EXIT
      END IF
      buf(row, 1:nf) = fields(1:nf)
    END DO
    CLOSE(unit)

    dataset%nrows       = row
    dataset%ncols       = SIZE(hdr_buf)
    dataset%source_file = TRIM(filename)
    ALLOCATE(dataset%headers(dataset%ncols))
    ALLOCATE(dataset%data(dataset%nrows, dataset%ncols))
    dataset%headers = hdr_buf
    dataset%data    = buf(1:row, 1:dataset%ncols)

    DEALLOCATE(buf, hdr_buf)
  END SUBROUTINE

  !> Retorna o valor de um campo pelo nome da coluna.
  !> Retorna string vazia se a coluna não existir.
  FUNCTION csv_field(ds, row, colname) RESULT(val)
    TYPE(csv_dataset),  INTENT(IN) :: ds
    INTEGER,            INTENT(IN) :: row
    CHARACTER(LEN=*),   INTENT(IN) :: colname
    CHARACTER(LEN=MAX_FIELD_LEN)   :: val
    INTEGER :: j
    val = ''
    DO j = 1, ds%ncols
      IF (TRIM(ds%headers(j)) == TRIM(colname)) THEN
        val = ds%data(row, j); RETURN
      END IF
    END DO
  END FUNCTION

  !> Libera memória alocada por um csv_dataset.
  SUBROUTINE csv_free(ds)
    TYPE(csv_dataset), INTENT(INOUT) :: ds
    IF (ALLOCATED(ds%headers)) DEALLOCATE(ds%headers)
    IF (ALLOCATED(ds%data))    DEALLOCATE(ds%data)
    ds%nrows = 0; ds%ncols = 0
  END SUBROUTINE

END MODULE csv_reader_mod
