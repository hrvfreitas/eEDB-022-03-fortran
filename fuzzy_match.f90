!> Fuzzy matching de nomes via Jaro-Winkler, implementado em Fortran puro.
!>
!> Paralelizado com DO CONCURRENT (Fortran 2008+): cada candidato é
!> comparado com a lista de referência de forma independente, o que
!> permite ao compilador vetorizar ou distribuir os comparações
!> (com -fdo-concurrent-parallel=auto no GFortran >=14, ou
!>  -parallel no Intel ifx).
MODULE fuzzy_match_mod
  USE constants_mod
  USE string_utils_mod
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: jaro_winkler, fuzzy_resolve_cnpj, fuzzy_match_result

  TYPE :: fuzzy_match_result
    CHARACTER(LEN=CNPJ_RAIZ_LEN) :: cnpj     = ''
    REAL                          :: score    = 0.0
    LOGICAL                       :: matched  = .FALSE.
    CHARACTER(LEN=64)             :: origin   = ''   !< "fuzzy match, score=N"
  END TYPE

CONTAINS

  !> Calcula a similaridade de Jaro entre duas strings.
  !> Retorna valor entre 0.0 (nenhuma semelhança) e 1.0 (idênticas).
  PURE FUNCTION jaro(s1, s2) RESULT(sim)
    CHARACTER(LEN=*), INTENT(IN) :: s1, s2
    REAL :: sim
    INTEGER :: l1, l2, match_dist, matches, transpositions
    INTEGER :: i, j, last
    LOGICAL, ALLOCATABLE :: m1(:), m2(:)
    CHARACTER(LEN=MAX_FIELD_LEN) :: t1, t2  ! transposição

    l1 = LEN_TRIM(s1); l2 = LEN_TRIM(s2)
    IF (l1 == 0 .AND. l2 == 0) THEN; sim = 1.0; RETURN; END IF
    IF (l1 == 0 .OR.  l2 == 0) THEN; sim = 0.0; RETURN; END IF

    match_dist   = MAX(l1, l2) / 2 - 1
    IF (match_dist < 0) match_dist = 0

    ALLOCATE(m1(l1), m2(l2))
    m1 = .FALSE.; m2 = .FALSE.
    matches = 0

    DO i = 1, l1
      DO j = MAX(1, i - match_dist), MIN(l2, i + match_dist)
        IF (.NOT. m2(j) .AND. s1(i:i) == s2(j:j)) THEN
          m1(i) = .TRUE.; m2(j) = .TRUE.
          matches = matches + 1; EXIT
        END IF
      END DO
    END DO

    IF (matches == 0) THEN; sim = 0.0; DEALLOCATE(m1, m2); RETURN; END IF

    ! transposições
    transpositions = 0; last = 0; t1 = ''; t2 = ''
    j = 0
    DO i = 1, l1
      IF (m1(i)) THEN; j = j + 1; t1(j:j) = s1(i:i); END IF
    END DO
    j = 0
    DO i = 1, l2
      IF (m2(i)) THEN; j = j + 1; t2(j:j) = s2(i:i); END IF
    END DO
    DO i = 1, matches
      IF (t1(i:i) /= t2(i:i)) transpositions = transpositions + 1
    END DO

    sim = (REAL(matches)/REAL(l1) + REAL(matches)/REAL(l2) + &
           REAL(matches - transpositions/2)/REAL(matches)) / 3.0

    DEALLOCATE(m1, m2)
  END FUNCTION

  !> Calcula a similaridade de Jaro-Winkler entre duas strings.
  !> Dá peso extra para prefixos comuns (até 4 caracteres).
  PURE FUNCTION jaro_winkler(s1, s2) RESULT(sim)
    CHARACTER(LEN=*), INTENT(IN) :: s1, s2
    REAL :: sim
    REAL :: j_sim
    INTEGER :: prefix, max_prefix
    REAL, PARAMETER :: P = 0.1   ! fator de escala Winkler

    j_sim = jaro(s1, s2)
    IF (j_sim < 0.7) THEN; sim = j_sim; RETURN; END IF

    max_prefix = MIN(4, LEN_TRIM(s1), LEN_TRIM(s2))
    prefix = 0
    DO prefix = 0, max_prefix - 1
      IF (s1(prefix+1:prefix+1) /= s2(prefix+1:prefix+1)) EXIT
    END DO

    sim = j_sim + REAL(prefix) * P * (1.0 - j_sim)
  END FUNCTION

  !> Para cada nome em 'names_src', encontra o melhor match em
  !> 'names_ref' e retorna o CNPJ correspondente se o score >= threshold.
  !>
  !> DO CONCURRENT permite que o compilador paralelize o loop externo
  !> (cada linha é independente — sem escrita compartilhada, pois cada
  !> iteração escreve em results(i) exclusivo).
  SUBROUTINE fuzzy_resolve_cnpj(names_src, n_src, names_ref, cnpjs_ref, &
                                  n_ref, results)
    INTEGER,          INTENT(IN)  :: n_src, n_ref
    CHARACTER(LEN=*), INTENT(IN)  :: names_src(n_src)
    CHARACTER(LEN=*), INTENT(IN)  :: names_ref(n_ref)
    CHARACTER(LEN=*), INTENT(IN)  :: cnpjs_ref(n_ref)
    TYPE(fuzzy_match_result), INTENT(OUT) :: results(n_src)

    INTEGER :: i, j
    REAL    :: sc, best_sc
    INTEGER :: best_j
    CHARACTER(LEN=8) :: score_str

    ! Fortran 2023: DO CONCURRENT com LOCAL garante que best_sc, best_j,
    ! sc e score_str são variáveis locais de cada iteração paralela.
    DO CONCURRENT (i = 1:n_src) &
        LOCAL(j, sc, best_sc, best_j, score_str)

      best_sc = -1.0; best_j = 0
      DO j = 1, n_ref
        sc = jaro_winkler( &
               TRIM(normalize_name(names_src(i))), &
               TRIM(normalize_name(names_ref(j))) )
        IF (sc > best_sc) THEN
          best_sc = sc; best_j = j
        END IF
      END DO

      IF (best_sc >= FUZZY_THRESHOLD .AND. best_j > 0) THEN
        results(i)%cnpj    = cnpjs_ref(best_j)
        results(i)%score   = best_sc
        results(i)%matched = .TRUE.
        WRITE(score_str, '(F5.3)') best_sc
        results(i)%origin  = 'fuzzy match, score=' // TRIM(score_str)
      ELSE
        results(i)%cnpj    = ''
        results(i)%score   = best_sc
        results(i)%matched = .FALSE.
        results(i)%origin  = 'nao resolvido'
      END IF
    END DO
  END SUBROUTINE

END MODULE fuzzy_match_mod
