CREATE FUNCTION pgsm_bgw_run(iterations int) RETURNS bool
AS 'MODULE_PATHNAME', 'pgsm_bgw_run'
LANGUAGE C STRICT;
