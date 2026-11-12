# Atividade 3 — Pipeline ETL em **Fortran 2023** (exercício acadêmico)

- **Antonio Daniel de Souza Linhares**
- **Yuri Alexandre Barbosa Rodrigues**
- **Hercules Ramos Veloso de Freitas**

> **Aviso honesto:** este repositório é um exercício acadêmico que demonstra
> que é *tecnicamente possível* implementar um pipeline ETL completo em
> Fortran 2023. Ele **não substitui** o pipeline Python+Spark
> ([eEDB-022-03-spark](../eEDB-022-03-spark)) para nenhum cenário de produção.
> O valor aqui é didático: entender o que as abstrações modernas fazem por
> baixo, implementando-as do zero.

## O que este repositório demonstra

| Conceito moderno | Equivalente Fortran 2023 usado aqui |
|---|---|
| `spark.read.csv` | Leitor CSV genérico em `csv_reader.f90` (Fortran puro) |
| DataFrame / Schema | `csv_dataset` (TYPE com arrays alocáveis) |
| Spark distributed join | Join nested-loop + busca binária em `delivery_layer.f90` |
| `mapInPandas` / UDF | `DO CONCURRENT` com cláusula `LOCAL` em `fuzzy_match.f90` |
| RapidFuzz | Jaro-Winkler implementado do zero em `fuzzy_match.f90` |
| Splink (Python) | Fellegi-Sunter + EM implementado do zero em `splink_match.f90` |
| Spark coalesce/partitions | Coarray images (`THIS_IMAGE()`, `NUM_IMAGES()`, `SYNC ALL`) |
| JDBC → Postgres | ISO_C_BINDING → libpq em `db_libpq.f90` |
| Parquet | Fallback CSV anotado em `parquet_writer.f90` (Arrow via C binding: extensão futura) |
| `--match-strategy` flag | Variável de ambiente `MATCH_STRATEGY` + flag `-DSTRATEGY=` CPP |

## Estrutura de arquivos

```
src/
  constants.f90       constantes globais (thresholds, tamanhos de buffer)
  string_utils.f90    trim, split, normalização de nomes, CNPJ raiz
  csv_reader.f90      leitor CSV/TSV genérico (csv_dataset)
  db_libpq.f90        ISO_C_BINDING → libpq (connect, exec, close)
  parquet_writer.f90  escritor Parquet (fallback CSV; Arrow: extensão futura)
  fuzzy_match.f90     Jaro-Winkler + DO CONCURRENT (estratégia FUZZY)
  splink_match.f90    Fellegi-Sunter + EM (estratégia SPLINK)
  raw_layer.f90       Etapa 1: ingestão RAW
  trusted_layer.f90   Etapa 2: limpeza, tipagem, resolução de CNPJ
  delivery_layer.f90  Etapa 3: join final, tabela Delivery
  pipeline.F90        programa principal (.F90 = CPP ativo)
Makefile
Dockerfile
docker-compose.yml
setup_database.sql
```

## Estratégia de matching: FUZZY vs SPLINK

A resolução de CNPJ dos bancos "conglomerado" (por nome, quando o cruzamento
exato falha) pode usar **uma das duas estratégias**:

| Estratégia | Implementação | Fortran usado |
|---|---|---|
| `FUZZY` (default) | Jaro-Winkler, aceita score ≥ 0.88 | `DO CONCURRENT` com `LOCAL` paralleliza o loop de comparação |
| `SPLINK` | Fellegi-Sunter + Expectation-Maximization | `DO CONCURRENT` no E-step; loop serial no M-step (escrita compartilhada) |

### Escolher a estratégia

**Em tempo de execução** (variável de ambiente — tem prioridade):
```bash
MATCH_STRATEGY=fuzzy  ./pipeline_etl
MATCH_STRATEGY=splink ./pipeline_etl
```

**Em tempo de compilação** (flag CPP — fixada no binário):
```bash
make STRATEGY=FUZZY    # default
make STRATEGY=SPLINK
```

**Via Docker Compose**:
```bash
STRATEGY=SPLINK MATCH_STRATEGY=splink docker compose up --build
```

## Como compilar e rodar

### Dependências

```bash
# Debian/Ubuntu
sudo apt install gfortran libpq-dev libcoarrays-dev make

# macOS (Homebrew)
brew install gcc libpq open-coarrays make
```

> GFortran >= 12 para Fortran 2018 completo.  
> GFortran >= 14 para `DO CONCURRENT` com `-fdo-concurrent-parallel=auto`.  
> Intel `ifx` >= 2024.0 também suportado (ver Makefile).

### Compilar

```bash
# default: fuzzy, single-image coarray
make

# splink fixo no binário
make STRATEGY=SPLINK

# com paralelismo automático em DO CONCURRENT (GFortran >= 14)
make parallel

# com coarrays MPI (paralelismo distribuído entre images)
make coarray
# rodar com 3 images (uma por fonte de dados):
cafrun -n 3 ./pipeline_etl_coarray
```

### Rodar

```bash
# coloque os dados em data/raw/origem/
# (pastas Reclamações/, Bancos/, Empregados/ — mesmo layout dos repos anteriores)

make run           # MATCH_STRATEGY=fuzzy
make run-splink    # MATCH_STRATEGY=splink

# ou diretamente:
DB_HOST=localhost DB_USER=postgres DB_PASSWORD=postgres \
  MATCH_STRATEGY=splink ./pipeline_etl
```

### Docker Compose (mais fácil)

```bash
# fuzzy (default)
docker compose up --build

# splink
STRATEGY=SPLINK MATCH_STRATEGY=splink docker compose up --build
```

## O que o pipeline produz

```
data/raw/             espelho das fontes (CSV "raw")
data/trusted/         tabelas tratadas (Parquet fallback CSV)
  bancos.parquet.csv
  reclamacoes_fuzzy.parquet.csv   (ou _splink)
  empregados.parquet.csv
data/delivery/
  tb_reclamacoes_bancos_funcionarios.parquet.csv

Postgres:
  raw.reclamacoes, raw.bancos, raw.empregados_match, raw.empregados_match_less
  trusted.bancos, trusted.reclamacoes, trusted.empregados
  delivery.tb_reclamacoes_bancos_funcionarios
```

## Por que Fortran 2023 e não Fortran 77?

| Feature usada | Padrão mínimo |
|---|---|
| `TYPE` (structs) | Fortran 90 |
| Arrays alocáveis | Fortran 90 |
| `GET_ENVIRONMENT_VARIABLE` | Fortran 2003 |
| `ISO_C_BINDING` (libpq) | Fortran 2003 |
| `NEWUNIT=` no OPEN | Fortran 2008 |
| `THIS_IMAGE()`, `NUM_IMAGES()`, `SYNC ALL` (coarrays) | Fortran 2008 |
| `DO CONCURRENT` | Fortran 2008 |
| `DO CONCURRENT` com `LOCAL`, `REDUCE` | Fortran 2018 |
| Pré-processador CPP via `.F90` | Extensão portável (todos os compiladores modernos) |

## Custo real de desenvolvimento

O pipeline Python+Spark equivalente ([eEDB-022-03-spark](../eEDB-022-03-spark))
tem ~600 linhas de código. Esta versão Fortran tem ~1.400 linhas — a maioria
sendo infraestrutura (parser CSV, binding libpq, escritor Parquet) que em
Python vem de pacotes. Se a camada Parquet fosse implementada via Arrow C
binding completo (em vez do fallback CSV), adicionaria ~300 linhas de binding.

A vantagem do Fortran apareceria se o kernel de matching (Jaro-Winkler sobre
bilhões de pares) fosse o gargalo: compilado com `-O3 -march=native` e
`DO CONCURRENT` paralelo, ele provavelmente superaria o Python em throughput
puro de CPU, sem overhead de JVM (Spark) ou GIL (Python). Para o volume deste
case (~700 linhas de saída), a diferença é imperceptível.
