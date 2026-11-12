!> Escritor de Parquet simplificado via Apache Arrow C Data Interface.
!>
!> Em um ambiente de produção, isto usaria a lib C do Arrow
!> (libarrow, libarrow_dataset) via ISO_C_BINDING. Para manter o
!> exercício compilável sem depender do Arrow instalado, este módulo
!> implementa um FALLBACK em CSV quando a lib não está disponível,
!> controlado pela flag de compilação -DARROW_AVAILABLE.
!>
!> A interface pública é a mesma nos dois casos, isolando o restante
!> do código dessa dependência.
MODULE parquet_writer_mod
  USE constants_mod
  USE string_utils_mod
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: parquet_dataset, parquet_open, parquet_write_row, parquet_close

  TYPE :: parquet_dataset
    INTEGER           :: unit    = -1
    INTEGER           :: nrows   = 0
    CHARACTER(LEN=512) :: path   = ''
    LOGICAL           :: is_open = .FALSE.
  END TYPE

CONTAINS

  !> Abre (cria) um arquivo de saída da camada.
  !> Com -DARROW_AVAILABLE: escreve Parquet via Arrow C API.
  !> Sem a flag: escreve CSV anotado (fallback portável).
  SUBROUTINE parquet_open(ds, path, headers, ncols, rc)
    TYPE(parquet_dataset), INTENT(OUT) :: ds
    CHARACTER(LEN=*),      INTENT(IN)  :: path
    CHARACTER(LEN=*),      INTENT(IN)  :: headers(:)
    INTEGER,               INTENT(IN)  :: ncols
    INTEGER,               INTENT(OUT) :: rc
    INTEGER :: j

#ifdef ARROW_AVAILABLE
    ! TODO: inicializar ArrowSchema + ArrowArray via C binding
    ! (exercício deixado como extensão)
    WRITE(*,'(A)') '[parquet] Arrow backend: não implementado neste exercício'
    rc = RC_ERROR
#else
    ! fallback: CSV com extensão .parquet.csv para deixar explícito
    ds%path = TRIM(path) // '.csv'
    OPEN(NEWUNIT=ds%unit, FILE=TRIM(ds%path), STATUS='REPLACE', &
         ACTION='WRITE', IOSTAT=rc)
    IF (rc /= 0) RETURN
    ! cabeçalho
    DO j = 1, ncols
      IF (j > 1) WRITE(ds%unit, '(A)', ADVANCE='NO') '|'
      WRITE(ds%unit, '(A)', ADVANCE='NO') TRIM(headers(j))
    END DO
    WRITE(ds%unit, *)
    ds%is_open = .TRUE.
    rc = RC_OK
#endif
  END SUBROUTINE

  !> Escreve uma linha de dados.
  SUBROUTINE parquet_write_row(ds, fields, ncols)
    TYPE(parquet_dataset), INTENT(INOUT) :: ds
    CHARACTER(LEN=*),      INTENT(IN)    :: fields(:)
    INTEGER,               INTENT(IN)    :: ncols
    INTEGER :: j
    IF (.NOT. ds%is_open) RETURN
    DO j = 1, ncols
      IF (j > 1) WRITE(ds%unit, '(A)', ADVANCE='NO') '|'
      WRITE(ds%unit, '(A)', ADVANCE='NO') TRIM(fields(j))
    END DO
    WRITE(ds%unit, *)
    ds%nrows = ds%nrows + 1
  END SUBROUTINE

  !> Fecha o arquivo e libera recursos.
  SUBROUTINE parquet_close(ds)
    TYPE(parquet_dataset), INTENT(INOUT) :: ds
    IF (ds%is_open) CLOSE(ds%unit)
    ds%is_open = .FALSE.
    WRITE(*,'(A,A,A,I0,A)') '[parquet] escrito: ', TRIM(ds%path), &
                              ' (', ds%nrows, ' linhas)'
  END SUBROUTINE

END MODULE parquet_writer_mod
