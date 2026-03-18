# 01. 시스템 아키텍처

## 전체 구조

```
Binance WebSocket (trade, depth, kline)
        │
        ▼
┌─ L0 : 게이트웨이 ──────────────────────────────┐
│   스트림 정규화  →  링 버퍼 (인메모리 deque)      │
└────────────────────┬───────────────────────────┘
                     │
                     ▼
┌─ L1 : 피처 엔진 ──────────────────────────────┐
│   미시구조 7개 │ 시간윈도우 18개 │ 파생 10개     │──→ Oracle TB_SNAPSHOT
│   → 35차원 숫자 벡터 (num_vector) 생성          │     (비동기 INSERT)
└────────────────────┬───────────────────────────┘
                     │ feature vector
                     ▼
┌─ L2 : 전략 엔진 ──────────────────────────────┐
│   ① 전방: HNSW 패턴 검색 (TB_PATTERN)          │←→ Oracle HNSW
│   ② 후방: 전조 벡터 검색 (TB_INFLECTION)        │     (동기 READ)
│   → 매수/매도/회피 신호 판단                     │
└────────────────────┬───────────────────────────┘
                     │ entry/exit signal
                     ▼
┌─ L3 : 리스크 + 주문 ──────────────────────────┐
│   리스크 게이트 → 주문 생성 → 체결 감시          │
│   → 포지션 모니터링 → 청산 → 결과 기록           │──→ Oracle TB_SIM_TRADE
└────────────────────┬───────────────────────────┘
                     │
                     ▼
              Binance Testnet REST API


    [사이드]                              [사이드]
┌─ Oracle 26ai ─┐                  ┌─ RTX 3090 ────┐
│ TB_SNAPSHOT    │                  │ BGE-M3 (~2GB) │
│ TB_PATTERN     │                  │  뉴스 임베딩    │
│ TB_SIM_TRADE   │                  │               │
│ TB_INFLECTION  │                  │ Qwen3.5(~16GB)│
│ TB_NEWS_SIGNAL │                  │  신호 검증      │
│ TB_MACRO_REGIME│                  │  패턴 라벨링    │
│ TB_SEC_FILING  │                  │  공시 분석      │
│ TB_LLM_LOG     │                  └───────────────┘
│ TB_SYSTEM_CONFIG│
└────────────────┘

    [배치]
┌─ 오프라인 학습기 ─┐
│ 사후 라벨링       │
│ 패턴 승격         │
│ 변곡점 감지/역추적 │
│ Qwen 패턴 분석    │
└──────────────────┘
```

## 레이어별 역할 요약

| 레이어 | 역할 | 입력 | 출력 | 지연 예산 |
|--------|------|------|------|----------|
| L0 | 데이터 수신 + 정규화 | Binance WS 이벤트 | 정규화된 Ring Buffer | < 1ms |
| L1 | 피처 산출 + 벡터 생성 | Ring Buffer | 35D num_vector | < 5ms |
| L2 | 패턴 매칭 + 신호 판단 | num_vector | entry/exit signal | < 10ms (HNSW ~0.1ms) |
| L3 | 리스크 관리 + 주문 실행 | signal | Binance REST 주문 | < 50ms (내부), ~200ms (API) |

**실시간 경로 전체: L0→L1→L2→L3 < 50ms (Binance API 응답 제외)**

## 데이터 흐름 타임라인

```
t=0       [L0] WebSocket 이벤트 수신
t+3s      [L1] 스냅샷 생성 → TB_SNAPSHOT INSERT (label=NULL)
t+3s      [L2] HNSW 패턴 검색 (~0.1ms) + 전조 검색
t+3s      [L2] 매칭 시 → L3 signal 전송
t+3s      [L3] 리스크 게이트 → Testnet 주문 → TB_SIM_TRADE INSERT
t+3s      [GPU] Qwen 비동기 signal validation (non-blocking)

t+1min    [Labeler] TB_SNAPSHOT.ret_fwd_1m UPDATE
t+5min    [Labeler] TB_SNAPSHOT.ret_fwd_5m, mfe_5m, mae_5m UPDATE
t+15min   [Labeler] 전체 라벨 확정 + outcome_vector + label UPDATE
t+15min   [Detector] 변곡점 감지 → TB_INFLECTION INSERT (전조 벡터 조립)

매시간     [Trainer] 라벨 통계 → 패턴 승격 후보 추출
일 1회     [Trainer] TB_PATTERN 갱신 + Qwen 패턴 설명 생성
일 1회     [FRED] TB_MACRO_REGIME 갱신
30초 간격  [Tiingo] TB_NEWS_SIGNAL INSERT
시간 1회   [EDGAR] TB_SEC_FILING INSERT
```

## Testnet ↔ 실전 전환

환경변수 `TESTNET_MODE` 하나로 전환. L0~L3 코드 변경 없음.

| 항목 | Testnet | 실전 |
|------|---------|------|
| REST | `https://testnet.binance.vision/api/v3` | `https://api.binance.com/api/v3` |
| WS 시장 | `wss://testnet.binance.vision/ws` | `wss://stream.binance.com:9443/ws` |
| WS 사용자 | `wss://testnet.binance.vision/ws/{listenKey}` | `wss://stream.binance.com:9443/ws/{listenKey}` |
| 잔고 | 가상 자산 (자동 지급) | 실제 잔고 |
| 리셋 | 월 1회 전체 초기화 | 없음 |
