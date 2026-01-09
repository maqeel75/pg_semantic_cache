# set_vector_dimension

Configure vector embedding dimension.

## Signature

```sql
semantic_cache.set_vector_dimension(dimension integer) RETURNS void
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `dimension` | integer | Vector dimension (e.g., 768, 1536, 3072) |

## Description

Sets the vector dimension. Requires `rebuild_index()` to apply changes.

## Example

```sql
-- Change to 768 dimensions
SELECT semantic_cache.set_vector_dimension(768);
SELECT semantic_cache.rebuild_index();  -- Apply changes
```
