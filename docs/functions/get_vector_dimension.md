# get_vector_dimension

Get configured vector embedding dimension.

## Signature

```sql
semantic_cache.get_vector_dimension() RETURNS integer
```

## Returns

- **integer**: Current vector dimension

## Example

```sql
SELECT semantic_cache.get_vector_dimension();
-- Returns: 1536
```
