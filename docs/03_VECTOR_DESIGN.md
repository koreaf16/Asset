# 03. 벡터 설계 — 4종 벡터 상세 명세

## 설계 원칙

- **숫자 벡터가 주력** — 금융 시계열 수치는 그 자체로 완벽한 좌표. BGE-M3는 텍스트 전용.
- **정규화 필수** — 모든 피처는 rolling z-score (직전 1시간 기준) 적용 후 벡터화. 절대값이 아닌 상대적 위치로 비교해야 유사도 검색이 유효함.
- **2종 벡터 분리** — 상황(현재 상태)과 결과(미래 관측)를 분리해야 역방향 검색 가능.

---

## 벡터 1: 상황 벡터 (num_vector, 35차원)

**용도**: 매 스냅샷의 시장 상태를 표현. L2 패턴 매칭의 주력 검색 대상.

```
[0]  bid_ask_spread      호가 스프레드 (%)
[1]  ob_imbalance         호가 불균형 (-1 ~ +1, bid vs ask 5호가)
[2]  vwap_dev             VWAP 이탈률 (%)
[3]  buy_sell_ratio       체결 강도 (buy vol / total vol)
[4]  trades_per_sec       초당 체결 건수
[5]  depth_pressure       호가벽 압력 (bid 5호가합 / ask 5호가합)
[6]  price_z_score        현재가의 z-score (1시간 rolling)

[7]  ret_1m               직전 1분 수익률
[8]  vol_1m               직전 1분 변동성 (표준편차)
[9]  volume_chg_1m        직전 1분 거래량 변화율
[10] high_low_range_1m    직전 1분 고저 범위
[11] close_position_1m    직전 1분 캔들 내 종가 위치 (0~1)
[12] tick_count_1m        직전 1분 체결 건수

[13-18] 5분 윈도우         (위 6개와 동일 구조)
[19-24] 15분 윈도우        (위 6개와 동일 구조)

[25] regime_enc           시장 레짐 인코딩 (risk-off=-1, neutral=0, risk-on=1)
[26] news_sentiment       최근 뉴스 감성 평균 (-1 ~ +1)
[27] btc_dom_chg          BTC 도미넌스 변화율
[28] dgs_spread           DGS10-DGS2 장단기 금리차
[29] stlfsi               금융 스트레스 지수

[30] momentum_1m          1분 모멘텀 (ret_1m의 가속도)
[31] momentum_5m          5분 모멘텀
[32] rsi_14               RSI 14 (0~100 → 0~1 정규화)
[33] vol_ratio_1m5m       변동성 비율 (vol_1m / vol_5m)
[34] spread_z_score       spread의 z-score (1시간 rolling)
```

**저장**: TB_SNAPSHOT.num_vector `VECTOR(35, FLOAT32)`
**인덱스**: HNSW `DISTANCE COSINE WITH TARGET ACCURACY 95`

---

## 벡터 2: 결과 벡터 (outcome_vector, 15차원)

**용도**: 스냅샷 이후 실제로 벌어진 일을 표현. 사후 라벨링 시 UPDATE.

```
[0]  ret_fwd_1m           1분 후 수익률 (%)
[1]  ret_fwd_5m           5분 후 수익률 (%)
[2]  ret_fwd_15m          15분 후 수익률 (%)

[3]  mfe_5m               5분간 최대 유리 움직임 (%)
[4]  mae_5m               5분간 최대 불리 움직임 (%)
[5]  mfe_15m              15분간 MFE (%)
[6]  mae_15m              15분간 MAE (%)

[7]  fwd_volatility       이후 5분 변동성
[8]  mfe_mae_ratio_5m     mfe_5m / mae_5m
[9]  mfe_mae_ratio_15m    mfe_15m / mae_15m

[10] close_position_fwd   이후 5분 고저 대비 종가 위치
[11] retracement_ratio    되돌림 비율 (MFE 도달 후 얼마나 되돌렸는지)
[12] trend_persistence    추세 지속도 (동일 방향 연속 캔들 비율)

[13] sharpe_ratio_5m      5분 샤프 비율 (ret / vol)
[14] max_consecutive_dir  최대 연속 동일 방향 (양수=상승, 음수=하락)
```

**저장**: TB_SNAPSHOT.outcome_vector `VECTOR(15, FLOAT32)`
**시점**: 라벨링 시 (스냅샷 후 15분 경과 후 UPDATE)

---

## 벡터 3: 전조 벡터 (precursor_vector, 50차원)

**용도**: 변곡점(급등/급락) 직전의 시장 변화 궤적. 후방 추적 핵심.
**핵심 차이**: 정적 스냅샷이 아니라 "변화의 변화"를 담은 궤적 벡터.

```
[0-9]   T-30초 시점 상태 차분 (현재 시점 대비)
        Δspread, Δimbalance, Δvwap_dev, Δbuy_sell_ratio,
        Δtrades_per_sec, Δvolume, Δprice_momentum,
        Δdepth_pressure, Δret_1m, Δvol_1m

[10-19] T-1분 시점 상태 차분 (동일 10개)
[20-29] T-3분 시점 상태 차분 (동일 10개)
[30-39] T-5분 시점 상태 차분 (동일 10개)

[40] spread_acceleration    spread 변화 가속도
[41] imbalance_velocity     imbalance 기울기 변화 속도
[42] volume_jerk            거래량 가속도의 변화율 (3차 미분)
[43] price_curvature        가격 곡률 (2차 미분)
[44] event_sequence_enc     이벤트 발생 순서 인코딩 (비트패턴)
[45] tps_acceleration       체결 속도 가속도
[46] depth_drain_rate       호가 소진 속도 (호가벽이 얼마나 빨리 사라지는지)
[47] momentum_divergence    가격 vs 거래량 괴리 (가격은 오르는데 거래량은 감소 등)
[48] microstructure_stress  미시구조 스트레스 종합 지수
[49] regime_stability       레짐 안정성 (최근 레짐 변경 빈도)
```

**조립 방식**:
1. 변곡점 감지 (5분 ret > ±0.8% 또는 vol > 3x avg)
2. 해당 시점의 TB_SNAPSHOT에서 T-30s, T-1m, T-3m, T-5m 스냅샷 조회
3. 각 시점의 num_vector와 현재 num_vector의 차분 계산
4. 궤적 파생 지표 (가속도, 곡률 등) 계산
5. 50차원으로 조립 → TB_INFLECTION.precursor_vector INSERT

**저장**: TB_INFLECTION.precursor_vector `VECTOR(50, FLOAT32)`
**인덱스**: HNSW `DISTANCE COSINE WITH TARGET ACCURACY 95`

---

## 벡터 4: 거래 벡터 (trade_vector, 25차원)

**용도**: 모의거래 결과를 표현. "비슷한 거래"를 검색하여 패턴 실전 유효성 검증.

```
[0]  entry_similarity      패턴 매칭 유사도
[1]  signal_strength       신호 강도 (복수 패턴 매칭 시 합산)
[2]  spread_at_entry       진입 시점 spread
[3]  imbalance_at_entry    진입 시점 imbalance
[4]  volume_chg_at_entry   진입 시점 거래량 변화율

[5]  entry_slippage        진입 슬리피지 (%)
[6]  exit_slippage         청산 슬리피지 (%)
[7]  entry_latency         진입 주문~체결 지연 (ms, 정규화)
[8]  exit_latency          청산 주문~체결 지연 (ms, 정규화)
[9]  fill_ratio            체결 비율 (부분체결 시 < 1.0)

[10] pnl_pct               수수료 후 순손익 (%)
[11] hold_time             보유 시간 (초, 정규화)
[12] real_mfe              실제 MFE (%)
[13] real_mae              실제 MAE (%)
[14] mfe_mae_ratio         real_mfe / real_mae

[15] mfe_gap               이론 MFE - 실전 MFE
[16] mae_gap               이론 MAE - 실전 MAE
[17] pnl_gap               이론 PnL - 실전 PnL
[18] latency_impact        지연이 수익에 미친 영향
[19] slip_impact           슬리피지가 수익에서 차지하는 비율

[20] regime_enc            거래 시점 레짐
[21] news_sentiment        거래 시점 뉴스 감성
[22] vol_at_entry          진입 시점 변동성
[23] vol_at_exit           청산 시점 변동성
[24] trend_strength        거래 시점 추세 강도
```

**저장**: TB_SIM_TRADE.trade_vector `VECTOR(25, FLOAT32)`
**인덱스**: HNSW `DISTANCE COSINE WITH TARGET ACCURACY 95`

---

## 벡터 방식 선택 근거

| 방식 | 장점 | 단점 | 용도 |
|------|------|------|------|
| 숫자 벡터 (35D) | 수치 정밀도 높음, 해석 가능, ~0.1ms 검색 | 텍스트 의미 표현 불가 | **패턴 매칭 주력** |
| BGE-M3 (1024D) | 텍스트 의미 유사도 우수 | 숫자 정밀도 낮음, ~5ms 추론 | **뉴스/공시 보조** |

숫자를 텍스트로 변환 후 BGE-M3에 넣으면 "0.02%"와 "0.03%"의 수치적 차이를 모델이 이해하지 못함. 따라서 금융 시계열 패턴 매칭은 반드시 숫자 벡터로 수행.
