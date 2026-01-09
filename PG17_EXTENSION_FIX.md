# PostgreSQL 17 Compatibility Fix - Extension

## Issue Summary

**Problem:** The extension crashed with PostgreSQL 17 when caching data containing quotes:

```
ERROR:  invalid input syntax for type json
DETAIL:  Token "self" is invalid.
CONTEXT:  JSON data, line 1: {"answer": "PostgreSQL provides a \\"self...
```

**Affected:** PostgreSQL 17 (PG 16 was more lenient and didn't catch this bug)

**Root Cause:** Double JSON encoding in the `cache_query()` C function

## Technical Details

### The Bug

In `pg_semantic_cache.c`, the `cache_query()` function was:

1. Converting JSONB to JSON string: `JsonbToCString()`
2. Escaping that JSON string: `pg_escape_string()`
3. Trying to cast the escaped string back to JSONB: `'...'::jsonb`

This created invalid JSON with double-escaped quotes:
- Original: `"text with \"quotes\""`
- After escape: `"text with \\\"quotes\\\""`
- PostgreSQL 17 rejects this as invalid JSON

### The Fix

**Changed:** Use parameterized queries with proper JSONB handling

**Before (Broken):**
```c
rstr = JsonbToCString(NULL, &result->root, VARSIZE(result));
resc = pg_escape_string(rstr);

appendStringInfo(&buf, "... VALUES (..., %s::jsonb, ...", resc);

// Then execute with SPI_execute()
```

**After (Fixed):**
```c
// Don't escape JSONB - pass it directly as a parameter
appendStringInfo(&buf, "... VALUES (..., $1, ...");

// Use parameterized query
argtypes[0] = JSONBOID;
values[0] = PointerGetDatum(result);

SPI_execute_with_args(buf.data, nargs, argtypes, values, nulls, false, 0);
```

### Files Modified

- `pg_semantic_cache.c` - Lines 249-296
  - Removed JSONB string escaping
  - Changed to use `$1` parameter for JSONB data
  - Updated both `has_tags` and `no_tags` code paths
  - Now uses `SPI_execute_with_args()` for all cases

### Demo Files Also Fixed

The Python demo scripts also had the same issue:

- `simple_demo.py` - Changed from `json.dumps()` + `::jsonb` to `Json()` adapter
- `simple_demo_openai.py` - Same fix

## Benefits

✅ **Correct JSONB handling** - No double encoding
✅ **PostgreSQL 17 compatible** - Passes strict JSON validation
✅ **Backward compatible** - Works with PG 14, 15, 16, 17+
✅ **Safer** - Parameterized queries prevent injection issues
✅ **Cleaner code** - Less escaping logic

## Testing

The fix allows caching data with special characters:

```sql
-- These now work correctly:
SELECT semantic_cache.cache_query(
    'Question',
    '[...]'::text,
    jsonb_build_object(
        'answer', 'Text with "quotes" and ''apostrophes''',
        'nested', jsonb_build_object('key', 'value with "quotes"')
    ),
    3600,
    ARRAY['tag']::text[]
);
```

## Upgrading

If you have an existing installation, rebuild the extension:

```bash
cd pg_semantic_cache
git pull
make clean && make
sudo make install

# Then restart PostgreSQL or reload the extension
psql -U postgres -d your_db -c "DROP EXTENSION pg_semantic_cache CASCADE; CREATE EXTENSION pg_semantic_cache;"
```

## Related

- **Demo Fix:** Both demo scripts also needed the same fix (using `Json()` adapter)
- **Documentation:** See `PG17_FIX.md` in the demo directory for details

## Status

🟢 **READY FOR PRODUCTION** - Fix tested and confirmed working with PG 17
