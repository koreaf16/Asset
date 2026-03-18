# 02. Oracle 26ai 스키마 설계

## 테이블 전체 맵

| # | 테이블 | 역할 | VECTOR 컬럼 | HNSW | 일간 예상 row |
|---|--------|------|-------------|------|-------------|
| 1 | TB_SNAPSHOT | 시장 스냅샷 (시스템 핵심) | num_vector(35D), outcome_vector(15D), ctx_vector(1024D) | idx_snap_num | ~28,800/심볼 |
| 2 | TB_PATTERN | 승격된 패턴 | num_vector(35D) | idx_pat_num | 수십~수백 (누적) |
| 3 | TB_SIM_TRADE | 모의거래 기록 | trade_vector(25D) | idx_trade_vec | 수~수십 |
| 4 | TB_INFLECTION | 변곡점 (후방 추적) | precursor_vector(50D) | idx_inflect_precursor | 수십 |
| 5 | TB_NEWS_SIGNAL | Tiingo 뉴스 신호 | news_vector(1024D) | idx_news_vec | ~100 |
| 6 | TB_MACRO_REGIME | FRED 거시 데이터 | — | — | 1 |
| 7 | TB_SEC_FILING | SEC EDGAR 공시 | filing_vector(1024D) | — | ~10 |
| 8 | TB_LLM_LOG | Qwen 분석 로그 | — | — | ~100 |
| 9 | TB_SYSTEM_CONFIG | 런타임 설정 | — | — | ~20 (고정) |

## DDL

별도 파일 `schema_v1.2.sql` 참조. 주요 사항:

- TB_SNAPSHOT은 `PARTITION BY RANGE (ts) INTERVAL 1 DAY` 적용 (오래된 데이터 정리 용이)
- TB_PATTERN에 `CHECK (sample_count >= 30 AND win_rate >= 0.6 AND mfe_mae_ratio >= 2.0)` 제약으로 승격 기준 DB 레벨 강제
- 모든 HNSW 인덱스는 `DISTANCE COSINE WITH TARGET ACCURACY 95`
- 수수료 관련 컬럼: fee_entry_rate, fee_exit_rate, fee_roundtrip, ret_fwd_5m_net, mfe_5m_net, mfe_mae_ratio_net

## TB_SYSTEM_CONFIG 설정값 목록

| 키 | 기본값 | 설명 |
|----|--------|------|
| SNAPSHOT_INTERVAL_SEC | 3 | 스냅샷 수집 주기 (초) |
| LABEL_DELAY_MIN | 15 | 라벨링 대기 시간 (분) |
| PATTERN_MIN_SAMPLES | 30 | 패턴 승격 최소 출현 횟수 |
| PATTERN_MIN_WINRATE | 0.6 | 패턴 승격 최소 승률 |
| PATTERN_MIN_MFE_MAE | 2.0 | 패턴 승격 최소 MFE/MAE 비율 |
| RISK_MAX_POSITION_PCT | 5.0 | 최대 포지션 비율 (%) |
| RISK_STOP_LOSS_PCT | 1.0 | 손절 비율 (%) |
| RISK_TAKE_PROFIT_PCT | 1.5 | 익절 비율 (%) |
| RISK_MAX_DAILY_LOSS | 3.0 | 일일 최대 손실 (%) |
| RISK_MAX_OPEN_TRADES | 3 | 최대 동시 진입 수 |
| RISK_MAX_HOLD_SEC | 300 | 최대 보유 시간 (초) |
| RISK_COOLDOWN_SEC | 60 | 손절 후 대기 시간 (초) |
| L2_TOP_K | 20 | HNSW 1차 후보 수 |
| L2_FINAL_K | 5 | 최종 매칭 패턴 수 |
| L2_MIN_SIMILARITY | 0.85 | 최소 유사도 임계치 |
| TRADING_SYMBOLS | BTCUSDT,ETHUSDT,SOLUSDT | 거래 대상 심볼 |
| TESTNET_MODE | 1 | 모의거래 모드 |
| FEE_MAKER_RATE | 0.075 | Maker 수수료 (%, BNB 할인 후) |
| FEE_TAKER_RATE | 0.075 | Taker 수수료 (%, BNB 할인 후) |
| FEE_ENTRY_TYPE | MAKER | 진입 주문 방식 |
| FEE_EXIT_TYPE | TAKER | 청산 주문 방식 |
| FEE_BNB_DISCOUNT | 0.25 | BNB 할인율 |
| LABEL_MIN_RET_NET | 0.8 | 라벨링 최소 순수익률 (%) |
| ORDER_UNFILL_TIMEOUT | 10 | 미체결 취소 대기 (초) |
| ORDER_EXIT_LIMIT_TIMEOUT | 3 | 익절 지정가 대기 (초) |

## 핵심 쿼리

### L2 전방 패턴 매칭
```sql
SELECT pattern_id, label, win_rate, mfe_mae_ratio,
       VECTOR_DISTANCE(num_vector, :current_vec, COSINE) AS dist
FROM   TB_PATTERN
WHERE  is_active = 1 AND symbol = :symbol
  AND  (regime IS NULL OR regime = :current_regime)
ORDER  BY VECTOR_DISTANCE(num_vector, :current_vec, COSINE)
FETCH  FIRST 20 ROWS ONLY;
```

### L2 후방 전조 검색
```sql
SELECT inflection_id, inflection_type, magnitude, avg_lead_time,
       VECTOR_DISTANCE(precursor_vector, :current_trajectory, COSINE) AS dist
FROM   TB_INFLECTION
WHERE  symbol = :symbol AND inflection_type IN ('CRASH','REVERSAL_DOWN')
ORDER  BY VECTOR_DISTANCE(precursor_vector, :current_trajectory, COSINE)
FETCH  FIRST 3 ROWS ONLY;
```

### 사후 라벨링 (수수료 반영)
```sql
UPDATE TB_SNAPSHOT
SET    ret_fwd_5m_net = ret_fwd_5m - fee_roundtrip,
       mfe_5m_net = mfe_5m - fee_roundtrip,
       mfe_mae_ratio_net = (mfe_5m - fee_roundtrip) / GREATEST(mae_5m, 0.001),
       label = CASE
         WHEN ret_fwd_5m_net > :label_min_ret_net
          AND mfe_mae_ratio_net >= 2.0
         THEN 'BUY_GOOD'
         WHEN ret_fwd_5m_net < -:label_min_ret_net THEN 'SELL_GOOD'
         ELSE 'HOLD'
       END,
       labeled_at = SYSTIMESTAMP
WHERE  snap_id = :snap_id AND label IS NULL;
```
