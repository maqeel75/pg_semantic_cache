# get_index_type

Get configured vector index type.

## Signature

```sql
semantic_cache.get_index_type() RETURNS text
```

## Returns

- **text**: Current index type ('ivfflat' or 'hnsw')

## Example

```sql
SELECT semantic_cache.get_index_type();
-- Returns: 'ivfflat'
```
