FROM debian:bookworm-slim

ARG STRATEGY=FUZZY

# gfortran + libpq + libcoarrays
RUN apt-get update && apt-get install -y --no-install-recommends \
    gfortran \
    libpq-dev \
    postgresql-client \
    libcoarrays-dev \
    make \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/pipeline

COPY src/       ./src/
COPY Makefile   .
COPY setup_database.sql .

# compila com a estratégia passada como build arg
RUN make STRATEGY=${STRATEGY}

# aguarda Postgres e roda (estratégia pode ser sobrescrita via env em runtime)
CMD ["sh", "-c", "until pg_isready -h $DB_HOST -p $DB_PORT -U $DB_USER; do sleep 2; done && ./pipeline_etl"]
