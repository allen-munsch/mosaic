# ranking/ — Multi-Signal Result Ranking

Configurable ranking pipeline with weighted scorer fusion (RRF,
weighted sum, max). Each scorer is a behaviour module.

## Modules

- `ranker.ex` — Ranker struct with scorers, weights, fusion strategy, min_score
- `fusion.ex` — Fusion strategies: :weighted_sum, :rrf (Reciprocal Rank Fusion), :max
- `scorer.ex` — Behaviour for scoring modules
- `scorers/vector_similarity.ex` — Cosine distance scoring
- `scorers/bm25.ex` — Lexical relevance (BM25)
- `scorers/pagerank.ex` — Link authority scoring
- `scorers/freshness.ex` — Time-decay scoring
- `scorers/text_match.ex` — Text match boost

## Isolation

- **Depends on**: `config.ex`
- **Does NOT depend on**: any other domain
- **Consumed by**: query_engine.ex (result ranking)

## Adding a New Scorer

1. Create `ranking/scorers/new_scorer.ex`
2. Implement `@behaviour Mosaic.Ranking.Scorer`
3. Add to `ranker.ex` defaults
