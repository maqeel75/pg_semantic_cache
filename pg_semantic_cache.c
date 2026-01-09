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
PG_FUNCTION_INFO_V1(evict_lfu);
PG_FUNCTION_INFO_V1(clear_cache);
PG_FUNCTION_INFO_V1(auto_evict);
PG_FUNCTION_INFO_V1(log_cache_access);
PG_FUNCTION_INFO_V1(get_cost_savings);
PG_FUNCTION_INFO_V1(set_vector_dimension);
PG_FUNCTION_INFO_V1(get_vector_dimension);
PG_FUNCTION_INFO_V1(set_index_type);
PG_FUNCTION_INFO_V1(get_index_type);
PG_FUNCTION_INFO_V1(rebuild_index);

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
	int32 dimension = 1536;  /* Default: OpenAI ada-002 */
	char *index_type = "ivfflat";  /* Default: ivfflat */
	int ret;
	bool isnull;
	StringInfoData buf;

	/* First create config table and metadata tables */
	const char *base_sql =
		"CREATE TABLE IF NOT EXISTS semantic_cache.cache_config ("
		"  key TEXT PRIMARY KEY, value TEXT"
		");"
		"CREATE TABLE IF NOT EXISTS semantic_cache.cache_metadata ("
		"  id SERIAL PRIMARY KEY,"
		"  total_hits BIGINT DEFAULT 0,"
		"  total_misses BIGINT DEFAULT 0,"
		"  total_cost_saved NUMERIC(12,6) DEFAULT 0.0"
		");"
		"INSERT INTO semantic_cache.cache_metadata (id) VALUES (1) ON CONFLICT (id) DO NOTHING;"
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
		"  ON semantic_cache.cache_access_log(query_hash);"
		"INSERT INTO semantic_cache.cache_config (key, value) "
		"  VALUES ('vector_dimension', '1536') ON CONFLICT (key) DO NOTHING;"
		"INSERT INTO semantic_cache.cache_config (key, value) "
		"  VALUES ('index_type', 'ivfflat') ON CONFLICT (key) DO NOTHING;";

	SPI_connect();
	execute_sql(base_sql);

	/* Get configured dimension */
	ret = SPI_execute(
		"SELECT value FROM semantic_cache.cache_config WHERE key = 'vector_dimension'",
		true, 0);
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		Datum val = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
		{
			char *dim_str = TextDatumGetCString(val);
			dimension = atoi(dim_str);
			pfree(dim_str);
		}
	}

	/* Get configured index type */
	ret = SPI_execute(
		"SELECT value FROM semantic_cache.cache_config WHERE key = 'index_type'",
		true, 0);
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		Datum val = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
		{
			index_type = TextDatumGetCString(val);
		}
	}

	/* Create cache_entries table with configured dimension */
	initStringInfo(&buf);
	appendStringInfo(&buf,
		"CREATE TABLE IF NOT EXISTS semantic_cache.cache_entries ("
		"  id BIGSERIAL PRIMARY KEY,"
		"  query_hash TEXT NOT NULL UNIQUE,"
		"  query_text TEXT NOT NULL,"
		"  query_embedding vector(%d),"
		"  result_data JSONB NOT NULL,"
		"  result_size_bytes INTEGER,"
		"  created_at TIMESTAMPTZ DEFAULT NOW(),"
		"  last_accessed_at TIMESTAMPTZ DEFAULT NOW(),"
		"  access_count INTEGER DEFAULT 0,"
		"  ttl_seconds INTEGER,"
		"  expires_at TIMESTAMPTZ,"
		"  tags TEXT[]"
		");",
		dimension);

	execute_sql(buf.data);
	pfree(buf.data);

	/* Create index with configured type */
	initStringInfo(&buf);

	if (strcmp(index_type, "hnsw") == 0)
	{
		/* HNSW index - more accurate, requires pgvector 0.5.0+ */
		appendStringInfo(&buf,
			"CREATE INDEX IF NOT EXISTS idx_cache_embedding "
			"  ON semantic_cache.cache_entries "
			"  USING hnsw (query_embedding vector_cosine_ops);");
	}
	else
	{
		/* IVFFlat index - default, widely supported */
		appendStringInfo(&buf,
			"CREATE INDEX IF NOT EXISTS idx_cache_embedding "
			"  ON semantic_cache.cache_entries "
			"  USING ivfflat (query_embedding vector_cosine_ops) WITH (lists = 100);");
	}

	execute_sql(buf.data);
	pfree(buf.data);

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
	size_t result_len;

	query_text = PG_GETARG_TEXT_PP(0);
	emb_text = PG_GETARG_TEXT_PP(1);
	result = PG_GETARG_JSONB_P(2);
	ttl = PG_ARGISNULL(3) ? 3600 : PG_GETARG_INT32(3);
	has_tags = !PG_ARGISNULL(4);

	/* Validate TTL */
	if (ttl < 0)
		elog(ERROR, "cache_query: ttl_seconds must be non-negative");
	if (ttl > 31536000)  /* 1 year max */
		elog(ERROR, "cache_query: ttl_seconds exceeds maximum (1 year)");
	
	qstr = text_to_cstring(query_text);
	estr = text_to_cstring(emb_text);
	rstr = JsonbToCString(NULL, &result->root, VARSIZE(result));

	/* Validate result size */
	result_len = strlen(rstr);
	if (result_len > 10485760)  /* 10MB max */
		elog(ERROR, "cache_query: result_data exceeds maximum size (10MB)");

	qesc = pg_escape_string(qstr);
	eesc = pg_escape_string(estr);
	/* For JSONB, use dollar quoting to avoid escaping issues */

	initStringInfo(&buf);

	/* Use dollar-quoted strings for JSONB to avoid escaping issues */
	if (has_tags)
	{
		appendStringInfo(&buf,
			"INSERT INTO semantic_cache.cache_entries "
			"(query_hash, query_text, query_embedding, result_data, "
			" result_size_bytes, ttl_seconds, expires_at, tags) "
			"VALUES (md5(%s), %s, %s::vector, $$%s$$::jsonb, %d, %d, "
			"NOW() + interval '%d seconds', $1) "
			"ON CONFLICT (query_hash) DO UPDATE SET "
			"  last_accessed_at = NOW(), "
			"  access_count = semantic_cache.cache_entries.access_count + 1 "
			"RETURNING id",
			qesc, qesc, eesc, rstr, (int)strlen(rstr), ttl, ttl);

		/* Only tags parameter needed */
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
			"VALUES (md5(%s), %s, %s::vector, $$%s$$::jsonb, %d, %d, "
			"NOW() + interval '%d seconds') "
			"ON CONFLICT (query_hash) DO UPDATE SET "
			"  last_accessed_at = NOW(), "
			"  access_count = semantic_cache.cache_entries.access_count + 1 "
			"RETURNING id",
			qesc, qesc, eesc, rstr, (int)strlen(rstr), ttl, ttl);

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

/*
 * get_cached_result - REPLACED WITH SQL IMPLEMENTATION
 *
 * This function is now implemented in SQL (see sql/pg_semantic_cache--0.3.0.sql)
 * for better memory management and simpler maintenance.
 *
 * Benefits of SQL implementation:
 * - Avoids complex SPI memory context issues with pass-by-reference types (JSONB)
 * - Provides identical functionality
 * - Better performance (no C/SQL boundary overhead)
 * - Easier to maintain and debug
 * - No memory corruption issues
 *
 * This stub is kept only for the PG_FUNCTION_INFO_V1 declaration but is never called.
 */
Datum
get_cached_result(PG_FUNCTION_ARGS)
{
	elog(ERROR, "get_cached_result C stub should not be called - using SQL implementation");
	PG_RETURN_NULL();
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

/* Evict expired entries */
Datum
evict_expired(PG_FUNCTION_ARGS)
{
	SPI_connect();
	execute_sql("DELETE FROM semantic_cache.cache_entries WHERE expires_at <= NOW()");
	int64 d = SPI_processed;
	SPI_finish();
	PG_RETURN_INT64(d);
}

/* Evict Least Recently Used entries */
Datum
evict_lru(PG_FUNCTION_ARGS)
{
	int32 keep_count;
	StringInfoData buf;
	int64 deleted = 0;

	if (PG_ARGISNULL(0))
		elog(ERROR, "evict_lru: keep_count parameter is required");

	keep_count = PG_GETARG_INT32(0);

	if (keep_count < 0)
		elog(ERROR, "evict_lru: keep_count must be non-negative");

	if (keep_count > 10000000)  /* 10 million max for safety */
		elog(ERROR, "evict_lru: keep_count exceeds maximum (10,000,000)");

	initStringInfo(&buf);
	appendStringInfo(&buf,
		"DELETE FROM semantic_cache.cache_entries "
		"WHERE id NOT IN ("
		"  SELECT id FROM semantic_cache.cache_entries "
		"  ORDER BY last_accessed_at DESC "
		"  LIMIT %d"
		")",
		keep_count);

	SPI_connect();
	execute_sql(buf.data);
	deleted = SPI_processed;
	SPI_finish();

	pfree(buf.data);
	PG_RETURN_INT64(deleted);
}

/* Evict Least Frequently Used entries */
Datum
evict_lfu(PG_FUNCTION_ARGS)
{
	int32 keep_count;
	StringInfoData buf;
	int64 deleted = 0;

	if (PG_ARGISNULL(0))
		elog(ERROR, "evict_lfu: keep_count parameter is required");

	keep_count = PG_GETARG_INT32(0);

	if (keep_count < 0)
		elog(ERROR, "evict_lfu: keep_count must be non-negative");

	if (keep_count > 10000000)  /* 10 million max for safety */
		elog(ERROR, "evict_lfu: keep_count exceeds maximum (10,000,000)");

	initStringInfo(&buf);
	appendStringInfo(&buf,
		"DELETE FROM semantic_cache.cache_entries "
		"WHERE id NOT IN ("
		"  SELECT id FROM semantic_cache.cache_entries "
		"  ORDER BY access_count DESC, last_accessed_at DESC "
		"  LIMIT %d"
		")",
		keep_count);

	SPI_connect();
	execute_sql(buf.data);
	deleted = SPI_processed;
	SPI_finish();

	pfree(buf.data);
	PG_RETURN_INT64(deleted);
}

/* Clear all cache entries */
Datum
clear_cache(PG_FUNCTION_ARGS)
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

/* Configure vector dimension (must be called before init_schema or after clearing cache) */
Datum
set_vector_dimension(PG_FUNCTION_ARGS)
{
	int32 dimension = PG_GETARG_INT32(0);
	StringInfoData buf;

	/* Validate dimension */
	if (dimension < 1 || dimension > 16000)
		elog(ERROR, "set_vector_dimension: dimension must be between 1 and 16000");

	SPI_connect();

	/* Update or insert config */
	initStringInfo(&buf);
	appendStringInfo(&buf,
		"INSERT INTO semantic_cache.cache_config (key, value) "
		"VALUES ('vector_dimension', '%d') "
		"ON CONFLICT (key) DO UPDATE SET value = '%d'",
		dimension, dimension);

	execute_sql(buf.data);
	pfree(buf.data);

	SPI_finish();

	elog(NOTICE, "Vector dimension set to %d. Call rebuild_index() to apply changes.", dimension);
	PG_RETURN_VOID();
}

/* Get configured vector dimension */
Datum
get_vector_dimension(PG_FUNCTION_ARGS)
{
	int32 dimension = 1536;  /* Default: OpenAI ada-002 */
	int ret;
	bool isnull;

	SPI_connect();
	ret = SPI_execute(
		"SELECT value FROM semantic_cache.cache_config WHERE key = 'vector_dimension'",
		true, 0);

	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		Datum val = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
		{
			char *dim_str = TextDatumGetCString(val);
			dimension = atoi(dim_str);
			pfree(dim_str);
		}
	}

	SPI_finish();
	PG_RETURN_INT32(dimension);
}

/* Set index type: 'ivfflat' or 'hnsw' */
Datum
set_index_type(PG_FUNCTION_ARGS)
{
	text *type_text = PG_GETARG_TEXT_PP(0);
	char *index_type = text_to_cstring(type_text);
	StringInfoData buf;

	/* Validate index type */
	if (strcmp(index_type, "ivfflat") != 0 && strcmp(index_type, "hnsw") != 0)
	{
		pfree(index_type);
		elog(ERROR, "set_index_type: index type must be 'ivfflat' or 'hnsw'");
	}

	SPI_connect();

	/* Update or insert config */
	initStringInfo(&buf);
	appendStringInfo(&buf,
		"INSERT INTO semantic_cache.cache_config (key, value) "
		"VALUES ('index_type', '%s') "
		"ON CONFLICT (key) DO UPDATE SET value = '%s'",
		index_type, index_type);

	execute_sql(buf.data);
	pfree(buf.data);

	SPI_finish();
	pfree(index_type);

	elog(NOTICE, "Index type set to %s. Call rebuild_index() to apply changes.", text_to_cstring(type_text));
	PG_RETURN_VOID();
}

/* Get configured index type */
Datum
get_index_type(PG_FUNCTION_ARGS)
{
	char *index_type = "ivfflat";  /* Default */
	int ret;
	bool isnull;

	SPI_connect();
	ret = SPI_execute(
		"SELECT value FROM semantic_cache.cache_config WHERE key = 'index_type'",
		true, 0);

	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		Datum val = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
		{
			index_type = TextDatumGetCString(val);
		}
	}

	SPI_finish();
	PG_RETURN_TEXT_P(cstring_to_text(index_type));
}

/* Rebuild index with current configuration */
Datum
rebuild_index(PG_FUNCTION_ARGS)
{
	int32 dimension = 1536;
	char *index_type = "ivfflat";
	int ret;
	bool isnull;
	int64 entry_count = 0;
	StringInfoData buf;

	SPI_connect();

	/* Get current entry count */
	ret = SPI_execute("SELECT COUNT(*) FROM semantic_cache.cache_entries", true, 0);
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		Datum count_datum = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
			entry_count = DatumGetInt64(count_datum);
	}

	/* Get configured dimension */
	ret = SPI_execute(
		"SELECT value FROM semantic_cache.cache_config WHERE key = 'vector_dimension'",
		true, 0);
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		Datum val = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
		{
			char *dim_str = TextDatumGetCString(val);
			dimension = atoi(dim_str);
			pfree(dim_str);
		}
	}

	/* Get configured index type */
	ret = SPI_execute(
		"SELECT value FROM semantic_cache.cache_config WHERE key = 'index_type'",
		true, 0);
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		Datum val = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
		{
			index_type = TextDatumGetCString(val);
		}
	}

	/* Drop existing index */
	execute_sql("DROP INDEX IF EXISTS semantic_cache.idx_cache_embedding");

	/* Recreate table with new dimension */
	execute_sql("DROP TABLE IF EXISTS semantic_cache.cache_entries CASCADE");

	initStringInfo(&buf);
	appendStringInfo(&buf,
		"CREATE TABLE semantic_cache.cache_entries ("
		"  id BIGSERIAL PRIMARY KEY,"
		"  query_hash TEXT NOT NULL UNIQUE,"
		"  query_text TEXT NOT NULL,"
		"  query_embedding vector(%d),"
		"  result_data JSONB NOT NULL,"
		"  result_size_bytes INTEGER,"
		"  created_at TIMESTAMPTZ DEFAULT NOW(),"
		"  last_accessed_at TIMESTAMPTZ DEFAULT NOW(),"
		"  access_count INTEGER DEFAULT 0,"
		"  ttl_seconds INTEGER,"
		"  expires_at TIMESTAMPTZ,"
		"  tags TEXT[]"
		")",
		dimension);

	execute_sql(buf.data);
	pfree(buf.data);

	/* Create index with configured type */
	initStringInfo(&buf);

	if (strcmp(index_type, "hnsw") == 0)
	{
		appendStringInfo(&buf,
			"CREATE INDEX idx_cache_embedding "
			"  ON semantic_cache.cache_entries "
			"  USING hnsw (query_embedding vector_cosine_ops)");
	}
	else
	{
		/* Calculate optimal lists based on expected cache size */
		int lists = 100;
		if (entry_count > 100000)
			lists = 1000;
		else if (entry_count > 10000)
			lists = 200;
		else if (entry_count < 1000)
			lists = 10;

		appendStringInfo(&buf,
			"CREATE INDEX idx_cache_embedding "
			"  ON semantic_cache.cache_entries "
			"  USING ivfflat (query_embedding vector_cosine_ops) WITH (lists = %d)",
			lists);
	}

	execute_sql(buf.data);
	pfree(buf.data);

	SPI_finish();

	elog(NOTICE, "Index rebuilt successfully with dimension=%d, type=%s", dimension, index_type);
	PG_RETURN_VOID();
}
