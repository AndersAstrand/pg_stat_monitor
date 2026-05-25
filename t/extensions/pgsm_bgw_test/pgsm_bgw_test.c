#include "postgres.h"

#include "executor/spi.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "utils/builtins.h"
#include "utils/snapmgr.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(pgsm_bgw_run);

PGDLLEXPORT void pgsm_bgw_main(Datum main_arg);

void
pgsm_bgw_main(Datum main_arg)
{
	int32		iterations = DatumGetInt32(main_arg);
	int64		used_bytes = -1;
	int			ret;

	pqsignal(SIGTERM, SignalHandlerForShutdownRequest);
	BackgroundWorkerUnblockSignals();
	BackgroundWorkerInitializeConnection("postgres", NULL, 0);

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	SPI_connect();
	PushActiveSnapshot(GetTransactionSnapshot());

	for (int i = 0; i < iterations; i++)
	{
		ret = SPI_execute("SELECT 1", true, 0);
		if (ret != SPI_OK_SELECT)
			elog(WARNING, "pgsm_bgw_test SPI_execute failed: %d", ret);
	}

	ret = SPI_execute(
		"SELECT used_bytes FROM pg_backend_memory_contexts "
		"WHERE name = 'pg_stat_monitor local store'",
		true, 1);
	if (ret == SPI_OK_SELECT && SPI_processed == 1)
	{
		bool		isnull;
		Datum		d = SPI_getbinval(SPI_tuptable->vals[0],
									  SPI_tuptable->tupdesc, 1, &isnull);

		if (!isnull)
			used_bytes = DatumGetInt64(d);
	}

	elog(LOG, "pgsm_bgw_test: iterations=%d used_bytes=" INT64_FORMAT,
		 iterations, used_bytes);

	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();
}

Datum
pgsm_bgw_run(PG_FUNCTION_ARGS)
{
	int32		iterations = PG_GETARG_INT32(0);
	BackgroundWorker worker;
	BackgroundWorkerHandle *handle;
	BgwHandleStatus status;
	pid_t		pid;

	memset(&worker, 0, sizeof(worker));
	worker.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
	worker.bgw_restart_time = BGW_NEVER_RESTART;
	snprintf(worker.bgw_library_name, BGW_MAXLEN, "pgsm_bgw_test");
	snprintf(worker.bgw_function_name, BGW_MAXLEN, "pgsm_bgw_main");
	snprintf(worker.bgw_name, BGW_MAXLEN, "pgsm_bgw_test");
	snprintf(worker.bgw_type, BGW_MAXLEN, "pgsm_bgw_test");
	worker.bgw_main_arg = Int32GetDatum(iterations);
	worker.bgw_notify_pid = MyProcPid;

	if (!RegisterDynamicBackgroundWorker(&worker, &handle))
		ereport(ERROR,
				(errmsg("could not register pgsm_bgw_test worker")));

	status = WaitForBackgroundWorkerStartup(handle, &pid);
	if (status != BGWH_STARTED)
		ereport(ERROR,
				(errmsg("pgsm_bgw_test worker failed to start (status=%d)",
						status)));

	status = WaitForBackgroundWorkerShutdown(handle);
	if (status != BGWH_STOPPED)
		ereport(ERROR,
				(errmsg("pgsm_bgw_test worker did not stop cleanly (status=%d)",
						status)));

	PG_RETURN_BOOL(true);
}
