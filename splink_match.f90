!> Matching probabilístico de nomes (Fellegi-Sunter) implementado em
!> Fortran puro — equivalente simplificado do que o Splink faz.
!>
!> Algoritmo:
!>   1. Gera pares candidatos com blocking rule (mesma inicial).
!>   2. Para cada par, calcula um vetor de comparação gamma com
!>      base no Jaro-Winkler (3 níveis: 0=não-match, 1=parcial, 2=match).
!>   3. Treina os pesos m/u via Expectation-Maximization (EM) iterativo.
!>   4. Calcula log-odds e probabilidade de match para cada par.
!>   5. Aceita o match com maior probabilidade >= SPLINK_THRESHOLD.
!>
!> Paralelizado com DO CONCURRENT nos loops de comparação e nas
!> iterações do E-step do EM.
MODULE splink_match_mod
  USE constants_mod
  USE string_utils_mod
  USE fuzzy_match_mod, ONLY: jaro_winkler
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: splink_match_result, splink_resolve_cnpj

  TYPE :: splink_match_result
    CHARACTER(LEN=CNPJ_RAIZ_LEN) :: cnpj     = ''
    REAL                          :: prob     = 0.0
    LOGICAL                       :: matched  = .FALSE.
    CHARACTER(LEN=64)             :: origin   = ''
  END TYPE

  ! ---- parâmetros do modelo EM ----
  INTEGER, PARAMETER :: N_LEVELS   = 3       !< níveis de gamma: 0,1,2
  INTEGER, PARAMETER :: EM_ITER    = 20      !< iterações máximas
  REAL,    PARAMETER :: EM_TOL     = 1.0E-5  !< convergência
  REAL,    PARAMETER :: LAMBDA_INI = 0.1     !< prior P(match)

  ! Thresholds de Jaro-Winkler para níveis de gamma
  REAL, PARAMETER :: GAMMA_HIGH = 0.90
  REAL, PARAMETER :: GAMMA_MID  = 0.70

CONTAINS

  !> Converte score Jaro-Winkler em nível gamma {0,1,2}.
  PURE FUNCTION gamma_level(score) RESULT(g)
    REAL, INTENT(IN) :: score
    INTEGER :: g
    IF      (score >= GAMMA_HIGH) THEN; g = 2
    ELSE IF (score >= GAMMA_MID)  THEN; g = 1
    ELSE;                               g = 0
    END IF
  END FUNCTION

  !> Treina os parâmetros m (P(gamma|match)) e u (P(gamma|não-match))
  !> via Expectation-Maximization.
  SUBROUTINE em_train(gammas, n_pairs, m_out, u_out, lambda_out)
    INTEGER, INTENT(IN)  :: n_pairs
    INTEGER, INTENT(IN)  :: gammas(n_pairs)    !< vetor de gammas dos pares
    REAL,    INTENT(OUT) :: m_out(0:N_LEVELS-1) !< P(gamma|match)
    REAL,    INTENT(OUT) :: u_out(0:N_LEVELS-1) !< P(gamma|nao-match)
    REAL,    INTENT(OUT) :: lambda_out          !< P(match)

    ! parâmetros iniciais
    REAL :: m(0:N_LEVELS-1), u(0:N_LEVELS-1), lambda
    REAL :: m_new(0:N_LEVELS-1), u_new(0:N_LEVELS-1), lambda_new
    REAL :: p_match(n_pairs)  !< E[match | gamma, params]
    REAL :: log_odds, p, denom
    INTEGER :: iter, i, g

    ! inicialização razoável para 3 níveis
    m = [0.05, 0.10, 0.85]   ! match quase sempre = gamma 2
    u = [0.75, 0.15, 0.10]   ! nao-match domina gamma 0
    lambda = LAMBDA_INI

    DO iter = 1, EM_ITER

      ! ---- E-step: calcula P(match|gamma_i) para cada par ----
      DO CONCURRENT (i = 1:n_pairs) LOCAL(g, log_odds, p, denom)
        g        = gammas(i)
        log_odds = LOG(lambda / (1.0 - lambda + 1.0E-12)) + &
                   LOG(m(g) / (u(g) + 1.0E-12))
        p        = 1.0 / (1.0 + EXP(-log_odds))
        p_match(i) = p
      END DO

      ! ---- M-step: atualiza parâmetros ----
      lambda_new = SUM(p_match) / REAL(n_pairs)
      m_new = 0.0; u_new = 0.0
      DO i = 1, n_pairs
        g = gammas(i)
        m_new(g) = m_new(g) + p_match(i)
        u_new(g) = u_new(g) + (1.0 - p_match(i))
      END DO
      denom = SUM(p_match) + 1.0E-12
      m_new = m_new / denom
      denom = REAL(n_pairs) - SUM(p_match) + 1.0E-12
      u_new = u_new / denom

      ! normaliza para garantir que soma a 1 em cada nível
      m_new = m_new / (SUM(m_new) + 1.0E-12)
      u_new = u_new / (SUM(u_new) + 1.0E-12)

      ! convergência
      IF (MAXVAL(ABS(m_new - m)) < EM_TOL .AND. &
          MAXVAL(ABS(u_new - u)) < EM_TOL) EXIT

      m = m_new; u = u_new; lambda = lambda_new
    END DO

    m_out      = m
    u_out      = u
    lambda_out = lambda
  END SUBROUTINE

  !> Para cada nome em 'names_src', encontra o melhor match probabilístico
  !> em 'names_ref' seguindo o fluxo Fellegi-Sunter + EM:
  !>
  !>  1) blocking por inicial (reduz pares candidatos de O(n*m) para O(n*k))
  !>  2) computa gammas para os pares bloqueados
  !>  3) treina m/u via EM sobre esses gammas
  !>  4) calcula probabilidade de match e escolhe o melhor por src
  SUBROUTINE splink_resolve_cnpj(names_src, n_src, names_ref, cnpjs_ref, &
                                   n_ref, results)
    INTEGER,          INTENT(IN)  :: n_src, n_ref
    CHARACTER(LEN=*), INTENT(IN)  :: names_src(n_src)
    CHARACTER(LEN=*), INTENT(IN)  :: names_ref(n_ref)
    CHARACTER(LEN=*), INTENT(IN)  :: cnpjs_ref(n_ref)
    TYPE(splink_match_result), INTENT(OUT) :: results(n_src)

    ! arrays de pares candidatos (blocking reduz drasticamente o total)
    INTEGER, ALLOCATABLE :: pair_i(:), pair_j(:)
    INTEGER, ALLOCATABLE :: gammas(:)
    INTEGER :: n_pairs, max_pairs
    INTEGER :: i, j, k
    REAL    :: sc
    CHARACTER(LEN=1) :: ini_src, ini_ref

    ! parâmetros EM treinados
    REAL :: m_param(0:N_LEVELS-1), u_param(0:N_LEVELS-1), lambda_param

    ! probabilidades finais por par
    REAL,    ALLOCATABLE :: probs(:)
    REAL    :: best_prob, log_odds, prob
    INTEGER :: best_j
    CHARACTER(LEN=8) :: prob_str
    CHARACTER(LEN=MAX_FIELD_LEN) :: norm_src, norm_ref

    ! ---- 1. Blocking + cálculo de gammas ----
    max_pairs = n_src * MIN(n_ref, 500)   ! estimativa conservadora
    ALLOCATE(pair_i(max_pairs), pair_j(max_pairs), gammas(max_pairs))
    n_pairs = 0

    DO i = 1, n_src
      norm_src = normalize_name(names_src(i))
      IF (LEN_TRIM(norm_src) == 0) CYCLE
      ini_src = norm_src(1:1)
      DO j = 1, n_ref
        norm_ref = normalize_name(names_ref(j))
        IF (LEN_TRIM(norm_ref) == 0) CYCLE
        ini_ref = norm_ref(1:1)
        ! blocking rule: mesma letra inicial
        IF (ini_src /= ini_ref) CYCLE
        n_pairs = n_pairs + 1
        IF (n_pairs > max_pairs) THEN
          n_pairs = max_pairs; EXIT
        END IF
        pair_i(n_pairs) = i
        pair_j(n_pairs) = j
        sc = jaro_winkler(TRIM(norm_src), TRIM(norm_ref))
        gammas(n_pairs) = gamma_level(sc)
      END DO
    END DO

    IF (n_pairs == 0) THEN
      ! nenhum par bloqueado: sem match para ninguém
      DO i = 1, n_src
        results(i)%matched = .FALSE.
        results(i)%origin  = 'nao resolvido (sem pares bloqueados)'
      END DO
      DEALLOCATE(pair_i, pair_j, gammas); RETURN
    END IF

    ! ---- 2. Treina m/u via EM ----
    CALL em_train(gammas(1:n_pairs), n_pairs, m_param, u_param, lambda_param)

    ! ---- 3. Calcula probabilidade de match para cada par ----
    ALLOCATE(probs(n_pairs))
    DO CONCURRENT (k = 1:n_pairs) LOCAL(log_odds, prob)
      log_odds = LOG(lambda_param / (1.0 - lambda_param + 1.0E-12)) + &
                 LOG(m_param(gammas(k)) / (u_param(gammas(k)) + 1.0E-12))
      probs(k) = 1.0 / (1.0 + EXP(-log_odds))
    END DO

    ! ---- 4. Seleciona melhor par por src (maior probabilidade) ----
    ! (loop serial: escrita em results(pair_i(k)) pode colidir em
    !  concurrent -> usamos loop serial simples aqui)
    results%matched = .FALSE.; results%prob = 0.0; results%cnpj = ''

    DO k = 1, n_pairs
      i = pair_i(k)
      IF (probs(k) > results(i)%prob) THEN
        results(i)%prob   = probs(k)
        results(i)%cnpj   = cnpjs_ref(pair_j(k))
        results(i)%matched = (probs(k) >= SPLINK_THRESHOLD)
        IF (results(i)%matched) THEN
          WRITE(prob_str, '(F5.3)') probs(k)
          results(i)%origin = 'splink match, prob=' // TRIM(prob_str)
        ELSE
          results(i)%origin = 'nao resolvido'
        END IF
      END IF
    END DO

    DEALLOCATE(pair_i, pair_j, gammas, probs)
  END SUBROUTINE

END MODULE splink_match_mod
