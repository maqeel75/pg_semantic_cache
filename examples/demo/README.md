# pg_semantic_cache Demo Applications

Interactive demonstrations showing how to use pg_semantic_cache with real embedding models and LLMs.

## Available Demos

### 1. Ollama Demo (Local, Free)
**File:** `simple_demo.py`

Uses local Ollama models - no API keys needed!
- Embedding: `mxbai-embed-large` (1024 dimensions)
- LLM: `llama3.2:1b`

### 2. OpenAI Demo (Cloud, API Key Required)
**File:** `simple_demo_openai.py`

Uses OpenAI models for production-quality results.
- Embedding: `text-embedding-3-small` (1536 dimensions)
- LLM: `gpt-4`

## Quick Start

### Option 1: Docker Compose (Recommended)

#### For Ollama Demo:
```bash
# From examples/demo/ directory
docker-compose up --build

# In another terminal, run the demo
docker-compose exec app python simple_demo.py
```

#### For OpenAI Demo:
```bash
# Create .env file (see setup below)
cp .env.example .env
# Edit .env and add your OpenAI API key

docker-compose -f docker-compose.openai.yml up --build

# In another terminal
docker-compose -f docker-compose.openai.yml exec app python simple_demo_openai.py
```

### Option 2: Manual Setup

#### Prerequisites
- PostgreSQL 14+ with pgvector installed
- pg_semantic_cache extension installed
- Python 3.8+
- Ollama (for local demo) OR OpenAI API key (for cloud demo)

#### Setup Steps

1. **Create .env file:**
```bash
cp .env.example .env
```

2. **Edit .env and add credentials (if using OpenAI):**
```bash
# For OpenAI demo only
OPENAI_API_KEY=sk-your-actual-key-here

# For GitHub access (if needed to clone private repos)
GIT_USERNAME=your-github-username
GIT_TOKEN=ghp_your-github-token
```

3. **Install Python dependencies:**
```bash
pip install -r requirements.txt
```

4. **Set up database:**
```bash
# For Ollama demo
psql -U postgres -f setup.sql

# For OpenAI demo
psql -U postgres -f setup_openai.sql
```

5. **Run the demo:**
```bash
# Ollama demo
python simple_demo.py

# OpenAI demo
python simple_demo_openai.py
```

## What the Demos Show

Both demos demonstrate:
- ✅ Generating embeddings for user queries
- ✅ Checking semantic cache for similar queries
- ✅ Cache MISS: Calling LLM API when no match found
- ✅ Cache HIT: Returning cached results for similar queries
- ✅ Real-time similarity scores and performance metrics
- ✅ Cost savings tracking

### Example Session:

```
❓ Your question> What is PostgreSQL?
⏳ Generating embedding... (0.12s)
⏳ Checking semantic cache... ✗ Cache miss (0.002s)
   ⏳ Generating answer with llama3.2:1b... (4.32s)

💡 Answer (generated):
PostgreSQL is an open-source relational database management system...

⏳ Caching answer... ✓

─────────────────────────────────────────────────────

❓ Your question> Tell me about PostgreSQL
⏳ Generating embedding... (0.11s)
⏳ Checking semantic cache... ✓ Cache hit! (0.003s)
   Similarity score: 0.98

💡 Answer (from cache):
PostgreSQL is an open-source relational database management system...

💰 Saved API call! (4.3s faster)
```

## Test Files

### `test_probes.sql`
Tests IVFFlat probe settings and cache performance.

### `test_jsonb_fix.sql`
Validates JSONB handling with special characters.

### `test_pg_versions.sh`
Tests compatibility across PostgreSQL 14-18.

## Environment Variables

Create a `.env` file based on `.env.example`:

```bash
# Required for OpenAI demo
OPENAI_API_KEY=sk-your-key-here

# Optional: For cloning private repos
GIT_USERNAME=your-username
GIT_TOKEN=ghp-your-token
```

**IMPORTANT:**
- Never commit your `.env` file to git
- The `.env.example` file shows the format but contains no real credentials
- Use environment-specific tokens (dev vs prod)

## Docker Files

### `Dockerfile.postgres`
PostgreSQL 17 with pg_semantic_cache and pgvector pre-installed.
Configured for Ollama demo (1024 dimensions).

### `Dockerfile.postgres.openai`
PostgreSQL 17 configured for OpenAI demo (1536 dimensions).

### `docker-compose.yml`
Complete stack for Ollama demo:
- PostgreSQL with extensions
- Python app container
- Network configuration

### `docker-compose.openai.yml`
Complete stack for OpenAI demo (requires API key).

## SQL Setup Files

### `setup.sql`
Initializes database for Ollama demo:
- Creates extension
- Sets vector dimension to 1024
- Configures IVFFlat index

### `setup_openai.sql`
Initializes database for OpenAI demo:
- Creates extension
- Sets vector dimension to 1536
- Configures IVFFlat index

## Troubleshooting

### Ollama Demo Issues

**"Connection refused to localhost:11434"**
```bash
# Start Ollama
ollama serve

# Pull required models
ollama pull mxbai-embed-large
ollama pull llama3.2:1b
```

**"Model not found"**
```bash
# Verify models are installed
ollama list

# Pull missing models
ollama pull mxbai-embed-large
ollama pull llama3.2:1b
```

### OpenAI Demo Issues

**"Authentication failed"**
- Check your OpenAI API key in `.env`
- Verify key is active: https://platform.openai.com/api-keys

**"Rate limit exceeded"**
- Add delay between requests
- Check your OpenAI usage limits

### Database Issues

**"Extension does not exist"**
```bash
# Build and install from project root
cd ../..
make clean && make
sudo make install

# Then run setup
psql -U postgres -f examples/demo/setup.sql
```

**"Vector dimension mismatch"**
```sql
-- Check current dimension
SELECT semantic_cache.get_vector_dimension();

-- Rebuild for correct dimension
SELECT semantic_cache.set_vector_dimension(1024);  -- or 1536
SELECT semantic_cache.rebuild_index();
```

## Performance Tips

1. **Cache Size:** Adjust based on your query volume
```sql
INSERT INTO semantic_cache.cache_config (key, value)
VALUES ('max_cache_size_mb', '500')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
```

2. **Similarity Threshold:** Lower = more cache hits
```python
# In demo code
result = cur.fetchone()  # Uses 0.95 default
# Try 0.90 for more aggressive caching
```

3. **Index Type:** Switch to HNSW for better accuracy
```sql
SELECT semantic_cache.set_index_type('hnsw');
SELECT semantic_cache.rebuild_index();
```

## Cost Comparison

Based on typical usage (1000 queries/day):

| Scenario | Without Cache | With Cache (80% hit) | Savings |
|----------|--------------|---------------------|---------|
| Ollama (Free) | $0 | $0 | N/A |
| OpenAI GPT-4 | $2,400/mo | $480/mo | **$1,920/mo** |
| OpenAI GPT-3.5 | $300/mo | $60/mo | **$240/mo** |

## Next Steps

1. Try both demos to see the difference
2. Modify questions to test semantic similarity
3. Check cache statistics:
```sql
SELECT * FROM semantic_cache.cache_stats();
SELECT * FROM semantic_cache.cost_savings_daily;
```
4. Integrate into your own application using the patterns shown

## Additional Resources

- Main documentation: `../../README.md`
- Function reference: `../../docs/functions/`
- Logging guide: `../../docs/logging.md`

## License

Same as main project - see LICENSE file in project root.
