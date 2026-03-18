# 06. L2 : 전략 엔진 — 패턴 매칭 + 후방 추적 + 신호 판단

## 역할
L1에서 생성된 35D 벡터를 Oracle HNSW로 검색하여 유사 패턴을 찾고, 동시에 후방 추적으로 위험을 감지하여 매수/매도/회피 신호를 판단.

## 구성요소
```
L2_StrategyEngine/
├── pattern_matcher.py     # 전방: TB_PATTERN HNSW 검색
├── inflection_scanner.py  # 후방: TB_INFLECTION HNSW 검색
├── trajectory_builder.py  # 현재 시점 전조 벡터 (50D) 실시간 조립
├── signal_scorer.py       # 매칭 결과 종합 점수 산출
├── signal_decider.py      # 최종 진입/회피 결정
└── oracle_client.py       # Oracle 26ai VECTOR 쿼리 래퍼
```

## 양방향 검색 흐름

```
L1 → 35D num_vector 수신
      │
      ├── [전방] TB_PATTERN HNSW 검색
      │     "이 시장 상태와 비슷했던 과거 패턴이 있는가?"
      │     → Top K 후보 (유사도, 승률, MFE/MAE)
      │
      ├── [후방] TB_INFLECTION HNSW 검색
      │     "현재 시장 궤적이 과거 급락 전조와 비슷한가?"
      │     → 위험 패턴 매칭 여부
      │
      └── [판단] signal_scorer + signal_decider
            전방 결과 + 후방 결과 종합 → ENTRY / SKIP / EXIT_EXISTING
```

## 전방 패턴 매칭 (pattern_matcher.py)

```python
async def match_patterns(current_vec, symbol, regime, config):
    """
    TB_PATTERN에서 HNSW 검색.
    관계형 필터 + 벡터 유사도 결합.
    """
    rows = await oracle.execute("""
        SELECT pattern_id, label, win_rate, mfe_mae_ratio,
               sim_win_rate, avg_ret_5m, description,
               VECTOR_DISTANCE(num_vector, :vec, COSINE) AS dist
        FROM   TB_PATTERN
        WHERE  is_active = 1
          AND  symbol = :symbol
          AND  (regime IS NULL OR regime = :regime)
        ORDER  BY VECTOR_DISTANCE(num_vector, :vec, COSINE)
        FETCH  FIRST :top_k ROWS ONLY
    """, vec=current_vec, symbol=symbol, regime=regime, top_k=config.L2_TOP_K)
    
    # 유사도 필터 (distance → similarity 변환)
    candidates = []
    for r in rows:
        similarity = 1 - r["dist"]
        if similarity >= config.L2_MIN_SIMILARITY:
            candidates.append({**r, "similarity": similarity})
    
    return candidates
```

## 후방 전조 검색 (inflection_scanner.py)

```python
async def scan_precursors(current_trajectory, symbol):
    """
    현재 시장 궤적(50D)이 과거 변곡점 전조와 유사한지 검색.
    """
    # 위험 패턴 (급락, 하락 반전) 검색
    dangers = await oracle.execute("""
        SELECT inflection_id, inflection_type, magnitude, avg_lead_time,
               occurrence_count,
               VECTOR_DISTANCE(precursor_vector, :vec, COSINE) AS dist
        FROM   TB_INFLECTION
        WHERE  symbol = :symbol
          AND  inflection_type IN ('CRASH', 'REVERSAL_DOWN')
        ORDER  BY VECTOR_DISTANCE(precursor_vector, :vec, COSINE)
        FETCH  FIRST 3 ROWS ONLY
    """, vec=current_trajectory, symbol=symbol)
    
    # 기회 패턴 (급등, 상승 반전) 검색
    opportunities = await oracle.execute("""
        SELECT inflection_id, inflection_type, magnitude, avg_lead_time,
               occurrence_count,
               VECTOR_DISTANCE(precursor_vector, :vec, COSINE) AS dist
        FROM   TB_INFLECTION
        WHERE  symbol = :symbol
          AND  inflection_type IN ('SURGE', 'REVERSAL_UP')
        ORDER  BY VECTOR_DISTANCE(precursor_vector, :vec, COSINE)
        FETCH  FIRST 3 ROWS ONLY
    """, vec=current_trajectory, symbol=symbol)
    
    return {
        "dangers": [r for r in dangers if 1 - r["dist"] >= 0.80],
        "opportunities": [r for r in opportunities if 1 - r["dist"] >= 0.80],
    }
```

## 전조 벡터 실시간 조립 (trajectory_builder.py)

```python
class TrajectoryBuilder:
    """
    매 스냅샷마다 현재 시점의 50D 전조 벡터를 조립.
    TB_SNAPSHOT에서 과거 스냅샷을 읽지 않고, 로컬 캐시에서 계산.
    """
    def __init__(self):
        self.snap_cache = {}  # {symbol: deque(maxlen=200)} 직전 10분 스냅샷

    def build(self, symbol, current_features):
        history = self.snap_cache.get(symbol, [])
        if len(history) < 20:
            return None  # 워밍업 부족
        
        t_30s = self._find_nearest(history, seconds_ago=30)
        t_1m  = self._find_nearest(history, seconds_ago=60)
        t_3m  = self._find_nearest(history, seconds_ago=180)
        t_5m  = self._find_nearest(history, seconds_ago=300)
        
        # 차분 계산 (현재 - 과거)
        diff_30s = current_features[:10] - t_30s[:10]
        diff_1m  = current_features[:10] - t_1m[:10]
        diff_3m  = current_features[:10] - t_3m[:10]
        diff_5m  = current_features[:10] - t_5m[:10]
        
        # 궤적 파생 지표
        derived = self._compute_derivatives(diff_30s, diff_1m, diff_3m, diff_5m)
        
        return np.concatenate([diff_30s, diff_1m, diff_3m, diff_5m, derived])
```

## 신호 판단 로직 (signal_decider.py)

```python
async def decide(forward_matches, backward_scan, config):
    """
    전방 + 후방 결과를 종합하여 최종 결정.
    
    반환: ("ENTRY_BUY", details) | ("ENTRY_SELL", details) | ("SKIP", reason)
    """
    
    # 1. 후방 위험 체크 (최우선)
    if backward_scan["dangers"]:
        best_danger = backward_scan["dangers"][0]
        if best_danger["similarity"] >= 0.85:
            return "SKIP", f"급락 전조 감지 (유사도 {best_danger['similarity']:.2f}, 과거 평균 {best_danger['magnitude']:.2f}%)"
    
    # 2. 전방 패턴 매칭 없음
    if not forward_matches:
        return "SKIP", "매칭 패턴 없음"
    
    # 3. 최고 매칭 패턴 평가
    best = forward_matches[0]
    
    # 모의거래 실전 검증이 있으면 반영
    if best["sim_trade_count"] and best["sim_trade_count"] >= 10:
        effective_wr = best["sim_win_rate"]  # 실전 승률 우선
    else:
        effective_wr = best["win_rate"]  # 이론 승률
    
    if effective_wr < config.PATTERN_MIN_WINRATE:
        return "SKIP", f"승률 미달 ({effective_wr:.2f})"
    
    # 4. 후방 기회 패턴으로 가중치 부스트
    boost = 1.0
    if backward_scan["opportunities"]:
        best_opp = backward_scan["opportunities"][0]
        if best_opp["similarity"] >= 0.80:
            boost = 1.2  # 급등 전조 감지 시 신호 강화
    
    # 5. 최종 결정
    signal_strength = best["similarity"] * effective_wr * best["mfe_mae_ratio"] * boost
    
    if signal_strength >= 1.0:  # 임계치
        side = "BUY" if best["label"] == "BUY_GOOD" else "SELL"
        return f"ENTRY_{side}", {
            "pattern_id": best["pattern_id"],
            "similarity": best["similarity"],
            "win_rate": effective_wr,
            "signal_strength": signal_strength,
            "description": best["description"],
        }
    
    return "SKIP", f"신호 강도 미달 ({signal_strength:.2f})"
```

## 실시간 경로에서 DB 호출

| 호출 | 대상 | 예상 지연 | 비고 |
|------|------|----------|------|
| 전방 HNSW | TB_PATTERN (~수백 row) | ~0.1ms | SGA 메모리 상주 |
| 후방 HNSW | TB_INFLECTION (~수천 row) | ~0.2ms | SGA 메모리 상주 |
| **합계** | | **< 1ms** | |
