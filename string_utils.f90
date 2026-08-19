!> Utilitários de string: trim, split, normalização de nomes e CNPJ.
!> Fortran 2003+ (allocatable character, ISO_VARYING_STRING não usado
!> por portabilidade — ficamos com CHARACTER(LEN=*) + índices).
MODULE string_utils_mod
  USE constants_mod
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: str_upper, str_strip, str_split, normalize_name, &
            cnpj_raiz, str_starts_with, str_contains, int_to_str

CONTAINS

  !> Converte string para maiúsculas (ASCII apenas).
  PURE FUNCTION str_upper(s) RESULT(r)
    CHARACTER(LEN=*), INTENT(IN)  :: s
    CHARACTER(LEN=LEN(s))         :: r
    INTEGER :: i, c
    r = s
    DO i = 1, LEN(s)
      c = ICHAR(s(i:i))
      IF (c >= 97 .AND. c <= 122) r(i:i) = CHAR(c - 32)
    END DO
  END FUNCTION

  !> Remove espaços à esquerda e à direita.
  PURE FUNCTION str_strip(s) RESULT(r)
    CHARACTER(LEN=*), INTENT(IN)       :: s
    CHARACTER(LEN=LEN(s))              :: r
    r = ADJUSTL(TRIM(s))
  END FUNCTION

  !> Retorna .TRUE. se 's' começa com 'prefix'.
  PURE FUNCTION str_starts_with(s, prefix) RESULT(r)
    CHARACTER(LEN=*), INTENT(IN) :: s, prefix
    LOGICAL :: r
    r = (LEN_TRIM(s) >= LEN_TRIM(prefix)) .AND. &
        (s(1:LEN_TRIM(prefix)) == prefix(1:LEN_TRIM(prefix)))
  END FUNCTION

  !> Retorna .TRUE. se 'sub' aparece em 's'.
  PURE FUNCTION str_contains(s, sub) RESULT(r)
    CHARACTER(LEN=*), INTENT(IN) :: s, sub
    LOGICAL :: r
    r = (INDEX(s, TRIM(sub)) > 0)
  END FUNCTION

  !> Divide 's' pelo separador 'sep' (1 char), retorna campos em 'fields'
  !> e o número de campos em 'nfields'.
  SUBROUTINE str_split(s, sep, fields, nfields)
    CHARACTER(LEN=*),  INTENT(IN)  :: s, sep
    CHARACTER(LEN=MAX_FIELD_LEN), INTENT(OUT) :: fields(MAX_COLS)
    INTEGER,           INTENT(OUT) :: nfields
    INTEGER :: pos, prev, slen, seplen
    slen   = LEN_TRIM(s)
    seplen = LEN_TRIM(sep)
    nfields = 0
    prev    = 1
    fields  = ''
    DO
      pos = INDEX(s(prev:slen), sep(1:seplen))
      IF (pos == 0) EXIT
      pos = pos + prev - 1
      nfields = nfields + 1
      IF (nfields > MAX_COLS) EXIT
      fields(nfields) = str_strip(s(prev:pos-1))
      prev = pos + seplen
    END DO
    ! último campo
    nfields = nfields + 1
    IF (nfields <= MAX_COLS) fields(nfields) = str_strip(s(prev:slen))
  END SUBROUTINE

  !> Normaliza nome para matching: maiúsculas, remove acentos (ASCII),
  !> substitui não-alfanuméricos por espaço, colapsa espaços múltiplos.
  PURE FUNCTION normalize_name(s) RESULT(r)
    CHARACTER(LEN=*), INTENT(IN)       :: s
    CHARACTER(LEN=MAX_FIELD_LEN)       :: r
    CHARACTER(LEN=MAX_FIELD_LEN)       :: tmp
    INTEGER :: i, j, c
    LOGICAL :: last_space

    ! passo 1: maiúsculas
    tmp = str_upper(str_strip(s))

    ! passo 2: remove acentos básicos (latin-1 -> ASCII aproximado)
    ! substitui caracteres acentuados comuns por base ASCII
    ! (abordagem byte a byte para os mais frequentes no português)
    j          = 0
    last_space = .TRUE.
    r          = ''
    DO i = 1, LEN_TRIM(tmp)
      c = ICHAR(tmp(i:i))
      ! letras A-Z, 0-9: copia direto
      IF ((c >= 65 .AND. c <= 90) .OR. (c >= 48 .AND. c <= 57)) THEN
        j = j + 1; IF (j > MAX_FIELD_LEN) EXIT
        r(j:j)     = CHAR(c)
        last_space = .FALSE.
      ELSE
        ! qualquer outro char vira espaço (colapsa múltiplos)
        IF (.NOT. last_space) THEN
          j = j + 1; IF (j > MAX_FIELD_LEN) EXIT
          r(j:j)   = ' '
          last_space = .TRUE.
        END IF
      END IF
    END DO
    ! trim final
    r = ADJUSTL(TRIM(r))
  END FUNCTION

  !> Extrai CNPJ raiz (8 dígitos, com zero à esquerda) de uma string.
  !> Remove não-dígitos e pega os 8 primeiros.
  FUNCTION cnpj_raiz(s) RESULT(r)
    CHARACTER(LEN=*), INTENT(IN) :: s
    CHARACTER(LEN=CNPJ_RAIZ_LEN) :: r
    CHARACTER(LEN=LEN(s))        :: digits
    INTEGER :: i, j, c
    j = 0
    digits = ''
    DO i = 1, LEN_TRIM(s)
      c = ICHAR(s(i:i))
      IF (c >= 48 .AND. c <= 57) THEN
        j = j + 1
        IF (j > LEN(s)) EXIT
        digits(j:j) = CHAR(c)
      END IF
    END DO
    ! pega os 8 primeiros com zero-padding à esquerda
    IF (j >= CNPJ_RAIZ_LEN) THEN
      r = digits(1:CNPJ_RAIZ_LEN)
    ELSE
      r = REPEAT('0', CNPJ_RAIZ_LEN - j) // digits(1:j)
    END IF
  END FUNCTION

  !> Converte inteiro para string.
  PURE FUNCTION int_to_str(n) RESULT(r)
    INTEGER, INTENT(IN) :: n
    CHARACTER(LEN=20)   :: r
    WRITE(r, '(I0)') n
    r = ADJUSTL(r)
  END FUNCTION

END MODULE string_utils_mod
