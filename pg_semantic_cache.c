/*-------------------------------------------------------------------------
 *
 * pg_semantic_cache.c
 *		PostgreSQL extension for semantic query result caching using vector embeddings
 *
 * Copyright (c) 2025, Aqeel
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "lib/stringinfo.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/jsonb.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"
#include "miscadmin.h"

#ifdef PG_MODULE_MAGIC
PG_MODULE_MAGIC;
#endif

/* Function declarations */
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
PG_FUNCTION_INFO_V1(get_config);
PG_FUNCTION_INFO_V1(set_config);
PG_FUNCTION_INFO_V1(init_schema);

/* Helper function to execute SQL and return result */
static int64
execute_insert_returning_int64(const char *query)
{
	int			ret;
	int64		result = 0;
	
	ret = SPI_execute(query, false, 0);
	
	if (ret != SPI_OK_INSERT_RETURNING && ret != SPI_OK_SELECT)
		elog(ERROR, "SPI_execute failed: error code %d", ret);
	
	if (SPI_processed > 0)
	{
		bool		isnull;
		Datum		value;
		
		value = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
			result = DatumGetInt64(value);
	}
	
	return result;
}

/* Helper to execute SQL without result */
static void
execute_sql(const char *query)
{
	int ret = SPI_execute(query, false, 0);
	if (ret < 0)
		elog(ERROR, "SPI_execute failed: error code %d", ret);
}

/* Helper to get string config value */
static char *
get_config_value(const char *key)
{
	StringInfoData query;
	int ret;
	char *result = NULL;
	
	SPI_connect();
	
	initStringInfo(&query);
	appendStringInfo(&query, 
		"SELECT value FROM semantic_cache.cache_config WHERE key = '%s'",
		key);
	
	ret = SPI_execute(query.data, true, 0);
	
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		bool isnull;
		Datum value = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
			result = pstrdup(TextDatumGetCString(value));
	}
	
	SPI_finish();
	pfree(query.data);
	
	return result;
}

/*
 * init_schema - Initialize extension schema and tables
 */
Datum
init_schema(PG_FUNCTION_ARGS)
{
	const char *sql = 
		"CREATE SCHEMA IF NOT EXISTS semantic_cache;"
		
		"CREATE TABLE IF NOT EXISTS semantic_cache.cache_entries ("
		"  id BIGSERIAL PRIMARY KEY,"
		"  query_hash TEXT NOT NULL,"
		"  query_text TEXT NOT NULL,"
		"  query_embedding vector(1536),"
		"  result_data JSONB NOT NULL,"
		"  result_size_bytes INTEGER,"
		"  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
		"  last_accessed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),"
		"  access_count INTEGER DEFAULT 0,"
		"  ttl_seconds INTEGER,"
		"  expires_at TIMESTAMPTZ,"
		"  tags TEXT[]"
		");"
		
		"CREATE INDEX IF NOT EXISTS idx_cache_query_hash "
		"  ON semantic_cache.cache_entries(query_hash);"
		
		"CREATE INDEX IF NOT EXISTS idx_cache_embedding "
		"  ON semantic_cache.cache_entries "
		"  USING ivfflat (query_embedding vector_cosine_ops) "
		"  WITH (lists = 100);"
		
		"CREATE INDEX IF NOT EXISTS idx_cache_expires_at "
		"  ON semantic_cache.cache_entries(expires_at) "
		"  WHERE expires_at IS NOT NULL;"
		
		"CREATE INDEX IF NOT EXISTS idx_cache_last_accessed "
		"  ON semantic_cache.cache_entries(last_accessed_at);"
		
		"CREATE TABLE IF NOT EXISTS semantic_cache.cache_metadata ("
		"  id SERIAL PRIMARY KEY,"
		"  total_hits BIGINT DEFAULT 0,"
		"  total_misses BIGINT DEFAULT 0,"
		"  total_evictions BIGINT DEFAULT 0,"
		"  total_entries INTEGER DEFAULT 0,"
		"  total_size_bytes BIGINT DEFAULT 0,"
		"  last_updated_at TIMESTAMPTZ DEFAULT NOW()"
		");"
		
		"INSERT INTO semantic_cache.cache_metadata (id) "
		"VALUES (1) ON CONFLICT (id) DO NOTHING;"
		
		"CREATE TABLE IF NOT EXISTS semantic_cache.cache_config ("
		"  key TEXT PRIMARY KEY,"
		"  value TEXT NOT NULL,"
		"  description TEXT,"
		"  updated_at TIMESTAMPTZ DEFAULT NOW()"
		");"
		
		"INSERT INTO semantic_cache.cache_config (key, value, description) VALUES "
		"  ('max_cache_size_mb', '1000', 'Maximum cache size in MB'),"
		"  ('default_ttl_seconds', '3600', 'Default TTL for cached entries'),"
		"  ('default_similarity_threshold', '0.95', 'Default similarity threshold'),"
		"  ('eviction_policy', 'lru', 'Eviction policy: lru, lfu, ttl'),"
		"  ('auto_eviction_enabled', 'true', 'Enable automatic eviction') "
		"ON CONFLICT (key) DO NOTHING;";
	
	SPI_connect();
	execute_sql(sql);
	SPI_finish();
	
	PG_RETURN_VOID();
}

/*
 * cache_query - Cache a query result with its embedding
 *
 * Arguments:
 *   query_text - The original query text
 *   query_embedding - Vector embedding (as text representation)
 *   result_data - The query result as JSONB
 *   ttl_seconds - Optional TTL in seconds
 *   tags - Optional tags array
 */
Datum
cache_query(PG_FUNCTION_ARGS)
{
	text	   *query_text = PG_GETARG_TEXT_PP(0);
	text	   *query_embedding_text = PG_GETARG_TEXT_PP(1);
	Jsonb	   *result_data = PG_GETARG_JSONB_P(2);
	int32		ttl_seconds;
	ArrayType  *tags_array = NULL;
	StringInfoData query;
	StringInfoData query_hash;
	char	   *query_str;
	char	   *embedding_str;
	char	   *result_str;
	char	   *tags_str = NULL;
	int64		cache_id;
	int32		result_size;
	
	/* Get arguments */
	query_str = text_to_cstring(query_text);
	embedding_str = text_to_cstring(query_embedding_text);
	result_str = JsonbToCString(NULL, &result_data->root, VARSIZE(result_data));
	result_size = strlen(result_str);
	
	/* Get TTL - use argument or default from config */
	if (PG_ARGISNULL(3))
	{
		char *default_ttl = get_config_value("default_ttl_seconds");
		ttl_seconds = default_ttl ? atoi(default_ttl) : 3600;
		if (default_ttl)
			pfree(default_ttl);
	}
	else
	{
		ttl_seconds = PG_GETARG_INT32(3);
	}
	
	/* Get tags if provided */
	if (!PG_ARGISNULL(4))
	{
		tags_array = PG_GETARG_ARRAYTYPE_P(4);
		/* Convert array to text representation */
		Datum tags_datum = PointerGetDatum(tags_array);
		tags_str = DatumGetCString(DirectFunctionCall1(array_out, tags_datum));
	}
	
	/* Calculate query hash using MD5 */
	initStringInfo(&query_hash);
	appendStringInfo(&query_hash, "md5_%s", query_str);
	
	/* Build INSERT query */
	initStringInfo(&query);
	appendStringInfo(&query,
		"INSERT INTO semantic_cache.cache_entries ("
		"  query_hash, query_text, query_embedding, result_data, "
		"  result_size_bytes, ttl_seconds, expires_at, tags"
		") VALUES ("
		"  md5('%s'), '%s', '%s'::vector, '%s'::jsonb, "
		"  %d, %d, NOW() + INTERVAL '%d seconds', ",
		query_str, query_str, embedding_str, result_str,
		result_size, ttl_seconds, ttl_seconds);
	
	if (tags_str)
		appendStringInfo(&query, "'%s'::text[]", tags_str);
	else
		appendStringInfo(&query, "NULL");
	
	appendStringInfo(&query,
		") ON CONFLICT (query_hash) DO UPDATE SET "
		"  query_embedding = EXCLUDED.query_embedding, "
		"  result_data = EXCLUDED.result_data, "
		"  result_size_bytes = EXCLUDED.result_size_bytes, "
		"  last_accessed_at = NOW(), "
		"  access_count = semantic_cache.cache_entries.access_count + 1, "
		"  ttl_seconds = EXCLUDED.ttl_seconds, "
		"  expires_at = NOW() + (EXCLUDED.ttl_seconds || ' seconds')::INTERVAL "
		"RETURNING id");
	
	SPI_connect();
	cache_id = execute_insert_returning_int64(query.data);
	
	/* Update metadata */
	execute_sql(
		"UPDATE semantic_cache.cache_metadata SET "
		"  total_entries = (SELECT COUNT(*) FROM semantic_cache.cache_entries), "
		"  total_size_bytes = (SELECT COALESCE(SUM(result_size_bytes), 0) FROM semantic_cache.cache_entries), "
		"  last_updated_at = NOW() "
		"WHERE id = 1");
	
	SPI_finish();
	
	/* Cleanup */
	pfree(query_str);
	pfree(embedding_str);
	pfree(result_str);
	pfree(query.data);
	pfree(query_hash.data);
	if (tags_str)
		pfree(tags_str);
	
	PG_RETURN_INT64(cache_id);
}

/*
 * get_cached_result - Retrieve cached result for a similar query
 */
Datum
get_cached_result(PG_FUNCTION_ARGS)
{
	text	   *query_embedding_text = PG_GETARG_TEXT_PP(0);
	float4		similarity_threshold;
	int32		max_age_seconds = -1;
	StringInfoData query;
	char	   *embedding_str;
	TupleDesc	tupdesc;
	Datum		values[4];
	bool		nulls[4];
	HeapTuple	tuple;
	int			ret;
	bool		cache_hit = false;
	
	/* Get similarity threshold - use argument or default */
	if (PG_ARGISNULL(1))
	{
		char *default_threshold = get_config_value("default_similarity_threshold");
		similarity_threshold = default_threshold ? atof(default_threshold) : 0.95;
		if (default_threshold)
			pfree(default_threshold);
	}
	else
	{
		similarity_threshold = PG_GETARG_FLOAT4(1);
	}
	
	/* Get max age if provided */
	if (!PG_ARGISNULL(2))
		max_age_seconds = PG_GETARG_INT32(2);
	
	embedding_str = text_to_cstring(query_embedding_text);
	
	/* Build search query */
	initStringInfo(&query);
	appendStringInfo(&query,
		"SELECT "
		"  result_data, "
		"  1 - (query_embedding <=> '%s'::vector) as similarity, "
		"  EXTRACT(EPOCH FROM (NOW() - created_at))::INTEGER as age_seconds, "
		"  id "
		"FROM semantic_cache.cache_entries "
		"WHERE (expires_at IS NULL OR expires_at > NOW()) ",
		embedding_str);
	
	if (max_age_seconds >= 0)
		appendStringInfo(&query, 
			"AND created_at > NOW() - INTERVAL '%d seconds' ", 
			max_age_seconds);
	
	appendStringInfo(&query,
		"ORDER BY query_embedding <=> '%s'::vector "
		"LIMIT 1",
		embedding_str);
	
	SPI_connect();
	ret = SPI_execute(query.data, true, 0);
	
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		bool		isnull;
		Datum		similarity_datum;
		float4		similarity;
		
		similarity_datum = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &isnull);
		similarity = DatumGetFloat4(similarity_datum);
		
		if (similarity >= similarity_threshold)
		{
			Datum		result_data_datum;
			Datum		age_datum;
			Datum		id_datum;
			int64		cache_entry_id;
			StringInfoData update_query;
			
			/* Get values */
			result_data_datum = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
			age_datum = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 3, &isnull);
			id_datum = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 4, &isnull);
			cache_entry_id = DatumGetInt64(id_datum);
			
			/* Update access statistics */
			initStringInfo(&update_query);
			appendStringInfo(&update_query,
				"UPDATE semantic_cache.cache_entries "
				"SET last_accessed_at = NOW(), access_count = access_count + 1 "
				"WHERE id = %ld",
				cache_entry_id);
			execute_sql(update_query.data);
			pfree(update_query.data);
			
			/* Update hit count */
			execute_sql(
				"UPDATE semantic_cache.cache_metadata "
				"SET total_hits = total_hits + 1, last_updated_at = NOW() "
				"WHERE id = 1");
			
			cache_hit = true;
			
			/* Prepare return tuple */
			if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("function returning record called in context that cannot accept type record")));
			
			tupdesc = BlessTupleDesc(tupdesc);
			
			values[0] = BoolGetDatum(true);					/* hit */
			values[1] = result_data_datum;					/* result_data */
			values[2] = Float4GetDatum(similarity);			/* similarity_score */
			values[3] = age_datum;							/* age_seconds */
			
			memset(nulls, 0, sizeof(nulls));
		}
	}
	
	if (!cache_hit)
	{
		/* Cache miss */
		execute_sql(
			"UPDATE semantic_cache.cache_metadata "
			"SET total_misses = total_misses + 1, last_updated_at = NOW() "
			"WHERE id = 1");
		
		/* Return NULL result */
		if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("function returning record called in context that cannot accept type record")));
		
		tupdesc = BlessTupleDesc(tupdesc);
		
		values[0] = BoolGetDatum(false);	/* hit */
		nulls[1] = true;					/* result_data - NULL */
		nulls[2] = true;					/* similarity_score - NULL */
		nulls[3] = true;					/* age_seconds - NULL */
	}
	
	SPI_finish();
	
	pfree(embedding_str);
	pfree(query.data);
	
	tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * invalidate_cache - Invalidate cache entries by pattern or tag
 */
Datum
invalidate_cache(PG_FUNCTION_ARGS)
{
	text	   *pattern = NULL;
	text	   *tag = NULL;
	StringInfoData query;
	int64		count;
	
	if (!PG_ARGISNULL(0))
		pattern = PG_GETARG_TEXT_PP(0);
	
	if (!PG_ARGISNULL(1))
		tag = PG_GETARG_TEXT_PP(1);
	
	if (pattern == NULL && tag == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("either pattern or tag must be provided")));
	
	initStringInfo(&query);
	appendStringInfo(&query,
		"WITH deleted AS ("
		"  DELETE FROM semantic_cache.cache_entries WHERE ");
	
	if (pattern)
		appendStringInfo(&query, "query_text ILIKE '%%%s%%'", text_to_cstring(pattern));
	else
		appendStringInfo(&query, "'%s' = ANY(tags)", text_to_cstring(tag));
	
	appendStringInfo(&query, " RETURNING *) SELECT COUNT(*) FROM deleted");
	
	SPI_connect();
	count = execute_insert_returning_int64(query.data);
	
	if (count > 0)
	{
		StringInfoData update_query;
		initStringInfo(&update_query);
		appendStringInfo(&update_query,
			"UPDATE semantic_cache.cache_metadata SET "
			"  total_entries = (SELECT COUNT(*) FROM semantic_cache.cache_entries), "
			"  total_size_bytes = (SELECT COALESCE(SUM(result_size_bytes), 0) FROM semantic_cache.cache_entries), "
			"  total_evictions = total_evictions + %ld, "
			"  last_updated_at = NOW() "
			"WHERE id = 1",
			count);
		execute_sql(update_query.data);
		pfree(update_query.data);
	}
	
	SPI_finish();
	pfree(query.data);
	
	PG_RETURN_INT64(count);
}

/*
 * evict_expired - Evict expired cache entries
 */
Datum
evict_expired(PG_FUNCTION_ARGS)
{
	int64 count;
	
	SPI_connect();
	
	count = execute_insert_returning_int64(
		"WITH deleted AS ("
		"  DELETE FROM semantic_cache.cache_entries "
		"  WHERE expires_at IS NOT NULL AND expires_at <= NOW() "
		"  RETURNING *"
		") SELECT COUNT(*) FROM deleted");
	
	if (count > 0)
	{
		StringInfoData query;
		initStringInfo(&query);
		appendStringInfo(&query,
			"UPDATE semantic_cache.cache_metadata SET "
			"  total_entries = (SELECT COUNT(*) FROM semantic_cache.cache_entries), "
			"  total_size_bytes = (SELECT COALESCE(SUM(result_size_bytes), 0) FROM semantic_cache.cache_entries), "
			"  total_evictions = total_evictions + %ld, "
			"  last_updated_at = NOW() "
			"WHERE id = 1",
			count);
		execute_sql(query.data);
		pfree(query.data);
	}
	
	SPI_finish();
	
	PG_RETURN_INT64(count);
}

/*
 * evict_lru - Evict least recently used entries when cache exceeds size limit
 */
Datum
evict_lru(PG_FUNCTION_ARGS)
{
	int32		limit_mb;
	int64		max_size_bytes;
	int64		current_size;
	int64		target_size;
	int64		bytes_to_evict;
	int64		count;
	StringInfoData query;
	int			ret;
	
	/* Get limit from argument or config */
	if (PG_ARGISNULL(0))
	{
		char *max_size_str = get_config_value("max_cache_size_mb");
		limit_mb = max_size_str ? atoi(max_size_str) : 1000;
		if (max_size_str)
			pfree(max_size_str);
	}
	else
	{
		limit_mb = PG_GETARG_INT32(0);
	}
	
	max_size_bytes = (int64)limit_mb * 1024 * 1024;
	
	SPI_connect();
	
	/* Get current cache size */
	ret = SPI_execute(
		"SELECT COALESCE(SUM(result_size_bytes), 0) FROM semantic_cache.cache_entries",
		true, 0);
	
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		bool isnull;
		current_size = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
	}
	else
	{
		current_size = 0;
	}
	
	if (current_size <= max_size_bytes)
	{
		SPI_finish();
		PG_RETURN_INT64(0);
	}
	
	/* Evict to 80% of max size */
	target_size = (int64)(max_size_bytes * 0.8);
	bytes_to_evict = current_size - target_size;
	
	/* Delete LRU entries */
	initStringInfo(&query);
	appendStringInfo(&query,
		"WITH to_delete AS ("
		"  SELECT id, result_size_bytes, "
		"    SUM(result_size_bytes) OVER (ORDER BY last_accessed_at ASC) as cumulative_size "
		"  FROM semantic_cache.cache_entries "
		"  ORDER BY last_accessed_at ASC"
		"), deleted AS ("
		"  DELETE FROM semantic_cache.cache_entries "
		"  WHERE id IN (SELECT id FROM to_delete WHERE cumulative_size <= %ld) "
		"  RETURNING *"
		") SELECT COUNT(*) FROM deleted",
		bytes_to_evict);
	
	count = execute_insert_returning_int64(query.data);
	
	if (count > 0)
	{
		StringInfoData update_query;
		initStringInfo(&update_query);
		appendStringInfo(&update_query,
			"UPDATE semantic_cache.cache_metadata SET "
			"  total_entries = (SELECT COUNT(*) FROM semantic_cache.cache_entries), "
			"  total_size_bytes = (SELECT COALESCE(SUM(result_size_bytes), 0) FROM semantic_cache.cache_entries), "
			"  total_evictions = total_evictions + %ld, "
			"  last_updated_at = NOW() "
			"WHERE id = 1",
			count);
		execute_sql(update_query.data);
		pfree(update_query.data);
	}
	
	SPI_finish();
	pfree(query.data);
	
	PG_RETURN_INT64(count);
}

/*
 * evict_lfu - Evict least frequently used entries
 */
Datum
evict_lfu(PG_FUNCTION_ARGS)
{
	int32		count_to_evict = PG_GETARG_INT32(0);
	int64		deleted_count;
	StringInfoData query;
	
	initStringInfo(&query);
	appendStringInfo(&query,
		"WITH deleted AS ("
		"  DELETE FROM semantic_cache.cache_entries "
		"  WHERE id IN ("
		"    SELECT id FROM semantic_cache.cache_entries "
		"    ORDER BY access_count ASC, last_accessed_at ASC "
		"    LIMIT %d"
		"  ) RETURNING *"
		") SELECT COUNT(*) FROM deleted",
		count_to_evict);
	
	SPI_connect();
	deleted_count = execute_insert_returning_int64(query.data);
	
	if (deleted_count > 0)
	{
		StringInfoData update_query;
		initStringInfo(&update_query);
		appendStringInfo(&update_query,
			"UPDATE semantic_cache.cache_metadata SET "
			"  total_entries = (SELECT COUNT(*) FROM semantic_cache.cache_entries), "
			"  total_size_bytes = (SELECT COALESCE(SUM(result_size_bytes), 0) FROM semantic_cache.cache_entries), "
			"  total_evictions = total_evictions + %ld, "
			"  last_updated_at = NOW() "
			"WHERE id = 1",
			deleted_count);
		execute_sql(update_query.data);
		pfree(update_query.data);
	}
	
	SPI_finish();
	pfree(query.data);
	
	PG_RETURN_INT64(deleted_count);
}

/*
 * clear_cache - Clear entire cache
 */
Datum
clear_cache(PG_FUNCTION_ARGS)
{
	int64 count;
	
	SPI_connect();
	
	count = execute_insert_returning_int64(
		"WITH deleted AS ("
		"  DELETE FROM semantic_cache.cache_entries RETURNING *"
		") SELECT COUNT(*) FROM deleted");
	
	execute_sql(
		"UPDATE semantic_cache.cache_metadata SET "
		"  total_entries = 0, "
		"  total_size_bytes = 0, "
		"  total_hits = 0, "
		"  total_misses = 0, "
		"  total_evictions = 0, "
		"  last_updated_at = NOW() "
		"WHERE id = 1");
	
	SPI_finish();
	
	PG_RETURN_INT64(count);
}

/*
 * auto_evict - Automatic eviction based on configured policy
 */
Datum
auto_evict(PG_FUNCTION_ARGS)
{
	char	   *enabled_str;
	char	   *policy_str;
	int64		expired_count = 0;
	int64		policy_count = 0;
	
	/* Check if auto-eviction is enabled */
	enabled_str = get_config_value("auto_eviction_enabled");
	if (enabled_str && strcmp(enabled_str, "true") != 0)
	{
		if (enabled_str)
			pfree(enabled_str);
		PG_RETURN_INT64(0);
	}
	if (enabled_str)
		pfree(enabled_str);
	
	SPI_connect();
	
	/* Always evict expired entries first */
	expired_count = DatumGetInt64(DirectFunctionCall1(evict_expired, 0));
	
	/* Apply configured eviction policy */
	policy_str = get_config_value("eviction_policy");
	if (policy_str)
	{
		if (strcmp(policy_str, "lru") == 0)
		{
			policy_count = DatumGetInt64(DirectFunctionCall1(evict_lru, 0));
		}
		else if (strcmp(policy_str, "lfu") == 0)
		{
			/* Evict bottom 10% by access count */
			int ret = SPI_execute(
				"SELECT COUNT(*) FROM semantic_cache.cache_entries",
				true, 0);
			
			if (ret == SPI_OK_SELECT && SPI_processed > 0)
			{
				bool isnull;
				int64 total = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
				int32 to_evict = (int32)(total * 0.1);
				if (to_evict > 0)
					policy_count = DatumGetInt64(DirectFunctionCall1(evict_lfu, Int32GetDatum(to_evict)));
			}
		}
		pfree(policy_str);
	}
	
	SPI_finish();
	
	PG_RETURN_INT64(expired_count + policy_count);
}

/*
 * cache_stats - Get comprehensive cache statistics
 */
Datum
cache_stats(PG_FUNCTION_ARGS)
{
	TupleDesc	tupdesc;
	Datum		values[8];
	bool		nulls[8];
	HeapTuple	tuple;
	int			ret;
	
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in context that cannot accept type record")));
	
	tupdesc = BlessTupleDesc(tupdesc);
	
	SPI_connect();
	
	ret = SPI_execute(
		"SELECT total_entries, total_hits, total_misses, total_evictions, total_size_bytes "
		"FROM semantic_cache.cache_metadata WHERE id = 1",
		true, 0);
	
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		bool		isnull;
		int32		entries;
		int64		hits;
		int64		misses;
		int64		evictions;
		int64		size_bytes;
		int64		total_requests;
		float4		hit_rate;
		float4		size_mb;
		float4		avg_size_kb;
		
		entries = DatumGetInt32(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
		hits = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &isnull));
		misses = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 3, &isnull));
		evictions = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 4, &isnull));
		size_bytes = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 5, &isnull));
		
		total_requests = hits + misses;
		hit_rate = total_requests > 0 ? ((float4)hits / (float4)total_requests * 100.0) : 0.0;
		size_mb = (float4)size_bytes / (1024.0 * 1024.0);
		avg_size_kb = entries > 0 ? ((float4)size_bytes / (float4)entries / 1024.0) : 0.0;
		
		values[0] = Int32GetDatum(entries);
		values[1] = Int64GetDatum(hits);
		values[2] = Int64GetDatum(misses);
		values[3] = Int64GetDatum(evictions);
		values[4] = Float4GetDatum(hit_rate);
		values[5] = Int64GetDatum(size_bytes);
		values[6] = Float4GetDatum(size_mb);
		values[7] = Float4GetDatum(avg_size_kb);
		
		memset(nulls, 0, sizeof(nulls));
	}
	else
	{
		memset(nulls, 1, sizeof(nulls));
	}
	
	SPI_finish();
	
	tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * cache_hit_rate - Get current hit rate percentage
 */
Datum
cache_hit_rate(PG_FUNCTION_ARGS)
{
	int		ret;
	float4	hit_rate = 0.0;
	
	SPI_connect();
	
	ret = SPI_execute(
		"SELECT total_hits, total_misses FROM semantic_cache.cache_metadata WHERE id = 1",
		true, 0);
	
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		bool	isnull;
		int64	hits = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
		int64	misses = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &isnull));
		int64	total = hits + misses;
		
		if (total > 0)
			hit_rate = ((float4)hits / (float4)total) * 100.0;
	}
	
	SPI_finish();
	
	PG_RETURN_FLOAT4(hit_rate);
}

/*
 * get_config - Get a configuration value
 */
Datum
get_config(PG_FUNCTION_ARGS)
{
	text	   *key = PG_GETARG_TEXT_PP(0);
	char	   *key_str = text_to_cstring(key);
	char	   *value = get_config_value(key_str);
	
	pfree(key_str);
	
	if (value)
	{
		text *result = cstring_to_text(value);
		pfree(value);
		PG_RETURN_TEXT_P(result);
	}
	
	PG_RETURN_NULL();
}

/*
 * set_config - Set a configuration value
 */
Datum
set_config(PG_FUNCTION_ARGS)
{
	text	   *key = PG_GETARG_TEXT_PP(0);
	text	   *value = PG_GETARG_TEXT_PP(1);
	char	   *key_str = text_to_cstring(key);
	char	   *value_str = text_to_cstring(value);
	StringInfoData query;
	
	initStringInfo(&query);
	appendStringInfo(&query,
		"INSERT INTO semantic_cache.cache_config (key, value, updated_at) "
		"VALUES ('%s', '%s', NOW()) "
		"ON CONFLICT (key) DO UPDATE "
		"SET value = EXCLUDED.value, updated_at = NOW()",
		key_str, value_str);
	
	SPI_connect();
	execute_sql(query.data);
	SPI_finish();
	
	pfree(key_str);
	pfree(value_str);
	pfree(query.data);
	
	PG_RETURN_VOID();
}
