# set_index_type

Set vector index type (ivfflat or hnsw).

## Signature

```sql
semantic_cache.set_index_type(index_type text) RETURNS void
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `index_type` | text | 'ivfflat' or 'hnsw' |

## Description

Sets the index type. Requires `rebuild_index()` to apply.

## Example

```sql
-- Switch to HNSW index
SELECT semantic_cache.set_index_type('hnsw');
SELECT semantic_cache.rebuild_index();
```
