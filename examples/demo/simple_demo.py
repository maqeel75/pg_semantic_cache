#!/usr/bin/env python3
"""
Simple pg_semantic_cache demo using Ollama for embeddings.

This demonstrates the core pg_semantic_cache functionality:
1. Cache query results with semantic embeddings
2. Retrieve similar cached results using cosine similarity
3. View cache statistics

Interactive mode: Ask questions and see semantic caching in action!

Uses mxbai-embed-large (1024 dimensions) - one of the best open-source
embedding models available through Ollama.

Before running:
  1. Install Ollama: https://ollama.com
  2. Pull models: ollama pull mxbai-embed-large && ollama pull llama3.2:1b
"""

import psycopg2
from psycopg2.extras import RealDictCursor, Json
import requests
import json
import time
import sys

# Configuration
DB_HOST = "localhost"
DB_PORT = 5434
DB_NAME = "postgres"
DB_USER = "postgres"
DB_PASSWORD = "postgres"

OLLAMA_HOST = "localhost:11434"
EMBEDDING_MODEL = "mxbai-embed-large"  # 1024 dimensions (best Ollama model)
LLM_MODEL = "llama3.2:1b"  # Model for generating answers (lighter/faster)
SIMILARITY_THRESHOLD = 0.89  # Threshold for cache hits (89% = balanced strict matching)

# NOTE: mxbai-embed-large produces 1024-dim vectors
# The setup.sql is configured for 1024 dims by default
# Alternative models: nomic-embed-text (768), all-minilm (384)


def get_embedding(text: str) -> list:
    """Get embedding from Ollama"""
    # Normalize text: lowercase and strip whitespace for consistent embeddings
    normalized_text = text.lower().strip()
    response = requests.post(
        f"http://{OLLAMA_HOST}/api/embeddings",
        json={"model": EMBEDDING_MODEL, "prompt": normalized_text}
    )
    return response.json()['embedding']


def generate_answer(question: str) -> str:
    """Generate answer using Ollama LLM"""
    print(f"   ⏳ Generating answer with {LLM_MODEL}...", end='', flush=True)
    start = time.time()

    try:
        response = requests.post(
            f"http://{OLLAMA_HOST}/api/generate",
            json={
                "model": LLM_MODEL,
                "prompt": f"Answer this question concisely in 2-3 sentences: {question}",
                "stream": False
            },
            timeout=60
        )
        response.raise_for_status()
        result = response.json()

        elapsed = time.time() - start
        print(f" ({elapsed:.2f}s)")

        return result.get('response', result.get('message', {}).get('content', 'No response generated'))
    except Exception as e:
        elapsed = time.time() - start
        print(f" ({elapsed:.2f}s)")
        print(f"\n   ⚠️  LLM generation failed: {e}")
        print(f"   Using fallback response...")
        return f"I don't have a cached answer for: {question}"


def interactive_mode():
    """Interactive Q&A mode with semantic caching"""
    print("=" * 70)
    print("pg_semantic_cache - Interactive Demo")
    print("=" * 70)

    # Connect to database
    print("\n⏳ Connecting to PostgreSQL...")
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )
    cur = conn.cursor(cursor_factory=RealDictCursor)
    print("✓ Connected to PostgreSQL")

    # Test Ollama connection
    print(f"⏳ Testing Ollama ({EMBEDDING_MODEL})...")
    try:
        test_emb = get_embedding("test")
        print(f"✓ Connected to Ollama (embedding dimension: {len(test_emb)})")
    except Exception as e:
        print(f"✗ Ollama connection failed: {e}")
        return

    print("\n" + "=" * 70)
    print("Ask any question and see semantic caching in action!")
    print("Commands: 'stats' (show stats), 'clear' (clear cache), 'exit' (quit)")
    print("Similarity threshold: {:.2f}".format(SIMILARITY_THRESHOLD))
    print("=" * 70 + "\n")

    while True:
        try:
            # Get user input
            user_question = input("❓ Your question> ").strip()

            if not user_question:
                continue

            # Handle commands
            if user_question.lower() in ['exit', 'quit', 'q']:
                print("\n👋 Goodbye!")
                break

            elif user_question.lower() == 'stats':
                cur.execute("SELECT * FROM semantic_cache.cache_stats()")
                stats = cur.fetchone()
                print(f"\n📊 Cache Statistics:")
                print(f"   Total entries: {stats['total_entries']}")
                print(f"   Cache hits: {stats['total_hits']}")
                print(f"   Cache misses: {stats['total_misses']}")
                print(f"   Hit rate: {stats['hit_rate_percent']:.1f}%\n")
                continue

            elif user_question.lower() == 'clear':
                cur.execute("SELECT semantic_cache.clear_cache()")
                conn.commit()
                print("✓ Cache cleared\n")
                continue

            # Process question
            print()
            start_total = time.time()

            # Generate embedding
            print("⏳ Generating embedding...", end='', flush=True)
            start = time.time()
            embedding = get_embedding(user_question)
            embedding_str = '[' + ','.join(map(str, embedding)) + ']'
            print(f" ({time.time() - start:.2f}s)")

            # Check cache
            print("⏳ Checking semantic cache...", end='', flush=True)
            start = time.time()
            cur.execute(
                """
                SELECT * FROM semantic_cache.get_cached_result(
                    %s::text,
                    %s::float4,
                    NULL
                )
                """,
                (embedding_str, SIMILARITY_THRESHOLD)
            )
            result = cur.fetchone()
            cache_time = time.time() - start

            if result and result['found']:
                # Cache hit!
                similarity_pct = result['similarity_score']
                print(f" ✓ CACHE HIT! Similarity: {similarity_pct:.1%} ({cache_time:.3f}s)")
                print(f"\n💡 Answer (from cache):")
                answer = result['result_data']
                if isinstance(answer, str) and answer.startswith('"'):
                    answer = json.loads(answer)
                print(f"{answer}")
                print(f"\n⚡ Total time: {time.time() - start_total:.2f}s (LLM call saved!)")

            else:
                # Cache miss - find closest match to show similarity
                cur.execute(
                    """
                    SELECT
                        (1 - (query_embedding <=> %s::vector))::float4 as similarity
                    FROM semantic_cache.cache_entries
                    WHERE expires_at IS NULL OR expires_at > NOW()
                    ORDER BY query_embedding <=> %s::vector
                    LIMIT 1
                    """,
                    (embedding_str, embedding_str)
                )
                closest = cur.fetchone()

                if closest:
                    closest_sim = closest['similarity']
                    print(f" ✗ Cache miss - closest: {closest_sim:.2%} < {SIMILARITY_THRESHOLD:.0%} threshold ({cache_time:.3f}s)")
                else:
                    print(f" ✗ Cache miss - no entries yet ({cache_time:.3f}s)")

                # Generate answer with LLM
                answer = generate_answer(user_question)

                # Display answer
                print(f"\n💡 Answer (generated):")
                print(f"{answer}")

                # Cache the result
                print("\n⏳ Caching answer...", end='', flush=True)
                cur.execute(
                    """
                    SELECT semantic_cache.cache_query(
                        %s::text,
                        %s::text,
                        %s,
                        3600,
                        ARRAY[]::text[]
                    )
                    """,
                    (user_question, embedding_str, Json(answer))
                )
                conn.commit()
                print(" ✓")

                print(f"\n⏱️  Total time: {time.time() - start_total:.2f}s")

            # Show quick stats
            cur.execute("SELECT * FROM semantic_cache.cache_stats()")
            stats = cur.fetchone()
            print(f"\n{'─'*70}")
            print(f"📈 Stats: {stats['total_entries']} entries | "
                  f"{stats['total_hits']} hits | "
                  f"{stats['total_misses']} misses | "
                  f"Hit rate: {stats['hit_rate_percent']:.1f}%")
            print()

        except KeyboardInterrupt:
            print("\n\n👋 Goodbye!")
            break
        except Exception as e:
            print(f"\n✗ Error: {e}\n")

    cur.close()
    conn.close()


def main():
    """Run interactive mode by default"""
    interactive_mode()


if __name__ == "__main__":
    main()
