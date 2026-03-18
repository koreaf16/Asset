# 05. L1 : 피처 엔진 — 35차원 벡터 생성 + 이벤트 감지

## 역할
Ring Buffer에서 원시 데이터를 읽어 35차원 숫자 벡터를 산출하고, 이벤트 플래그를 감지하여 TB_SNAPSHOT에 비동기 저장.

## 구성요소
```
L1_FeatureEngine/
├── microstructure.py    # 미시구조 피처 7개 계산
├── window_summary.py    # 시간 윈도우 요약 18개 (1/5/15분 × 6)
├── derived_features.py  # 파생 지표 10개
├── normalizer.py        # Rolling z-score 정규화
├── event_detector.py    # 이벤트 플래그 감지
├── vector_builder.py    # 35D 벡터 조립
└── snapshot_writer.py   # TB_SNAPSHOT 비동기 INSERT
```

## 피처 계산 상세

### 미시구조 피처 (즉시, Ring Buffer에서 직접 계산)

| # | 피처 | 계산 방식 |
|---|------|----------|
| 0 | bid_ask_spread | `(best_ask - best_bid) / mid_price * 100` |
| 1 | ob_imbalance | `(bid_vol_5 - ask_vol_5) / (bid_vol_5 + ask_vol_5)` — 상위 5호가 수량 합 |
| 2 | vwap_dev | `(price - vwap_1m) / vwap_1m * 100` |
| 3 | buy_sell_ratio | `buy_volume / total_volume` (직전 30초) |
| 4 | trades_per_sec | 직전 10초 체결 건수 / 10 |
| 5 | depth_pressure | `bid_total_5 / ask_total_5` |
| 6 | price_z_score | `(price - mean_1h) / std_1h` |

### 시간 윈도우 요약 (1분/5분/15분 각 6개 = 18개)

| # | 피처 | 계산 방식 |
|---|------|----------|
| 0 | ret | `(close - open) / open * 100` |
| 1 | vol | `std(returns)` |
| 2 | volume_chg | `(current_vol - prev_vol) / prev_vol` |
| 3 | high_low_range | `(high - low) / open * 100` |
| 4 | close_position | `(close - low) / (high - low)` (0=저점, 1=고점) |
| 5 | tick_count | 해당 윈도우 내 총 체결 건수 |

### 파생 지표 (10개)

| # | 피처 | 계산 방식 |
|---|------|----------|
| 30 | momentum_1m | `ret_1m - ret_1m_prev` (가속도) |
| 31 | momentum_5m | `ret_5m - ret_5m_prev` |
| 32 | rsi_14 | RSI 14 (0~100 → 0~1 정규화) |
| 33 | vol_ratio_1m5m | `vol_1m / vol_5m` (단기 변동성 확대 비율) |
| 34 | spread_z_score | `(spread - mean_spread_1h) / std_spread_1h` |

## Rolling Z-Score 정규화

```python
class RollingNormalizer:
    """직전 1시간 (1200개 스냅샷) 기준 z-score"""
    def __init__(self, window=1200):
        self.window = window
        self.history = {}  # {feature_name: deque(maxlen=window)}
    
    def normalize(self, feature_name, value):
        if feature_name not in self.history:
            self.history[feature_name] = deque(maxlen=self.window)
        
        self.history[feature_name].append(value)
        
        if len(self.history[feature_name]) < 30:
            return 0.0  # 초기 워밍업
        
        arr = np.array(self.history[feature_name])
        mean, std = arr.mean(), arr.std()
        if std < 1e-10:
            return 0.0
        return (value - mean) / std
```

**주의**: 정규화 이전의 원본 값도 TB_SNAPSHOT의 관계형 컬럼에 저장해야 함. 벡터에는 정규화된 값, 컬럼에는 원본 값.

## 이벤트 감지 (비트마스크)

```python
def detect_events(current, rolling_stats):
    flags = 0
    
    if current.volume_1m > rolling_stats.volume_avg_5m * 2:
        flags |= 1   # 거래량 급증
    
    if abs(current.imbalance - rolling_stats.imbalance_prev) > 0.4:
        flags |= 2   # 호가 급변
    
    if current.spread > rolling_stats.spread_avg_5m * 3:
        flags |= 4   # spread 확대
    
    if current.price > rolling_stats.bb_upper or current.price < rolling_stats.bb_lower:
        flags |= 8   # 볼린저 돌파
    
    if has_news_event(current.symbol):
        flags |= 16  # 뉴스 이벤트
    
    return flags
```

| 비트 | 값 | 이벤트 | 조건 |
|------|-----|--------|------|
| 0 | 1 | VOL_SURGE | 1분 거래량 > 5분 평균 × 2 |
| 1 | 2 | OB_SHIFT | imbalance 변화 > 0.4 |
| 2 | 4 | SPREAD_WIDE | spread > 5분 평균 × 3 |
| 3 | 8 | BB_BREAK | 1분 볼린저 밴드 돌파 |
| 4 | 16 | NEWS_EVENT | Tiingo impact > 0.5 뉴스 감지 |

## 성능 고려사항

- NumPy 벡터 연산으로 35개 피처 계산: ~1-2ms
- 병목이 되면 이 모듈만 Cython 또는 Rust pyo3로 교체 가능
- 인터페이스: `async def process_snapshot(symbol, ring_buffer) -> (np.ndarray, dict, int)`
  - 반환: (35D 벡터, 원본 피처 dict, event_flags)
