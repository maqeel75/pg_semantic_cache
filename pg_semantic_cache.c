/*-------------------------------------------------------------------------
 *
 * pg_semantic_cache.c
 *		PostgreSQL extension for semantic query result caching
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "fmgr.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "lib/stringinfo.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"
#include "utils/array.h"
#include "utils/numeric.h"
#include "catalog/pg_type.h"

#ifdef PG_MODULE_MAGIC
PG_MODULE_MAGIC;
#endif

/* Function declarations */
PG_FUNCTION_INFO_V1(init_schema);
PG_FUNCTION_INFO_V1(cache_query);
PG_FUNCTION_INFO_V1(get_cached_result);
PG_FUNCTION_INFO_V1(invalidate_cache);
PG_FUNCTION_INFO_V1(cache_stats);
PG_FUNCTION_INFO_V1(cache_hit_rate);
PG_FUNCTION_INFO_V1(evict_expired);
PG_FUNCTION_INFO_V1(evict_lru);
PG_FUNCTION_INFO_V1(clear_cache);
PG_FUNCTION_INFO_V1(auto_evict);
PG_FUNCTION_INFO_V1(log_cache_access);
PG_FUNCTION_INFO_V1(get_cost_savings);

/* Helper functions */
static void execute_sql(const char *query)
{
	int ret = SPI_execute(query, false, 0);
	if (ret < 0)
		elog(ERROR, "SPI_execute failed: %d", ret);
}

static char *
pg_escape_string(const char *str)
{
	size_t len = strlen(str);
	char *result = palloc(len * 2 + 3);
	size_t i, j = 0;
	
	result[j++] = '\'';
	
	for (i = 0; i < len; i++)
	{
		if (str[i] == '\'')
		{
			result[j++] = '\'';
			result[j++] = '\'';
		}
		else if (str[i] == '\\')
		{
			result[j++] = '\\';
			result[j++] = '\\';
		}
		else
		{
			result[j++] = str[i];
		}
	}
	
	result[j++] = '\'';
	result[j] = '\0';
	
	return result;
}

/* Initialize schema */
Datum
init_schema(PG_FUNCTION_ARGS)
{
	const char *sql =
		"CREATE TABLE IF NOT EXISTS semantic_cache.cache_entries ("
		"  id BIGSERIAL PRIMARY KEY,"
		"  query_hash TEXT NOT NULL UNIQUE,"
		"  query_text TEXT NOT NULL,"
		"  query_embedding vector(1536),"
		"  result_data JSONB NOT NULL,"
		"  result_size_bytes INTEGER,"
		"  created_at TIMESTAMPTZ DEFAULT NOW(),"
		"  last_accessed_at TIMESTAMPTZ DEFAULT NOW(),"
		"  access_count INTEGER DEFAULT 0,"
		"  ttl_seconds INTEGER,"
		"  expires_at TIMESTAMPTZ,"
		"  tags TEXT[]"
		");"
		"CREATE INDEX IF NOT EXISTS idx_cache_embedding "
		"  ON semantic_cache.cache_entries "
		"  USING ivfflat (query_embedding vector_cosine_ops) WITH (lists = 100);"
		"CREATE TABLE IF NOT EXISTS semantic_cache.cache_metadata ("
		"  id SERIAL PRIMARY KEY,"
		"  total_hits BIGINT DEFAULT 0,"
		"  total_misses BIGINT DEFAULT 0,"
		"  total_cost_saved NUMERIC(12,6) DEFAULT 0.0"
		");"
		"INSERT INTO semantic_cache.cache_metadata (id) VALUES (1) ON CONFLICT (id) DO NOTHING;"
		"CREATE TABLE IF NOT EXISTS semantic_cache.cache_config ("
		"  key TEXT PRIMARY KEY, value TEXT"
		");"
		"CREATE TABLE IF NOT EXISTS semantic_cache.cache_access_log ("
		"  id BIGSERIAL PRIMARY KEY,"
		"  access_time TIMESTAMPTZ DEFAULT NOW(),"
		"  query_hash TEXT,"
		"  cache_hit BOOLEAN NOT NULL,"
		"  similarity_score REAL,"
		"  query_cost NUMERIC(10,6),"
		"  cost_saved NUMERIC(10,6)"
		");"
		"CREATE INDEX IF NOT EXISTS idx_access_log_time "
		"  ON semantic_cache.cache_access_log(access_time);"
		"CREATE INDEX IF NOT EXISTS idx_access_log_hash "
		"  ON semantic_cache.cache_access_log(query_hash);";
	
	SPI_connect();
	execute_sql(sql);
	SPI_finish();
	
	PG_RETURN_VOID();
}

/* Cache a query */
Datum
cache_query(PG_FUNCTION_ARGS)
{
	text *query_text;
	text *emb_text;
	Jsonb *result;
	int32 ttl;
	bool has_tags;
	char *qstr, *estr, *rstr;
	char *qesc, *eesc, *resc;
	StringInfoData buf;
	int ret;
	int64 cache_id = 0;
	SPIPlanPtr plan;
	Oid argtypes[7];
	Datum values[7];
	char nulls[7];
	int nargs;
	
	query_text = PG_GETARG_TEXT_PP(0);
	emb_text = PG_GETARG_TEXT_PP(1);
	result = PG_GETARG_JSONB_P(2);
	ttl = PG_ARGISNULL(3) ? 3600 : PG_GETARG_INT32(3);
	has_tags = !PG_ARGISNULL(4);
	
	qstr = text_to_cstring(query_text);
	estr = text_to_cstring(emb_text);
	rstr = JsonbToCString(NULL, &result->root, VARSIZE(result));
	
	qesc = pg_escape_string(qstr);
	eesc = pg_escape_string(estr);
	resc = pg_escape_string(rstr);
	
	initStringInfo(&buf);
	
	/* Use parameterized query for tags */
	if (has_tags)
	{
		appendStringInfo(&buf,
			"INSERT INTO semantic_cache.cache_entries "
			"(query_hash, query_text, query_embedding, result_data, "
			" result_size_bytes, ttl_seconds, expires_at, tags) "
			"VALUES (md5(%s), %s, %s::vector, %s::jsonb, %d, %d, "
			"NOW() + interval '%d seconds', $1) "
			"ON CONFLICT (query_hash) DO UPDATE SET "
			"  last_accessed_at = NOW(), "
			"  access_count = semantic_cache.cache_entries.access_count + 1 "
			"RETURNING id",
			qesc, qesc, eesc, resc, (int)strlen(rstr), ttl, ttl);
		
		/* Prepare with tags parameter */
		argtypes[0] = TEXTARRAYOID;
		values[0] = PG_GETARG_DATUM(4);
		nulls[0] = ' ';
		nargs = 1;
	}
	else
	{
		appendStringInfo(&buf,
			"INSERT INTO semantic_cache.cache_entries "
			"(query_hash, query_text, query_embedding, result_data, "
			" result_size_bytes, ttl_seconds, expires_at) "
			"VALUES (md5(%s), %s, %s::vector, %s::jsonb, %d, %d, "
			"NOW() + interval '%d seconds') "
			"ON CONFLICT (query_hash) DO UPDATE SET "
			"  last_accessed_at = NOW(), "
			"  access_count = semantic_cache.cache_entries.access_count + 1 "
			"RETURNING id",
			qesc, qesc, eesc, resc, (int)strlen(rstr), ttl, ttl);
		
		nargs = 0;
	}
	
	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "cache_query: SPI_connect failed");
	
	if (nargs > 0)
	{
		ret = SPI_execute_with_args(buf.data, nargs, argtypes, values, nulls, false, 0);
	}
	else
	{
		ret = SPI_execute(buf.data, false, 0);
	}
	
	if (ret < 0)
		elog(ERROR, "cache_query: SPI_execute failed: %d", ret);
	
	if ((ret == SPI_OK_INSERT_RETURNING || ret == SPI_OK_UPDATE_RETURNING) && 
	    SPI_processed > 0)
	{
		bool isnull;
		Datum val = SPI_getbinval(SPI_tuptable->vals[0], 
		                          SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
			cache_id = DatumGetInt64(val);
	}
	
	SPI_finish();
	
	pfree(qstr);
	pfree(estr);
	pfree(rstr);
	pfree(qesc);
	pfree(eesc);
	pfree(resc);
	pfree(buf.data);
	
	if (cache_id == 0)
		elog(ERROR, "cache_query: Failed to get cache ID");
	
	PG_RETURN_INT64(cache_id);
}

/* Retrieve cached result */
Datum
get_cached_result(PG_FUNCTION_ARGS)
{
	text *emb_text = PG_GETARG_TEXT_PP(0);
	float4 threshold = PG_ARGISNULL(1) ? 0.95 : PG_GETARG_FLOAT4(1);
	char *estr = text_to_cstring(emb_text);
	StringInfoData buf;
	TupleDesc tupdesc;
	Datum values[4];
	bool nulls[4];
	int ret;
	
	initStringInfo(&buf);
	
	appendStringInfo(&buf,
		"SELECT true, result_data, "
		"       1 - (query_embedding <=> '%s'::vector) as sim, "
		"       EXTRACT(EPOCH FROM (NOW() - created_at))::integer as age "
		"FROM semantic_cache.cache_entries "
		"WHERE (expires_at IS NULL OR expires_at > NOW()) "
		"  AND 1 - (query_embedding <=> '%s'::vector) >= %f "
		"ORDER BY query_embedding <=> '%s'::vector "
		"LIMIT 1",
		estr, estr, threshold, estr);
	
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in wrong context")));
	
	tupdesc = BlessTupleDesc(tupdesc);
	
	SPI_connect();
	ret = SPI_execute(buf.data, true, 0);
	
	if (ret != SPI_OK_SELECT || SPI_processed == 0)
	{
		SPI_finish();
		pfree(estr);
		pfree(buf.data);
		PG_RETURN_NULL();
	}
	
	values[0] = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &nulls[0]);
	values[1] = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &nulls[1]);
	
	/* Fix similarity score extraction */
	Datum sim_datum = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 3, &nulls[2]);
	values[2] = Float4GetDatum((float4)DatumGetFloat8(sim_datum));
	
	values[3] = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 4, &nulls[3]);
	
	SPI_finish();
	pfree(estr);
	pfree(buf.data);
	
	HeapTuple tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/* Get cache statistics */
Datum
cache_stats(PG_FUNCTION_ARGS)
{
	TupleDesc tupdesc;
	Datum values[4] = {Int64GetDatum(0), Int64GetDatum(0), Int64GetDatum(0), Float4GetDatum(0.0)};
	bool nulls[4] = {false};
	
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in wrong context")));
	
	tupdesc = BlessTupleDesc(tupdesc);
	
	SPI_connect();
	int ret = SPI_execute("SELECT COUNT(*) FROM semantic_cache.cache_entries", true, 0);
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		bool isnull;
		values[0] = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
	}
	SPI_finish();
	
	HeapTuple tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/* Stub functions */
Datum invalidate_cache(PG_FUNCTION_ARGS) { PG_RETURN_INT64(0); }
Datum cache_hit_rate(PG_FUNCTION_ARGS) { PG_RETURN_FLOAT4(0.0); }
Datum evict_expired(PG_FUNCTION_ARGS) 
{
	SPI_connect();
	execute_sql("DELETE FROM semantic_cache.cache_entries WHERE expires_at <= NOW()");
	int64 d = SPI_processed;
	SPI_finish();
	PG_RETURN_INT64(d);
}
Datum evict_lru(PG_FUNCTION_ARGS) { PG_RETURN_INT64(0); }
Datum clear_cache(PG_FUNCTION_ARGS) 
{
	SPI_connect();
	execute_sql("DELETE FROM semantic_cache.cache_entries");
	int64 d = SPI_processed;
	SPI_finish();
	PG_RETURN_INT64(d);
}
Datum auto_evict(PG_FUNCTION_ARGS) { PG_RETURN_INT64(0); }

/* Log cache access */
Datum
log_cache_access(PG_FUNCTION_ARGS)
{
	text *query_hash_text = PG_ARGISNULL(0) ? NULL : PG_GETARG_TEXT_PP(0);
	bool cache_hit = PG_GETARG_BOOL(1);
	float4 similarity = PG_ARGISNULL(2) ? 0.0 : PG_GETARG_FLOAT4(2);
	float8 query_cost = 0.0;

	/* Convert numeric to float8 */
	if (!PG_ARGISNULL(3))
	{
		Numeric num = PG_GETARG_NUMERIC(3);
		query_cost = DatumGetFloat8(DirectFunctionCall1(numeric_float8, NumericGetDatum(num)));
	}

	char *query_hash = query_hash_text ? text_to_cstring(query_hash_text) : NULL;
	float8 cost_saved = cache_hit ? query_cost : 0.0;

	StringInfoData buf;
	initStringInfo(&buf);

	if (query_hash)
	{
		char *qh_esc = pg_escape_string(query_hash);
		appendStringInfo(&buf,
			"INSERT INTO semantic_cache.cache_access_log "
			"(query_hash, cache_hit, similarity_score, query_cost, cost_saved) "
			"VALUES (%s, %s, %.6f::real, %.6f::numeric, %.6f::numeric)",
			qh_esc,
			cache_hit ? "'t'" : "'f'",
			similarity,
			query_cost,
			cost_saved);
		pfree(qh_esc);
	}
	else
	{
		appendStringInfo(&buf,
			"INSERT INTO semantic_cache.cache_access_log "
			"(cache_hit, similarity_score, query_cost, cost_saved) "
			"VALUES (%s, %.6f::real, %.6f::numeric, %.6f::numeric)",
			cache_hit ? "'t'" : "'f'",
			similarity,
			query_cost,
			cost_saved);
	}

	SPI_connect();
	execute_sql(buf.data);

	/* Update total cost saved if it's a hit */
	if (cache_hit && cost_saved > 0)
	{
		StringInfoData update_buf;
		initStringInfo(&update_buf);
		appendStringInfo(&update_buf,
			"UPDATE semantic_cache.cache_metadata "
			"SET total_cost_saved = total_cost_saved + %.6f::numeric "
			"WHERE id = 1",
			cost_saved);
		execute_sql(update_buf.data);
		pfree(update_buf.data);
	}

	SPI_finish();
	pfree(buf.data);
	if (query_hash)
		pfree(query_hash);

	PG_RETURN_VOID();
}

/* Get cost savings report */
Datum
get_cost_savings(PG_FUNCTION_ARGS)
{
	int32 days = PG_ARGISNULL(0) ? 30 : PG_GETARG_INT32(0);
	TupleDesc tupdesc;
	Datum values[7];
	bool nulls[7] = {false};
	StringInfoData buf;

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in wrong context")));

	tupdesc = BlessTupleDesc(tupdesc);

	/* Initialize with zeros */
	values[0] = Int64GetDatum(0);  /* total_queries */
	values[1] = Int64GetDatum(0);  /* cache_hits */
	values[2] = Int64GetDatum(0);  /* cache_misses */
	values[3] = Float4GetDatum(0.0); /* hit_rate */
	values[4] = Float8GetDatum(0.0); /* total_cost_saved */
	values[5] = Float8GetDatum(0.0); /* avg_cost_per_hit */
	values[6] = Float8GetDatum(0.0); /* total_cost_if_no_cache */

	initStringInfo(&buf);
	appendStringInfo(&buf,
		"SELECT "
		"  COUNT(*) as total_queries, "
		"  SUM(CASE WHEN cache_hit THEN 1 ELSE 0 END) as cache_hits, "
		"  SUM(CASE WHEN NOT cache_hit THEN 1 ELSE 0 END) as cache_misses, "
		"  ROUND((SUM(CASE WHEN cache_hit THEN 1 ELSE 0 END)::NUMERIC / "
		"         NULLIF(COUNT(*), 0) * 100)::NUMERIC, 2) as hit_rate, "
		"  COALESCE(SUM(cost_saved), 0) as total_cost_saved, "
		"  COALESCE(AVG(CASE WHEN cache_hit THEN cost_saved END), 0) as avg_cost_per_hit, "
		"  COALESCE(SUM(query_cost), 0) as total_cost_if_no_cache "
		"FROM semantic_cache.cache_access_log "
		"WHERE access_time >= NOW() - interval '%d days'",
		days);

	SPI_connect();
	int ret = SPI_execute(buf.data, true, 0);

	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		bool isnull;
		values[0] = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
		if (isnull) values[0] = Int64GetDatum(0);

		values[1] = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &isnull);
		if (isnull) values[1] = Int64GetDatum(0);

		values[2] = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 3, &isnull);
		if (isnull) values[2] = Int64GetDatum(0);

		/* Convert hit_rate from numeric to float4 */
		Datum hit_rate_datum = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 4, &isnull);
		if (!isnull)
		{
			Numeric num = DatumGetNumeric(hit_rate_datum);
			float8 hit_rate_f8 = DatumGetFloat8(DirectFunctionCall1(numeric_float8, NumericGetDatum(num)));
			values[3] = Float4GetDatum((float4)hit_rate_f8);
		}

		/* Convert total_cost_saved from numeric to float8 */
		Datum cost_saved_datum = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 5, &isnull);
		if (!isnull)
		{
			Numeric num = DatumGetNumeric(cost_saved_datum);
			values[4] = DirectFunctionCall1(numeric_float8, NumericGetDatum(num));
		}
		else
			values[4] = Float8GetDatum(0.0);

		/* Convert avg_cost_per_hit from numeric to float8 */
		Datum avg_cost_datum = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 6, &isnull);
		if (!isnull)
		{
			Numeric num = DatumGetNumeric(avg_cost_datum);
			values[5] = DirectFunctionCall1(numeric_float8, NumericGetDatum(num));
		}
		else
			values[5] = Float8GetDatum(0.0);

		/* Convert total_cost_if_no_cache from numeric to float8 */
		Datum total_cost_datum = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 7, &isnull);
		if (!isnull)
		{
			Numeric num = DatumGetNumeric(total_cost_datum);
			values[6] = DirectFunctionCall1(numeric_float8, NumericGetDatum(num));
		}
		else
			values[6] = Float8GetDatum(0.0);
	}

	SPI_finish();
	pfree(buf.data);

	HeapTuple tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}
