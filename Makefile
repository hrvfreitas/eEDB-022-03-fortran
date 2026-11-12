# =============================================================================
# Makefile — Pipeline ETL em Fortran 2023
# =============================================================================
#
# Compiladores suportados:
#   FC=gfortran   (GFortran >= 12, recomendado >= 14 para DO CONCURRENT paralelo)
#   FC=ifx        (Intel Fortran llvm-based, >= 2024.0)
#
# Dependências do sistema:
#   libpq-dev   (sudo apt install libpq-dev  /  brew install libpq)
#   libcoarrays (sudo apt install libcoarrays-dev  —  só se FC=gfortran+coarray)
#
# Targets:
#   make            -> compila com gfortran, estrategia FUZZY, single-image
#   make FC=ifx     -> compila com Intel ifx
#   make STRATEGY=SPLINK -> fixa estrategia em tempo de compilação
#   make coarray    -> compila com suporte a coarrays MPI (requer OpenMPI)
#   make clean      -> remove binários e .mod
# =============================================================================

FC      ?= gfortran
STRATEGY ?= FUZZY      # FUZZY | SPLINK  (overrideable em compile-time)

# ---- flags comuns ----
FFLAGS_BASE = -std=f2018 -O2 -Wall -Wextra -fimplicit-none
CPPFLAGS    = -DSTRATEGY=$(STRATEGY)

# ---- libpq ----
PG_CFLAGS   := $(shell pg_config --includedir 2>/dev/null | sed 's/^/-I/')
PG_LIBS     := $(shell pg_config --libdir     2>/dev/null | sed 's/^/-L/')
LDFLAGS     = $(PG_LIBS) -lpq

# ---- flags por compilador ----
ifeq ($(FC),gfortran)
  FFLAGS_EXTRA = -fcoarray=single -cpp
  # para coarray MPI: use `make coarray`
  COARRAY_FLAGS = -fcoarray=lib
  COARRAY_LIBS  = -lcaf_mpi
  CONCURRENT_FLAGS = -fdo-concurrent-parallel=auto   # GFortran >= 14
else ifeq ($(FC),ifx)
  FFLAGS_EXTRA = -coarray=single -fpp -DSTRATEGY=$(STRATEGY)
  COARRAY_FLAGS = -coarray=distributed
  COARRAY_LIBS  = -lmpi
  CONCURRENT_FLAGS = -parallel
else
  FFLAGS_EXTRA =
endif

FFLAGS = $(FFLAGS_BASE) $(FFLAGS_EXTRA) $(PG_CFLAGS)

# ---- fontes em ordem de dependência (módulos primeiro) ----
SRCS = src/constants.f90     \
       src/string_utils.f90  \
       src/csv_reader.f90    \
       src/db_libpq.f90      \
       src/parquet_writer.f90 \
       src/fuzzy_match.f90   \
       src/splink_match.f90  \
       src/raw_layer.f90     \
       src/trusted_layer.f90 \
       src/delivery_layer.f90 \
       src/pipeline.F90

TARGET = pipeline_etl

.PHONY: all coarray parallel clean run run-splink help

all: $(TARGET)

$(TARGET): $(SRCS)
	@echo ">>> Compilando com FC=$(FC), STRATEGY=$(STRATEGY)"
	$(FC) $(FFLAGS) $(CPPFLAGS) $^ -o $@ $(LDFLAGS)
	@echo ">>> Binário: $(TARGET)"

# coarray com OpenMPI (paralelismo distribuído real)
coarray: $(SRCS)
	@echo ">>> Compilando com coarrays MPI"
	$(FC) $(FFLAGS_BASE) $(COARRAY_FLAGS) $(PG_CFLAGS) $(CPPFLAGS) \
	      $^ -o $(TARGET)_coarray $(LDFLAGS) $(COARRAY_LIBS)
	@echo ">>> Para rodar com N images: cafrun -n N ./$(TARGET)_coarray"

# habilita paralelismo automático em DO CONCURRENT (GFortran >= 14 / ifx)
parallel: $(SRCS)
	@echo ">>> Compilando com DO CONCURRENT paralelo"
	$(FC) $(FFLAGS_BASE) $(FFLAGS_EXTRA) $(CONCURRENT_FLAGS) \
	      $(PG_CFLAGS) $(CPPFLAGS) $^ -o $(TARGET)_parallel $(LDFLAGS)

clean:
	rm -f $(TARGET) $(TARGET)_coarray $(TARGET)_parallel *.mod *.smod

# ---- conveniências de execução ----
run: $(TARGET)
	MATCH_STRATEGY=fuzzy ./$(TARGET)

run-splink: $(TARGET)
	MATCH_STRATEGY=splink ./$(TARGET)

help:
	@echo ""
	@echo "  make                       # fuzzy, single-image"
	@echo "  make STRATEGY=SPLINK       # splink fixo em compile-time"
	@echo "  make FC=ifx                # Intel Fortran"
	@echo "  make coarray               # coarray MPI (paralelo distribuído)"
	@echo "  make parallel              # DO CONCURRENT automático"
	@echo "  make run                   # roda com MATCH_STRATEGY=fuzzy"
	@echo "  make run-splink            # roda com MATCH_STRATEGY=splink"
	@echo "  MATCH_STRATEGY=splink ./pipeline_etl   # runtime override"
	@echo ""
