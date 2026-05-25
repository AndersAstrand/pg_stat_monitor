#!/usr/bin/perl

# Verifies that pg_stat_monitor's per-backend local memory context
# ('pg_stat_monitor local store') remains bounded inside background
# workers, which run many SPI statements per transaction without the
# message-boundary resets a regular backend has.
#
# The helper extension pgsm_bgw_test under t/extensions/ launches a
# one-shot dynamic bgworker that runs N "SELECT 1" SPI queries in a
# single transaction and logs used_bytes of pgsm_mem_cxt before
# committing. We run it at two iteration counts; used_bytes should be
# roughly independent of N.

use strict;
use warnings;
use File::Basename;
use Test::More;
use lib 't';
use pgsm;

PGSM::setup_files_dir(basename($0));

# The helper extension pgsm_bgw_test is built and installed by
# `make installcheck` via the top-level Makefile's REGRESS_PREP hook.
my $node   = PGSM->pgsm_init_pg();
my $pgdata = $node->data_dir;

$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_stat_monitor'");

my $rt_value = $node->start;
ok($rt_value == 1, "Start Server");

$node->safe_psql('postgres', 'CREATE EXTENSION pg_stat_monitor;');
$node->safe_psql('postgres', 'CREATE EXTENSION pgsm_bgw_test;');

# Two runs with very different N. Cleanup-working baseline emits the
# same used_bytes for both; cleanup-broken upstream scales linearly.
my $small_iter = 2000;
my $big_iter   = 20000;

# Run each bgworker and wait for its self-reported log line before
# moving on. WaitForBackgroundWorkerShutdown in the SQL function only
# guarantees the worker has exited, not that its elog(LOG, ...) has
# been flushed by the logger, so a plain post-hoc log read can race.
my $offset = 0;
$node->safe_psql('postgres', "SELECT pgsm_bgw_run($small_iter);");
$offset = $node->wait_for_log(qr/pgsm_bgw_test: iterations=$small_iter /, $offset);
$node->safe_psql('postgres', "SELECT pgsm_bgw_run($big_iter);");
$offset = $node->wait_for_log(qr/pgsm_bgw_test: iterations=$big_iter /, $offset);

# Now the lines we want are definitely on disk. Slurp the file and pull
# out both samples.
my $logfile = $node->logfile;
open my $fh, '<', $logfile or BAIL_OUT("cannot open $logfile: $!");
my %seen;
while (my $line = <$fh>)
{
	if ($line =~ /pgsm_bgw_test: iterations=(\d+) used_bytes=(-?\d+)/)
	{
		$seen{ $1 + 0 } = $2 + 0;
	}
}
close $fh;

ok(exists $seen{$small_iter}, "got log sample for $small_iter iterations")
  or diag("seen: " . join(', ', keys %seen));
ok(exists $seen{$big_iter}, "got log sample for $big_iter iterations");

SKIP: {
	skip "missing log samples", 2
	  unless exists $seen{$small_iter} and exists $seen{$big_iter};

	my $small = $seen{$small_iter};
	my $big   = $seen{$big_iter};

	diag("small=$small bytes at $small_iter iter, "
		  . "big=$big bytes at $big_iter iter");

	# Floor check: the probe SELECT pushes one entry of its own, so a
	# functioning pgsm reports nonzero used_bytes. used_bytes == 0
	# would mean pgsm never engaged in the bgworker, which makes the
	# ratio check below a false-negative.
	cmp_ok(
		$small, '>', 0,
		"bgworker exercised pgsm_mem_cxt");

	# If cleanup fires per statement, used_bytes reflects only the probe
	# SELECT's footprint and is the same at both N. If cleanup is broken,
	# the bigger run holds 10x as many leftover per-query allocations.
	# A 4x ceiling (with 32 KB additive slack for noise) keeps the test
	# robust against incidental variation while still catching a real
	# per-iteration leak.
	cmp_ok(
		$big, '<=', 4 * $small + 32 * 1024,
		"bgworker pgsm_mem_cxt does not scale with iteration count");
}

$node->stop;
done_testing();
