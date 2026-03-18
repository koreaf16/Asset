# 10. 수수료 체계 + 라벨링 로직 + 패턴 승격

## 수수료 구조

### Binance Spot 수수료율 (VIP 0 기준)
| 항목 | Maker | Taker |
|------|-------|-------|
| 기본 | 0.10% | 0.10% |
| BNB 할인 (25%) | 0.075% | 0.075% |

### 시스템 기본 설정 (BNB 할인 적용)
| 항목 | 주문 방식 | 수수료율 |
|------|----------|---------|
| 진입 | LIMIT (maker) | 0.075% |
| 청산 — 익절 | LIMIT 시도 → MARKET | 0.075% ~ 0.075% |
| 청산 — 손절 | MARKET (taker) | 0.075% |
| **왕복 합계** | | **0.150%** |

### 수수료가 시스템에 미치는 영향
- 총수익 0.3% → 수수료 후 0.15% (수수료가 수익의 50%)
- 총수익 0.5% → 수수료 후 0.35% (수수료가 수익의 30%)
- 총수익 0.8% → 수수료 후 0.65% (수수료가 수익의 19%)
- 총수익 1.0% → 수수료 후 0.85% (수수료가 수익의 15%)

**단타에서 0.5% 이하 수익 목표는 수수료에 심각하게 잠식됨.**

---

## 스냅샷 수집 규칙

### 수집 타이밍
매 N초(기본 3초) 무조건 수집. 패턴 매칭 여부 무관.

### 수집 시 저장 내용
- 35D num_vector (정규화된 피처)
- 원본 피처값 (관계형 컬럼)
- event_flags (이벤트 비트마스크)
- 현재 적용 수수료율 (fee_entry_rate, fee_exit_rate, fee_roundtrip)
- regime, news_sentiment (현재 거시 컨텍스트)
- **label = NULL** (사후 UPDATE)

---

## 사후 라벨링 로직

### 타이밍
스냅샷 생성 후 15분 경과 시 라벨링 배치 실행.

### 순서
```
1. ret_fwd_1m, ret_fwd_5m, ret_fwd_15m 계산 (해당 시간 후 가격)
2. mfe_5m, mae_5m 계산 (5분간 최대 유리/불리 움직임)
3. mfe_15m, mae_15m 계산
4. 수수료 차감 순지표 계산:
   - ret_fwd_5m_net = ret_fwd_5m - fee_roundtrip
   - mfe_5m_net = mfe_5m - fee_roundtrip
   - mfe_mae_ratio_net = mfe_5m_net / GREATEST(mae_5m, 0.001)
5. outcome_vector (15D) 생성
6. 라벨 부여
```

### 라벨 기준 (수수료 반영)

```
BUY_GOOD:
  (ret_fwd_5m - fee_roundtrip) > LABEL_MIN_RET_NET (기본 0.8%)
  AND (mfe_5m - fee_roundtrip) / GREATEST(mae_5m, 0.001) >= 2.0

SELL_GOOD:
  ret_fwd_5m_net < -LABEL_MIN_RET_NET (기본 0.8%)

HOLD:
  나머지 전부
```

### 데이터 불균형 예상
- HOLD: ~90-95%
- BUY_GOOD: ~3-5%
- SELL_GOOD: ~2-4%

**학습 시 대응**: 이벤트 플래그(event_flags > 0)가 있는 스냅샷에 가중치 부여, 이벤트 없는 순수 HOLD는 10:1 다운샘플링.

---

## 패턴 승격 기준

### 승격 조건 (모두 충족 시)
| 조건 | 임계치 | 설정 키 |
|------|--------|---------|
| 출현 횟수 | ≥ 30회 | PATTERN_MIN_SAMPLES |
| 승률 (수수료 후) | ≥ 60% | PATTERN_MIN_WINRATE |
| MFE/MAE 비율 (수수료 후) | ≥ 2.0 | PATTERN_MIN_MFE_MAE |

### 승격 프로세스
```
[매시간 Trainer 배치]
1. TB_SNAPSHOT에서 라벨별 클러스터링 (symbol × label × 7일)
2. 각 클러스터의 통계 집계 (승률, MFE, MAE, 샤프)
3. 승격 조건 충족 → TB_PATTERN INSERT/UPDATE
   - num_vector = 클러스터 centroid (평균 벡터)
   - 통계 지표 기록
4. Qwen이 패턴 설명 생성 → description 필드
5. 기존 패턴 성능 재평가 → 성능 하락 시 is_active = 0
```

### 패턴 비활성화 조건
- 최근 7일 승률 < 50% (기존 60%에서 하락)
- 최근 7일 MFE/MAE < 1.5
- 30일간 매칭 0회 (사장된 패턴)
- 모의거래 실전 승률이 이론 승률 대비 20%p 이상 하락

---

## 변곡점 감지 + 전조 벡터 생성

### 변곡점 감지 조건
| 유형 | 조건 |
|------|------|
| CRASH | 5분 ret < -0.8% |
| SURGE | 5분 ret > +0.8% |
| VOL_EXPLOSION | 5분 vol > 3× rolling avg |
| REVERSAL_UP | 하락 추세 → 상승 전환 확인 |
| REVERSAL_DOWN | 상승 추세 → 하락 전환 확인 |

### 감지 시 처리
1. 해당 시점의 anchor_snap_id 확인
2. T-30s, T-1m, T-3m, T-5m 스냅샷에서 차분 계산
3. 궤적 파생 지표 계산 (가속도, 곡률 등)
4. 50D precursor_vector 조립
5. TB_INFLECTION INSERT
