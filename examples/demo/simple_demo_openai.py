#!/usr/bin/env python3
"""
Simple pg_semantic_cache demo using OpenAI for embeddings.

This demonstrates the core pg_semantic_cache functionality:
1. Cache query results with semantic embeddings
2. Retrieve similar cached results using cosine similarity
3. View cache statistics

Interactive mode: Ask questions and see semantic caching in action!

Uses OpenAI's text-embedding-3-small (1536 dimensions) for embeddings
and gpt-4o-mini for answer generation.

Before running:
  1. Install OpenAI SDK: pip install openai
  2. Set your API key: export OPENAI_API_KEY='your-key-here'
  3. Update database to 1536 dimensions (see instructions below)
"""

import psycopg2
from psycopg2.extras import RealDictCursor, Json
import json
import time
import sys
import os

try:
    from openai import OpenAI
except ImportError:
    print("❌ OpenAI SDK not installed. Install it with: pip install openai")
    sys.exit(1)

# Configuration
DB_HOST = "localhost"
DB_PORT = 5434
DB_NAME = "postgres"
DB_USER = "postgres"
DB_PASSWORD = "postgres"

# OpenAI Configuration
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY")
EMBEDDING_MODEL = "text-embedding-3-small"  # 1536 dimensions
LLM_MODEL = "gpt-4o-mini"  # Fast and cost-effective
SIMILARITY_THRESHOLD = 0.89  # Threshold for cache hits (89% = balanced strict matching)

# NOTE: text-embedding-3-small produces 1536-dim vectors (OpenAI default)
# You need to configure the database for 1536 dimensions:
#   SELECT semantic_cache.set_vector_dimension(1536);
#   SELECT semantic_cache.rebuild_index();  -- WARNING: Clears all cached data


def get_embedding(text: str) -> list:
    """Get embedding from OpenAI"""
    if not OPENAI_API_KEY:
        raise ValueError("OPENAI_API_KEY environment variable not set")

    client = OpenAI(api_key=OPENAI_API_KEY)

    # Normalize text: lowercase and strip whitespace for consistent embeddings
    normalized_text = text.lower().strip()

    response = client.embeddings.create(
        model=EMBEDDING_MODEL,
        input=normalized_text
    )

    return response.data[0].embedding


def generate_answer(question: str) -> str:
    """Generate answer using OpenAI LLM"""
    if not OPENAI_API_KEY:
        return f"OpenAI API key not set. Cannot generate answer for: {question}"

    print(f"   ⏳ Generating answer with {LLM_MODEL}...", end='', flush=True)
    start = time.time()

    try:
        client = OpenAI(api_key=OPENAI_API_KEY)

        response = client.chat.completions.create(
            model=LLM_MODEL,
            messages=[
                {"role": "system", "content": "You are a helpful assistant. Answer questions concisely in 2-3 sentences."},
                {"role": "user", "content": question}
            ],
            temperature=0.7,
            max_tokens=150
        )

        elapsed = time.time() - start
        print(f" ({elapsed:.2f}s)")

        return response.choices[0].message.content
    except Exception as e:
        elapsed = time.time() - start
        print(f" ({elapsed:.2f}s)")
        print(f"\n   ⚠️  LLM generation failed: {e}")
        print(f"   Using fallback response...")
        return f"I don't have a cached answer for: {question}"


def interactive_mode():
    """Interactive Q&A mode with semantic caching"""
    print("=" * 70)
    print("pg_semantic_cache - Interactive Demo (OpenAI)")
    print("=" * 70)

    # Check API key
    if not OPENAI_API_KEY:
        print("\n❌ OPENAI_API_KEY environment variable not set!")
        print("   Set it with: export OPENAI_API_KEY='your-key-here'")
        print("   Or in Python: os.environ['OPENAI_API_KEY'] = 'your-key-here'\n")
        return

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

    # Check vector dimension configuration
    cur.execute("SELECT semantic_cache.get_vector_dimension()")
    current_dim = cur.fetchone()['get_vector_dimension']

    if current_dim != 1536:
        print(f"\n⚠️  WARNING: Database is configured for {current_dim} dimensions")
        print(f"   OpenAI embeddings are 1536 dimensions")
        print(f"   You need to reconfigure:")
        print(f"     SELECT semantic_cache.set_vector_dimension(1536);")
        print(f"     SELECT semantic_cache.rebuild_index();  -- WARNING: Clears cache")
        print()
        proceed = input("   Continue anyway? (y/N): ").strip().lower()
        if proceed != 'y':
            print("   Exiting...")
            return

    # Test OpenAI connection
    print(f"⏳ Testing OpenAI API ({EMBEDDING_MODEL})...")
    try:
        test_emb = get_embedding("test")
        print(f"✓ Connected to OpenAI API (embedding dimension: {len(test_emb)})")
    except Exception as e:
        print(f"✗ OpenAI API connection failed: {e}")
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
                # Cache miss - use similarity_score from get_cached_result
                closest_sim = result['similarity_score'] if result else 0.0

                if closest_sim > 0.0:
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
