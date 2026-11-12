!> Constantes globais usadas por todos os módulos do pipeline.
MODULE constants_mod
  IMPLICIT NONE

  ! Tamanhos de buffer
  INTEGER, PARAMETER :: MAX_LINE_LEN   = 8192
  INTEGER, PARAMETER :: MAX_FIELD_LEN  = 512
  INTEGER, PARAMETER :: MAX_COLS       = 64
  INTEGER, PARAMETER :: MAX_ROWS       = 50000

  ! CNPJ raiz
  INTEGER, PARAMETER :: CNPJ_RAIZ_LEN  = 8

  ! Estratégias de matching
  INTEGER, PARAMETER :: STRATEGY_FUZZY  = 1
  INTEGER, PARAMETER :: STRATEGY_SPLINK = 2

  ! Thresholds
  REAL,    PARAMETER :: FUZZY_THRESHOLD  = 0.88
  REAL,    PARAMETER :: SPLINK_THRESHOLD = 0.85

  ! Códigos de retorno
  INTEGER, PARAMETER :: RC_OK    = 0
  INTEGER, PARAMETER :: RC_ERROR = 1

END MODULE constants_mod
