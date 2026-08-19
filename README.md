# eEDB-022-03-fortran

Atividade 3 — pipeline de ingestão de dados (ETL) escrito em **Fortran moderno**, que lê arquivos CSV/TSV de diferentes fontes (Reclamações, Bancos, Empregados) e os carrega em um banco **PostgreSQL**, usando a biblioteca cliente `libpq` via `ISO_C_BINDING`.

> ⚠️ **Status: projeto inacabado.** Apenas a camada **RAW** (ingestão bruta) está implementada. Faltam o programa principal (`PROGRAM`), o módulo de constantes (`constants_mod`) referenciado por todos os outros módulos, e as camadas de tratamento/curadoria dos dados. Veja a seção [O que falta](#o-que-falta) para detalhes.

## Visão geral

O objetivo do pipeline é ler três conjuntos de dados brutos de um diretório local e persistir cada um deles como tabela `TEXT` no schema `raw` de um banco Postgres, sem qualquer tratamento (é a etapa 1 de um pipeline maior, no estilo *raw → trusted → refined*, mas só a primeira etapa existe hoje):

- **Reclamações**: 7 arquivos CSV trimestrais (2021 T1–T4, 2022 T1, T3, T4), separados por `;`, concatenados em um único dataset com uma coluna extra `arquivo_origem` indicando de qual arquivo cada linha veio.
- **Bancos**: um único TSV (`EnquadramentoInicia_v2.tsv`), separado por tabulação.
- **Empregados**: dois arquivos CSV separados por `|` (`..._match_v2.csv` e `..._match_less_v2.csv`).

O código também já prevê paralelismo via **coarrays** do Fortran (processar as 3 fontes em imagens/`images` diferentes quando houver 3 ou mais disponíveis), embora essa distribução ainda não esteja de fato implementada em `raw_ingest` — o comentário no topo de `raw_layer.f90` descreve a intenção, mas a subrotina atual roda tudo sequencialmente.

## Estrutura dos arquivos

| Arquivo | Módulo | Responsabilidade |
|---|---|---|
| `string_utils.f90` | `string_utils_mod` | Funções utilitárias de string: maiúsculas (`str_upper`), trim (`str_strip`), split por separador (`str_split`), prefixo/substring (`str_starts_with`, `str_contains`), normalização de nomes para *matching* removendo acentos/pontuação (`normalize_name`), extração de raiz de CNPJ (`cnpj_raiz`) e conversão inteiro→string (`int_to_str`). |
| `csv_reader.f90` | `csv_reader_mod` | Leitor genérico de CSV/TSV. Define o tipo `csv_dataset` (cabeçalhos + matriz de strings `data(linha,coluna)`), a subrotina `csv_read_file` (lê o arquivo linha a linha, faz split pelo separador informado e pré-aloca um buffer de `MAX_ROWS`), a função `csv_field` (busca valor por nome de coluna) e `csv_free` (desaloca). |
| `db_libpq.f90` | `db_libpq_mod` | *Binding* em C (`ISO_C_BINDING`) para a `libpq` do PostgreSQL: `PQconnectdb`, `PQstatus`, `PQexec`, `PQresultStatus`, `PQclear`, `PQfinish`, `PQntuples`, `PQgetvalue`. Expõe `db_connect`, `db_exec` (comandos sem retorno de linhas), `db_exec_query` (SELECT simplificado, só conta linhas) e `db_close`. |
| `raw_layer.f90` | `raw_layer_mod` | Orquestra a camada RAW. `raw_ingest` é o ponto de entrada: lê cada fonte com `csv_read_file` e grava no Postgres com `persist_to_postgres`, que faz `DROP TABLE` + `CREATE TABLE` dinâmico (todas as colunas como `TEXT`, nomes sanitizados por `normalize_col_name`) e depois insere linha a linha com `INSERT` (o comentário no código já reconhece que, em produção, o ideal seria usar `COPY` em vez de inserts individuais). `ingest_reclamacoes` concatena os 7 arquivos trimestrais de Reclamações. |
| `.gitignore` | — | Ignora artefatos de build. |
| `LICENSE` | — | GPL-3.0. |

### Fluxo de dependências entre módulos

```
constants_mod   (❌ ausente — ver "O que falta")
   ├── string_utils_mod
   │       └── csv_reader_mod
   ├── db_libpq_mod
   └── raw_layer_mod  (usa string_utils_mod, csv_reader_mod, db_libpq_mod)
```

## O que falta

O repositório, hoje, **não compila sozinho** e não é executável de ponta a ponta. Faltam pelo menos:

1. **`constants_mod`** — módulo referenciado por `USE constants_mod` em `csv_reader.f90`, `db_libpq.f90`, `string_utils.f90` e `raw_layer.f90`, mas que não existe no repositório. Ele precisaria definir, no mínimo:
   - `MAX_FIELD_LEN`, `MAX_LINE_LEN`, `MAX_COLS`, `MAX_ROWS` (dimensionamento estático usado no leitor de CSV)
   - `RC_OK`, `RC_ERROR` (códigos de retorno usados em todo o pipeline)
   - `CNPJ_RAIZ_LEN` (usado em `cnpj_raiz`, em `string_utils.f90`)
2. **Programa principal (`PROGRAM`)** — não há nenhum `.f90` com um bloco `PROGRAM`/`END PROGRAM` que chame `raw_ingest`, abra a conexão via `db_connect` e passe o diretório de dados. Os módulos existentes são todos bibliotecas (`MODULE`), sem um ponto de entrada executável.
3. **Camadas seguintes do pipeline** — o comentário de `raw_layer.f90` descreve a RAW como a "Etapa 1", sugerindo etapas posteriores de tratamento/curadoria dos dados (ex.: normalização usando `normalize_name`/`cnpj_raiz`, que já existem em `string_utils_mod` mas ainda não são chamadas em lugar nenhum do pipeline).
4. **Paralelismo com coarrays** — mencionado no cabeçalho de `raw_layer.f90` como estratégia para dividir as 3 fontes entre *images*, mas `raw_ingest` atualmente processa tudo sequencialmente na image 1.
5. **Build system** — não há `Makefile`/`CMakeLists.txt`; a compilação precisa ser feita manualmente (ver abaixo).

## Compilação (quando completo)

O projeto depende da biblioteca cliente do PostgreSQL (`libpq`) e de um compilador Fortran com suporte a `ISO_C_BINDING` (e a coarrays, se essa parte for implementada). Com `gfortran`, a compilação dos módulos existentes seguiria algo como:

```bash
gfortran -c string_utils.f90 csv_reader.f90 db_libpq.f90 raw_layer.f90 \
  -I$(pg_config --includedir) 

gfortran *.o -o pipeline -lpq -L$(pg_config --libdir)
```

Isso ainda vai falhar até que `constants_mod` exista e um `PROGRAM` seja adicionado ao projeto.

## Licença

Distribuído sob a licença [GPL-3.0](LICENSE).
