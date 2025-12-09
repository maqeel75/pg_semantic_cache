# Logging & Cost Tracking - Complete Guide

This document consolidates all information about the logging and cost tracking feature.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Running the Demo](#running-the-demo)
3. [Understanding Costs](#understanding-costs)
4. [Integration Guide](#integration-guide)
5. [API Reference](#api-reference)
6. [Troubleshooting](#troubleshooting)
7. [Examples](#examples)

---

## Quick Start

### What This Feature Does

Track cache hits/misses and calculate cost savings from avoiding LLM API calls.

**Key Benefits**:
- 📊 Track every cache hit and miss
- 💰 Calculate actual cost savings
- 📈 Generate ROI reports
- 🎯 Identify top cost-saving queries
- 📅 Analyze trends over time

### Quick Demo

```bash
# Run the interactive demo
psql -U postgres -f test_logging_demo.sql
```

**What you'll see**:
- 6 queries about "Capital of France" in different wordings
- 1 cache MISS (first query costs $0.006)
- 5 cache HITS (each saves $0.006)
- **83.3% cost reduction** ($0.030 saved out of $0.036 total)
- Monthly projections showing $1,500-$15,000 savings at scale

---

## Running the Demo

### Option 1: SQL Script (Recommended)

```bash
# Run directly
psql -U postgres -f test_logging_demo.sql

# Save output to file
psql -U postgres -f test_logging_demo.sql > demo_results.log 2>&1
```

### Option 2: Shell Script (With Colors)

```bash
# Make executable (first time only)
chmod +x test_logging_demo.sh

# Run
./test_logging_demo.sh

# Output saved to: semantic_cache_demo_results.log
```

### What the Demo Shows

**Step 1**: Cleanup previous test data
**Step 2**: First query - CACHE MISS ($0.006 cost)
**Step 3**: 5 similar queries - CACHE HITS (each saves $0.006)
**Step 4**: Access log with individual query details
**Step 5**: Cost savings summary
**Step 6**: Hit/Miss breakdown
**Step 7**: Monthly cost projections at scale

### Expected Results

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 5: Cost Savings Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Total Queries: 6
Cache Hits: 5
Cache Misses: 1
Hit Rate: 83.3%
Money Saved: $0.0300
Avg Saved/Hit: $0.0060
Cost w/o Cache: $0.0360

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 7: Monthly Projections
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Scale                | Monthly Savings | Cost w/o Cache | Cost Reduction
---------------------+-----------------+----------------+----------------
1,000 queries/day   | $150.00         | $180.00        | 83.3% reduction
10,000 queries/day  | $1,500.00       | $1,800.00      | 83.3% reduction
100,000 queries/day | $15,000.00      | $18,000.00     | 83.3% reduction
```

---

## Understanding Costs

### Where Do Costs Come From?

**In the Demo**: Hardcoded mock values (`$0.006` per query)
**In Production**: Real costs from your LLM API responses

### The Flow

```
┌─────────────────────────────────────────┐
│ 1. Your Application                     │
│    - Calls LLM API (OpenAI, Anthropic)  │
│    - Gets token usage from response     │
│    - Calculates actual cost             │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│ 2. Log to PostgreSQL                    │
│    log_cache_access(                    │
│        query_hash,                      │
│        cache_hit,                       │
│        similarity,                      │
│        actual_cost ← YOU provide this   │
│    )                                    │
└─────────────────────────────────────────┘
                  ↓
┌─────────────────────────────────────────┐
│ 3. Extension Calculates                 │
│    - cost_saved (if hit)                │
│    - Accumulates total_cost_saved       │
│    - Provides analytics                 │
└─────────────────────────────────────────┘
```

### Cost Calculation Methods

#### Method 1: From API Response (Most Accurate)

```python
# OpenAI GPT-4 example
response = openai.ChatCompletion.create(...)
usage = response['usage']

input_cost = (usage['prompt_tokens'] / 1000) * 0.03      # $0.03/1K
output_cost = (usage['completion_tokens'] / 1000) * 0.06  # $0.06/1K
total_cost = input_cost + output_cost
```

#### Method 2: Estimate Based on Text Length

```python
# Rough estimate: 1 token ≈ 4 characters
estimated_tokens = len(query_text) / 4
cost = (estimated_tokens / 1000) * 0.03  # Input cost
```

#### Method 3: Fixed Average (Simplest)

```python
AVERAGE_QUERY_COST = 0.006  # Based on your typical usage
```

### Current Pricing (Dec 2024)

| Model | Input (per 1M tokens) | Output (per 1M tokens) |
|-------|----------------------|------------------------|
| GPT-4 Turbo | $10.00 | $30.00 |
| GPT-3.5 Turbo | $0.50 | $1.50 |
| Claude 3.5 Sonnet | $3.00 | $15.00 |
| Claude 3 Haiku | $0.25 | $1.25 |

---

## Integration Guide

### Python with OpenAI

```python
import psycopg2
import openai

def query_with_cache(query_text, embedding):
    conn = psycopg2.connect("dbname=mydb")
    cur = conn.cursor()

    # Check cache first
    cur.execute("""
        SELECT * FROM semantic_cache.get_cached_result(%s, 0.95)
    """, (embedding,))

    result = cur.fetchone()

    if result and result[0]:  # Cache HIT
        # Log the hit with cost we SAVED
        cur.execute("""
            SELECT semantic_cache.log_cache_access(
                %s, true, %s, 0.006
            )
        """, (hash(query_text), result[2]))

        conn.commit()
        return result[1]  # Cached result

    # Cache MISS - call API
    response = openai.ChatCompletion.create(
        model="gpt-4",
        messages=[{"role": "user", "content": query_text}]
    )

    # Calculate ACTUAL cost
    usage = response['usage']
    cost = ((usage['prompt_tokens'] / 1000) * 0.03 +
            (usage['completion_tokens'] / 1000) * 0.06)

    # Cache the result
    result_json = json.dumps(response['choices'][0]['message'])
    cur.execute("""
        SELECT semantic_cache.cache_query(%s, %s, %s::jsonb, 3600)
    """, (query_text, embedding, result_json))

    # Log the miss with ACTUAL cost
    cur.execute("""
        SELECT semantic_cache.log_cache_access(
            %s, false, NULL, %s
        )
    """, (hash(query_text), cost))

    conn.commit()
    return result_json
```

### Node.js with Anthropic

```javascript
const { Pool } = require('pg');
const Anthropic = require('@anthropic-ai/sdk');

const pool = new Pool({ database: 'mydb' });
const anthropic = new Anthropic();

async function queryWithCache(queryText, embedding) {
    const client = await pool.connect();

    try {
        // Check cache
        const cache = await client.query(
            'SELECT * FROM semantic_cache.get_cached_result($1, 0.95)',
            [embedding]
        );

        if (cache.rows[0]?.found) {
            // Cache HIT
            await client.query(
                'SELECT semantic_cache.log_cache_access($1, $2, $3, $4)',
                [queryText, true, cache.rows[0].similarity_score, 0.008]
            );
            return cache.rows[0].result_data;
        }

        // Cache MISS - call API
        const message = await anthropic.messages.create({
            model: "claude-3-5-sonnet-20241022",
            max_tokens: 1024,
            messages: [{ role: "user", content: queryText }]
        });

        // Calculate cost
        const cost =
            (message.usage.input_tokens / 1_000_000) * 3.00 +
            (message.usage.output_tokens / 1_000_000) * 15.00;

        // Cache result
        await client.query(
            'SELECT semantic_cache.cache_query($1, $2, $3, 3600)',
            [queryText, embedding, JSON.stringify(message.content)]
        );

        // Log miss
        await client.query(
            'SELECT semantic_cache.log_cache_access($1, $2, $3, $4)',
            [queryText, false, null, cost]
        );

        return message.content;
    } finally {
        client.release();
    }
}
```

---

## API Reference

### Functions

#### `log_cache_access()`

Record a cache access event with cost information.

```sql
SELECT semantic_cache.log_cache_access(
    query_hash text,              -- Unique identifier for the query
    cache_hit boolean,            -- true = hit, false = miss
    similarity_score float4,      -- Similarity score (0-1, NULL for misses)
    query_cost numeric            -- Cost of the query (dollars)
);
```

**Examples**:
```sql
-- Log a cache miss
SELECT semantic_cache.log_cache_access('query_123', false, NULL, 0.006);

-- Log a cache hit
SELECT semantic_cache.log_cache_access('query_456', true, 0.95, 0.006);
```

#### `get_cost_savings()`

Get cost savings report for a time period.

```sql
SELECT * FROM semantic_cache.get_cost_savings(
    days integer DEFAULT 30      -- Number of days to analyze
);
```

**Returns**:
| Column | Type | Description |
|--------|------|-------------|
| total_queries | bigint | Total number of queries |
| cache_hits | bigint | Number of cache hits |
| cache_misses | bigint | Number of cache misses |
| hit_rate | float4 | Hit rate percentage (0-100) |
| total_cost_saved | float8 | Total money saved |
| avg_cost_per_hit | float8 | Average savings per hit |
| total_cost_if_no_cache | float8 | What it would have cost without cache |

**Examples**:
```sql
-- Last 30 days (default)
SELECT * FROM semantic_cache.get_cost_savings();

-- Last 7 days
SELECT * FROM semantic_cache.get_cost_savings(7);

-- Pretty format
SELECT
    total_queries,
    cache_hits,
    ROUND(hit_rate, 1) || '%' as hit_rate,
    '$' || ROUND(total_cost_saved, 2) as saved,
    '$' || ROUND(total_cost_if_no_cache, 2) as would_have_cost
FROM semantic_cache.get_cost_savings(30);
```

### Views

#### `cache_access_summary`

Hourly access statistics with cost savings.

```sql
SELECT * FROM semantic_cache.cache_access_summary
ORDER BY hour DESC
LIMIT 24;
```

**Columns**: hour, total_accesses, hits, misses, hit_rate_pct, cost_saved

#### `cost_savings_daily`

Daily cost breakdown.

```sql
SELECT * FROM semantic_cache.cost_savings_daily
ORDER BY date DESC
LIMIT 7;
```

**Columns**: date, total_queries, cache_hits, cache_misses, hit_rate_pct, total_cost_saved, avg_cost_per_hit

#### `top_cached_queries`

Top 100 queries by cost savings.

```sql
SELECT * FROM semantic_cache.top_cached_queries
LIMIT 10;
```

**Columns**: query_hash, hit_count, avg_similarity, total_cost_saved, last_access

---

## Troubleshooting

### Issue: Costs showing as $0.000000

**Symptom**: All cost values display as zero in reports.

**Cause**: Extension wasn't rebuilt after applying numeric type fixes.

**Solution**:
```bash
cd /path/to/pg_semantic_cache
make clean && make && sudo make install

psql -U postgres << 'EOF'
DROP EXTENSION IF EXISTS pg_semantic_cache CASCADE;
CREATE EXTENSION pg_semantic_cache;
EOF
```

### Issue: Hit rate shows 0.0%

**Symptom**: get_cost_savings() shows 0% hit rate despite having hits.

**Cause**: Same as above - numeric type conversion issue.

**Solution**: Same rebuild process.

### Issue: No data in reports

**Symptom**: get_cost_savings() returns all zeros.

**Cause**: No log entries or time filter excludes all data.

**Solution**:
```sql
-- Check if there are any log entries
SELECT COUNT(*) FROM semantic_cache.cache_access_log;

-- Check date range
SELECT MIN(access_time), MAX(access_time)
FROM semantic_cache.cache_access_log;

-- Try with longer time period
SELECT * FROM semantic_cache.get_cost_savings(365);
```

---

## Examples

### Example 1: Basic Logging

```sql
-- Log a cache miss
SELECT semantic_cache.log_cache_access(
    'openai_gpt4_query_1',
    false,
    NULL,
    0.008
);

-- Log a cache hit
SELECT semantic_cache.log_cache_access(
    'openai_gpt4_query_2',
    true,
    0.97,
    0.008
);
```

### Example 2: Weekly Report

```sql
SELECT
    TO_CHAR(date, 'Day') as day_name,
    total_queries,
    cache_hits,
    hit_rate_pct || '%' as hit_rate,
    '$' || ROUND(total_cost_saved, 2) as saved
FROM semantic_cache.cost_savings_daily
WHERE date >= CURRENT_DATE - INTERVAL '7 days'
ORDER BY date;
```

### Example 3: ROI Analysis

```sql
WITH savings AS (
    SELECT
        total_cost_saved,
        total_cost_if_no_cache,
        hit_rate
    FROM semantic_cache.get_cost_savings(30)
)
SELECT
    '$' || ROUND(total_cost_saved, 2) as "30-Day Savings",
    '$' || ROUND(total_cost_if_no_cache, 2) as "Without Cache",
    ROUND(hit_rate, 1) || '%' as "Hit Rate",
    '$' || ROUND(total_cost_saved * 12, 2) as "Projected Annual"
FROM savings;
```

### Example 4: Top Queries

```sql
SELECT
    query_hash,
    hit_count as "Times Served",
    ROUND(avg_similarity::numeric, 2) as "Avg Match",
    '$' || ROUND(total_cost_saved, 4) as "Total Saved",
    AGE(NOW(), last_access) as "Last Used"
FROM semantic_cache.top_cached_queries
LIMIT 20;
```

### Example 5: Hourly Trend

```sql
SELECT
    TO_CHAR(hour, 'HH24:MI') as time,
    total_accesses as queries,
    hits,
    ROUND(hit_rate_pct, 1) || '%' as "hit %",
    '$' || ROUND(cost_saved, 4) as saved
FROM semantic_cache.cache_access_summary
WHERE hour >= NOW() - INTERVAL '24 hours'
ORDER BY hour DESC;
```

---

## Performance Considerations

- **Logging overhead**: ~1-2ms per cache access
- **Storage**: ~100 bytes per log entry
- **Indexes**: Automatically created on `access_time` and `query_hash`
- **Cleanup**: Consider archiving old logs after 90-365 days

### Archiving Old Logs

```sql
-- Archive logs older than 90 days
CREATE TABLE semantic_cache.cache_access_log_archive AS
SELECT * FROM semantic_cache.cache_access_log
WHERE access_time < NOW() - INTERVAL '90 days';

DELETE FROM semantic_cache.cache_access_log
WHERE access_time < NOW() - INTERVAL '90 days';

-- Vacuum to reclaim space
VACUUM semantic_cache.cache_access_log;
```

---

## Additional Resources

- **Full Examples**: See `examples/logging_examples.sql`
- **Test Suite**: See `test/test_logging.sql`
- **Quick Reference**: See `LOGGING_QUICK_REFERENCE.md`
- **Main README**: See `README.md`

---

**Questions?** Check the [GitHub Issues](https://github.com/anthropics/pg_semantic_cache/issues) or open a new issue.
