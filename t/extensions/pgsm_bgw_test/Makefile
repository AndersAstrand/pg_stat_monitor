MODULE_big = pgsm_bgw_test
OBJS = pgsm_bgw_test.o
EXTENSION = pgsm_bgw_test
DATA = pgsm_bgw_test--1.0.sql
PGFILEDESC = "pgsm_bgw_test - bgworker SPI driver for pg_stat_monitor cleanup tests"

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
