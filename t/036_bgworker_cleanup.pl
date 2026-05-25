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

# Build and install the helper extension.
my $ext_dir   = 't/extensions/pgsm_bgw_test';
my $pg_config = `which pg_config`;
chomp $pg_config;
$pg_config
  or BAIL_OUT("pg_config not on PATH");
system(
	"make -C $ext_dir -s USE_PGXS=1 PG_CONFIG=$pg_config install") == 0
  or BAIL_OUT("failed to build helper extension at $ext_dir");

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

$node->safe_psql('postgres', "SELECT pgsm_bgw_run($small_iter);");
$node->safe_psql('postgres', "SELECT pgsm_bgw_run($big_iter);");

# Read the server log and pull out the bgworker's self-reported sizes.
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
	skip "missing log samples", 1
	  unless exists $seen{$small_iter} and exists $seen{$big_iter};

	my $small = $seen{$small_iter};
	my $big   = $seen{$big_iter};

	diag("small=$small bytes at $small_iter iter, "
		  . "big=$big bytes at $big_iter iter");

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
