#!/usr/bin/perl

# Verifies that pg_stat_monitor's per-backend local memory context
# ('pg_stat_monitor local store') returns to baseline after each
# cleanup path. The paths exercised are a top-level error, a utility
# statement that never reaches the executor, a loop of EXCEPTION
# handler subtransaction aborts, and a loop of explicit SAVEPOINT
# subtransaction aborts inside a single multi-statement transaction.
#
# The probe reads used_bytes from pg_backend_memory_contexts. Because
# the probe SELECT itself runs through the hooks, the baseline is the
# probe's own footprint rather than zero.

use strict;
use warnings;
use File::Basename;
use Test::More;
use lib 't';
use pgsm;

PGSM::setup_files_dir(basename($0));

my $node = PGSM->pgsm_init_pg();
my $pgdata = $node->data_dir;

$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_stat_monitor'");

my $rt_value = $node->start;
ok($rt_value == 1, "Start Server");

# Every probe and every cleanup trigger must run in the same backend,
# because pg_backend_memory_contexts is per-process. Drive the whole
# scenario through a single psql invocation.
my $sql = <<'SQL';
CREATE EXTENSION pg_stat_monitor;
SELECT pg_stat_monitor_reset();

-- Warm the probe so the first measurement reflects steady state.
SELECT used_bytes FROM pg_backend_memory_contexts
 WHERE name = 'pg_stat_monitor local store';

\echo TAG:BASELINE
SELECT used_bytes FROM pg_backend_memory_contexts
 WHERE name = 'pg_stat_monitor local store';

-- Path 1: top-level error -> XACT_EVENT_ABORT.
SELECT 1/0;

\echo TAG:AFTER_ERROR
SELECT used_bytes FROM pg_backend_memory_contexts
 WHERE name = 'pg_stat_monitor local store';

-- Path 2: substatement parsed but never executed -> end-of-statement reset.
CREATE TABLE pgsm_cleanup_t (a int);
CREATE VIEW  pgsm_cleanup_v AS SELECT * FROM pgsm_cleanup_t;
DROP VIEW    pgsm_cleanup_v;
DROP TABLE   pgsm_cleanup_t;

\echo TAG:AFTER_VIEW
SELECT used_bytes FROM pg_backend_memory_contexts
 WHERE name = 'pg_stat_monitor local store';

-- Path 3: DO with many EXCEPTION subxacts. Cleanup happens at DO end.
DO $$
BEGIN
    FOR i IN 1..5000 LOOP
        BEGIN
            PERFORM 1/0;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
    END LOOP;
END $$;

\echo TAG:AFTER_DO
SELECT used_bytes FROM pg_backend_memory_contexts
 WHERE name = 'pg_stat_monitor local store';

-- Path 4: explicit SAVEPOINT subxact aborts inside one outer transaction.
-- Unlike Path 3, each subxact abort happens between top-level statements
-- in the same transaction rather than inside a single utility wrapper, so
-- this exercises the case where the bottom-of-hook reset for the next
-- statement (the ROLLBACK TO) is what reclaims the leaked entry.
BEGIN;
SAVEPOINT s1; SELECT 1/0;
ROLLBACK TO s1;
SAVEPOINT s2; SELECT 1/0;
ROLLBACK TO s2;
SAVEPOINT s3; SELECT 1/0;
ROLLBACK TO s3;
SAVEPOINT s4; SELECT 1/0;
ROLLBACK TO s4;
SAVEPOINT s5; SELECT 1/0;
ROLLBACK TO s5;
COMMIT;

\echo TAG:AFTER_SAVEPOINTS
SELECT used_bytes FROM pg_backend_memory_contexts
 WHERE name = 'pg_stat_monitor local store';
SQL

my ($cmdret, $stdout, $stderr) = $node->psql(
	'postgres', $sql,
	on_error_stop => 0,
	extra_params  => [ '-t', '-A' ]);

# Pull the bytes value that follows each TAG line.
sub extract_after_tag
{
	my ($tag, $text) = @_;
	if ($text =~ /^TAG:\Q$tag\E\s*\n(\d+)\s*$/m)
	{
		return $1 + 0;
	}
	return undef;
}

my $baseline         = extract_after_tag('BASELINE',         $stdout);
my $after_error      = extract_after_tag('AFTER_ERROR',      $stdout);
my $after_view       = extract_after_tag('AFTER_VIEW',       $stdout);
my $after_do         = extract_after_tag('AFTER_DO',         $stdout);
my $after_savepoints = extract_after_tag('AFTER_SAVEPOINTS', $stdout);

ok(defined $baseline,         "baseline probe extracted")
  or diag("stdout was:\n$stdout\nstderr was:\n$stderr");
ok(defined $after_error,      "after-error probe extracted");
ok(defined $after_view,       "after-view probe extracted");
ok(defined $after_do,         "after-DO probe extracted");
ok(defined $after_savepoints, "after-savepoints probe extracted");

# Each cleanup trigger should leave the local context at roughly the
# baseline used_bytes (which is just the probe SELECT's own footprint).
# 8 KB headroom absorbs incidental variation (catalog cache warmup,
# small differences in palloc rounding between probes) while still
# catching a real per-iteration leak in the DO path: 5000 iterations
# allocating even ~100 bytes apiece would land at ~500 KB.
my $tolerance = 8 * 1024;

SKIP: {
	skip "baseline probe missing", 4 unless defined $baseline;

	cmp_ok(
		abs($after_error - $baseline), '<=', $tolerance,
		"top-level error: local context returns to baseline (delta="
		  . ($after_error - $baseline) . ")");

	cmp_ok(
		abs($after_view - $baseline), '<=', $tolerance,
		"CREATE VIEW: local context returns to baseline (delta="
		  . ($after_view - $baseline) . ")");

	cmp_ok(
		abs($after_do - $baseline), '<=', $tolerance,
		"DO/EXCEPTION loop: local context returns to baseline (delta="
		  . ($after_do - $baseline) . ")");

	cmp_ok(
		abs($after_savepoints - $baseline), '<=', $tolerance,
		"SAVEPOINT loop: local context returns to baseline (delta="
		  . ($after_savepoints - $baseline) . ")");
}

$node->stop;
done_testing();
