package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Config struct {
	CacheEnabled           bool
	CacheSimilarityThreshold float32
	CacheTTLSeconds        int
}

type Server struct {
	dbPool *pgxpool.Pool
	config Config
}

type QueryRequest struct {
	Query          string `json:"query" binding:"required"`
	IncludeSources bool   `json:"include_sources"`
}

type QueryResponse struct {
	Answer         string   `json:"answer"`
	Sources        []string `json:"sources,omitempty"`
	CacheHit       bool     `json:"cache_hit"`
	SimilarityScore float32 `json:"similarity_score,omitempty"`
	ProcessingTime int64    `json:"processing_time_ms"`
}

type CacheStats struct {
	TotalEntries      int     `json:"total_entries"`
	HitCount          int     `json:"hit_count"`
	MissCount         int     `json:"miss_count"`
	HitRatePercent    float32 `json:"hit_rate_percent"`
	TotalCostSaved    float64 `json:"total_cost_saved"`
}

func main() {
	// Load configuration from environment
	config := Config{
		CacheEnabled:           os.Getenv("CACHE_ENABLED") == "true",
		CacheSimilarityThreshold: 0.95,
		CacheTTLSeconds:        3600,
	}

	// Connect to PostgreSQL
	dbURL := fmt.Sprintf("postgres://%s:%s@%s:%s/%s",
		getEnv("CACHE_USER", "postgres"),
		getEnv("CACHE_PASSWORD", "postgres"),
		getEnv("CACHE_HOST", "localhost"),
		getEnv("CACHE_PORT", "5432"),
		getEnv("CACHE_DB_NAME", "rag_db"),
	)

	pool, err := pgxpool.New(context.Background(), dbURL)
	if err != nil {
		log.Fatalf("Unable to connect to database: %v\n", err)
	}
	defer pool.Close()

	// Verify cache is available
	if config.CacheEnabled {
		var exists bool
		err = pool.QueryRow(context.Background(),
			"SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_semantic_cache')").Scan(&exists)
		if err != nil || !exists {
			log.Println("WARNING: pg_semantic_cache extension not found, disabling cache")
			config.CacheEnabled = false
		} else {
			log.Println("✓ pg_semantic_cache extension detected and enabled")
		}
	}

	server := &Server{
		dbPool: pool,
		config: config,
	}

	// Setup router
	r := gin.Default()

	r.GET("/health", server.healthCheck)
	r.GET("/cache/stats", server.getCacheStats)
	r.POST("/v1/query", server.handleQuery)
	r.DELETE("/cache/clear", server.clearCache)

	log.Println("🚀 RAG Server starting on :8080")
	log.Printf("   Cache enabled: %v", config.CacheEnabled)
	log.Printf("   Similarity threshold: %.2f", config.CacheSimilarityThreshold)
	log.Printf("   TTL: %d seconds", config.CacheTTLSeconds)

	if err := r.Run(":8080"); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}

func (s *Server) healthCheck(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"status": "healthy",
		"cache_enabled": s.config.CacheEnabled,
		"timestamp": time.Now().Unix(),
	})
}

func (s *Server) handleQuery(c *gin.Context) {
	var req QueryRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	startTime := time.Now()

	// For this test, we'll use a simple mock embedding
	// In production, this would call OpenAI/Voyage/etc
	mockEmbedding := generateMockEmbedding(req.Query)

	var resp QueryResponse

	// Check cache if enabled
	if s.config.CacheEnabled {
		cached, err := s.checkCache(c.Request.Context(), mockEmbedding)
		if err == nil && cached != nil {
			resp = *cached
			resp.CacheHit = true
			resp.ProcessingTime = time.Since(startTime).Milliseconds()
			c.JSON(http.StatusOK, resp)

			log.Printf("✓ CACHE HIT - Query: '%s' (similarity: %.4f, time: %dms)",
				req.Query, cached.SimilarityScore, resp.ProcessingTime)
			return
		}
	}

	// Cache miss - generate response
	answer := s.generateAnswer(c.Request.Context(), req.Query)

	resp = QueryResponse{
		Answer:   answer,
		CacheHit: false,
		ProcessingTime: time.Since(startTime).Milliseconds(),
	}

	// Store in cache if enabled
	if s.config.CacheEnabled {
		s.cacheResult(c.Request.Context(), req.Query, mockEmbedding, &resp)
	}

	log.Printf("✗ CACHE MISS - Query: '%s' (time: %dms)",
		req.Query, resp.ProcessingTime)

	c.JSON(http.StatusOK, resp)
}

func (s *Server) checkCache(ctx context.Context, embedding string) (*QueryResponse, error) {
	query := `
		SELECT
			found,
			result_data,
			similarity_score
		FROM semantic_cache.get_cached_result(
			$1::text,
			$2::float4,
			NULL
		)
	`

	var found bool
	var resultJSON []byte
	var similarity float32

	err := s.dbPool.QueryRow(ctx, query, embedding, s.config.CacheSimilarityThreshold).
		Scan(&found, &resultJSON, &similarity)

	if err != nil || !found {
		return nil, fmt.Errorf("cache miss")
	}

	var resp QueryResponse
	if err := json.Unmarshal(resultJSON, &resp); err != nil {
		return nil, err
	}

	resp.SimilarityScore = similarity
	return &resp, nil
}

func (s *Server) cacheResult(ctx context.Context, query string, embedding string, resp *QueryResponse) error {
	respJSON, err := json.Marshal(resp)
	if err != nil {
		return err
	}

	cacheQuery := `
		SELECT semantic_cache.cache_query(
			$1::text,
			$2::text,
			$3::jsonb,
			$4::integer,
			ARRAY['rag-test']::text[]
		)
	`

	_, err = s.dbPool.Exec(ctx, cacheQuery, query, embedding, string(respJSON), s.config.CacheTTLSeconds)
	return err
}

func (s *Server) generateAnswer(ctx context.Context, query string) string {
	// Simulate LLM processing time (2-3 seconds)
	time.Sleep(2 * time.Second)

	// Return mock answer
	return fmt.Sprintf("This is a mock answer for: %s. In production, this would be generated by GPT-4 or Claude based on retrieved documents.", query)
}

func (s *Server) getCacheStats(c *gin.Context) {
	if !s.config.CacheEnabled {
		c.JSON(http.StatusOK, gin.H{"error": "cache not enabled"})
		return
	}

	query := `SELECT * FROM semantic_cache.cache_stats()`

	var stats CacheStats
	err := s.dbPool.QueryRow(c.Request.Context(), query).Scan(
		&stats.TotalEntries,
		&stats.HitCount,
		&stats.MissCount,
		&stats.HitRatePercent,
	)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, stats)
}

func (s *Server) clearCache(c *gin.Context) {
	if !s.config.CacheEnabled {
		c.JSON(http.StatusOK, gin.H{"error": "cache not enabled"})
		return
	}

	_, err := s.dbPool.Exec(c.Request.Context(), "SELECT semantic_cache.clear_cache()")
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"status": "cache cleared"})
}

// Helper functions
func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func generateMockEmbedding(text string) string {
	// Generate a simple deterministic "embedding" for testing
	// In production, this would call OpenAI's embedding API
	// For now, we'll create a 1536-dimensional vector with simple values
	embedding := "["
	for i := 0; i < 1536; i++ {
		if i > 0 {
			embedding += ","
		}
		// Simple hash-based generation for deterministic results
		val := float32(len(text)+i) / 1536.0
		embedding += fmt.Sprintf("%.6f", val)
	}
	embedding += "]"
	return embedding
}
