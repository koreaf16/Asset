-- ============================================================
-- COIN 단타 시스템 — Oracle 26ai 스키마 v1.1 (수수료 반영)
-- Binance Spot / 모의거래 / 숫자 벡터 기반
-- ============================================================

-- ============================================================
-- 1. TB_SNAPSHOT — 시장 스냅샷 (시스템의 심장)
-- 매 N초마다 무조건 수집. 패턴 매칭 여부 무관.
-- 라벨은 M분 후 지연 UPDATE로 채움.
-- ============================================================
CREATE TABLE TB_SNAPSHOT (
    snap_id         NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts              TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    symbol          VARCHAR2(20)    NOT NULL,       -- 'BTCUSDT', 'ETHUSDT' 등

    -- ── 미시구조 피처 (즉시성) ──
    price           NUMBER(20,8)    NOT NULL,       -- 현재가
    bid_ask_spread  NUMBER(12,8),                   -- bid-ask spread (%)
    ob_imbalance    NUMBER(8,6),                    -- 호가 불균형 (-1 ~ +1)
    vwap_dev        NUMBER(12,8),                   -- VWAP 이탈률 (%)
    buy_sell_ratio  NUMBER(8,6),                    -- 체결 강도 (buy vol / total vol)
    trades_per_sec  NUMBER(10,2),                   -- 초당 체결 건수
    depth_pressure  NUMBER(12,8),                   -- 호가벽 압력 (bid 5호가합 / ask 5호가합)

    -- ── 시간 윈도우 요약 ──
    ret_1m          NUMBER(12,8),                   -- 직전 1분 수익률 (%)
    ret_5m          NUMBER(12,8),                   -- 직전 5분 수익률 (%)
    ret_15m         NUMBER(12,8),                   -- 직전 15분 수익률 (%)
    vol_1m          NUMBER(12,8),                   -- 직전 1분 변동성 (std)
    vol_5m          NUMBER(12,8),                   -- 직전 5분 변동성
    vol_15m         NUMBER(12,8),                   -- 직전 15분 변동성
    volume_chg_1m   NUMBER(12,8),                   -- 직전 1분 거래량 변화율
    volume_chg_5m   NUMBER(12,8),                   -- 직전 5분 거래량 변화율

    -- ── 거시 컨텍스트 (저빈도, 일 1회~시간 1회 갱신) ──
    regime          VARCHAR2(10)    DEFAULT 'NEUTRAL',  -- RISK_ON / NEUTRAL / RISK_OFF
    news_sentiment  NUMBER(6,4)     DEFAULT 0,          -- 최근 뉴스 감성 평균 (-1 ~ +1)
    btc_dominance   NUMBER(8,4),                        -- BTC 도미넌스 변화율

    -- ── 이벤트 플래그 (이 스냅샷이 "특이한" 순간인지) ──
    event_flags     NUMBER(4)       DEFAULT 0,
    /*
        비트마스크:
        1  = 거래량 급증 (>2x 5분 평균)
        2  = 호가 급변 (imbalance 0.3→0.7)
        4  = spread 확대 (>3x 평균)
        8  = 볼린저 밴드 돌파
        16 = 뉴스 이벤트 감지
    */

    -- ── 수수료 (스냅샷 시점 적용 요율) ──
    fee_entry_rate  NUMBER(8,6),                    -- 진입 수수료율 (%)
    fee_exit_rate   NUMBER(8,6),                    -- 청산 수수료율 (%)
    fee_roundtrip   NUMBER(8,6),                    -- 왕복 수수료 합계 (%)

    -- ── 숫자 벡터 (주력, ~35차원) ──
    num_vector      VECTOR(35, FLOAT32)  NOT NULL,
    /*
        차원 구성:
        [0-6]   미시구조: spread, imbalance, vwap_dev, buy_sell_ratio,
                         trades_per_sec, depth_pressure, price_z_score
        [7-12]  1분 윈도우: ret, vol, volume_chg, high_low_range, close_position, tick_count
        [13-18] 5분 윈도우: (동일 6개)
        [19-24] 15분 윈도우: (동일 6개)
        [25-29] 거시: regime_enc, news_sentiment, btc_dom_chg, dgs_spread, stlfsi
        [30-34] 파생: momentum_1m, momentum_5m, rsi_14, vol_ratio_1m5m, spread_z_score
    */

    -- ── BGE-M3 보조 벡터 (컨텍스트 검색용, 선택적) ──
    ctx_vector      VECTOR(1024, FLOAT32),

    -- ── 사후 라벨링 (M분 후 UPDATE) ──
    ret_fwd_1m      NUMBER(12,8),                   -- 1분 후 수익률
    ret_fwd_5m      NUMBER(12,8),                   -- 5분 후 수익률
    ret_fwd_15m     NUMBER(12,8),                   -- 15분 후 수익률
    mfe_5m          NUMBER(12,8),                   -- 5분간 MFE (%)
    mae_5m          NUMBER(12,8),                   -- 5분간 MAE (%)
    mfe_15m         NUMBER(12,8),                   -- 15분간 MFE (%)
    mae_15m         NUMBER(12,8),                   -- 15분간 MAE (%)
    fwd_volatility  NUMBER(12,8),                   -- 이후 5분 변동성

    -- ── 수수료 차감 후 순지표 (사후 UPDATE) ──
    ret_fwd_5m_net  NUMBER(12,8),                   -- 수수료 차감 후 5분 순수익률
    ret_fwd_15m_net NUMBER(12,8),                   -- 수수료 차감 후 15분 순수익률
    mfe_5m_net      NUMBER(12,8),                   -- 수수료 차감 후 MFE
    mfe_mae_ratio_net NUMBER(8,4),                  -- 수수료 차감 후 MFE/MAE

    -- ── 결과 벡터 (사후 UPDATE) ──
    outcome_vector  VECTOR(15, FLOAT32),
    /*
        차원 구성:
        [0-2]   수익률: ret_fwd_1m, ret_fwd_5m, ret_fwd_15m
        [3-6]   MFE/MAE: mfe_5m, mae_5m, mfe_15m, mae_15m
        [7-9]   리스크: fwd_volatility, mfe_mae_ratio_5m, mfe_mae_ratio_15m
        [10-12] 가격 행동: 종가 위치(고저 대비), 되돌림 비율, 추세 지속도
        [13-14] 파생: sharpe_ratio_5m, 최대 연속 방향
    */

    label           VARCHAR2(10),                   -- BUY_GOOD / SELL_GOOD / HOLD
    labeled_at      TIMESTAMP(6) WITH TIME ZONE,    -- 라벨링 시각

    CONSTRAINT chk_label CHECK (label IN ('BUY_GOOD','SELL_GOOD','HOLD'))
) PARTITION BY RANGE (ts)
  INTERVAL (NUMTODSINTERVAL(1, 'DAY'))
  (PARTITION p_init VALUES LESS THAN (TIMESTAMP '2026-04-01 00:00:00 +09:00'));

-- 숫자 벡터 HNSW 인덱스 (주력 검색)
CREATE VECTOR INDEX idx_snap_num ON TB_SNAPSHOT(num_vector)
    ORGANIZATION INMEMORY NEIGHBOR GRAPH
    DISTANCE COSINE
    WITH TARGET ACCURACY 95;

-- 시간 + 심볼 복합 인덱스
CREATE INDEX idx_snap_ts_sym ON TB_SNAPSHOT(symbol, ts DESC);

-- 이벤트 플래그 인덱스 (이벤트 근처 스냅샷 빠른 조회)
CREATE INDEX idx_snap_event ON TB_SNAPSHOT(event_flags, ts DESC);

-- 라벨 인덱스 (학습 데이터 추출)
CREATE INDEX idx_snap_label ON TB_SNAPSHOT(label, symbol);


-- ============================================================
-- 2. TB_PATTERN — 승격된 패턴 (L2 실시간 검색 대상)
-- TB_SNAPSHOT에서 통계 검증을 통과한 것만 올라옴.
-- ============================================================
CREATE TABLE TB_PATTERN (
    pattern_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at      TIMESTAMP(6) WITH TIME ZONE DEFAULT SYSTIMESTAMP,
    updated_at      TIMESTAMP(6) WITH TIME ZONE DEFAULT SYSTIMESTAMP,
    symbol          VARCHAR2(20)    NOT NULL,
    label           VARCHAR2(10)    NOT NULL,       -- BUY_GOOD / SELL_GOOD

    -- ── 대표 벡터 (해당 패턴 스냅샷들의 centroid) ──
    num_vector      VECTOR(35, FLOAT32)  NOT NULL,

    -- ── 통계 지표 ──
    sample_count    NUMBER          NOT NULL,       -- 출현 횟수
    win_rate        NUMBER(6,4)     NOT NULL,       -- 승률 (0~1)
    avg_ret_5m      NUMBER(12,8),                   -- 평균 5분 수익률
    avg_mfe_5m      NUMBER(12,8),                   -- 평균 MFE
    avg_mae_5m      NUMBER(12,8),                   -- 평균 MAE
    mfe_mae_ratio   NUMBER(8,4),                    -- MFE/MAE 비율
    sharpe_5m       NUMBER(8,4),                    -- 5분 샤프 비율
    avg_hold_time   NUMBER(10,2),                   -- 평균 보유 시간 (초)

    -- ── 유효 조건 ──
    regime          VARCHAR2(10),                   -- 이 패턴이 유효한 regime (NULL=전체)
    min_volume_chg  NUMBER(12,8),                   -- 최소 거래량 변화율 조건
    max_spread      NUMBER(12,8),                   -- 최대 spread 조건

    -- ── 메타 ──
    description     VARCHAR2(1000),                 -- Qwen이 생성한 패턴 설명
    is_active       NUMBER(1)       DEFAULT 1,      -- 활성 여부
    last_hit_at     TIMESTAMP(6) WITH TIME ZONE,    -- 마지막 매칭 시각
    hit_count       NUMBER          DEFAULT 0,      -- 실시간 매칭 누적 횟수

    -- ── 모의거래 실전 검증 ──
    sim_trade_count NUMBER          DEFAULT 0,      -- 모의거래 횟수
    sim_win_rate    NUMBER(6,4),                    -- 모의거래 승률
    sim_avg_slip    NUMBER(12,8),                   -- 모의거래 평균 슬리피지

    CONSTRAINT chk_pat_label CHECK (label IN ('BUY_GOOD','SELL_GOOD')),
    CONSTRAINT chk_pat_active CHECK (is_active IN (0,1)),
    CONSTRAINT chk_pat_promote CHECK (
        sample_count >= 30
        AND win_rate >= 0.6
        AND mfe_mae_ratio >= 2.0
    )
);

-- 패턴 HNSW 인덱스 (L2 실시간 검색)
CREATE VECTOR INDEX idx_pat_num ON TB_PATTERN(num_vector)
    ORGANIZATION INMEMORY NEIGHBOR GRAPH
    DISTANCE COSINE
    WITH TARGET ACCURACY 95;

-- 활성 패턴만 빠르게 조회
CREATE INDEX idx_pat_active ON TB_PATTERN(is_active, symbol, regime);


-- ============================================================
-- 3. TB_SIM_TRADE — 모의거래 기록 (Binance Testnet)
-- 모의거래 결과와 이론적 기대값의 차이를 기록.
-- ============================================================
CREATE TABLE TB_SIM_TRADE (
    trade_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at      TIMESTAMP(6) WITH TIME ZONE DEFAULT SYSTIMESTAMP,
    symbol          VARCHAR2(20)    NOT NULL,

    -- ── 진입 ──
    entry_snap_id   NUMBER          NOT NULL REFERENCES TB_SNAPSHOT(snap_id),
    entry_pattern_id NUMBER         REFERENCES TB_PATTERN(pattern_id),
    entry_similarity NUMBER(8,6),                   -- 패턴 매칭 유사도
    signal_price    NUMBER(20,8)    NOT NULL,       -- 신호 발생 시점 가격
    entry_price     NUMBER(20,8)    NOT NULL,       -- 실제 체결가
    entry_slippage  NUMBER(12,8),                   -- 체결 슬리피지 (%)
    entry_latency   NUMBER(10,2),                   -- 주문~체결 지연 (ms)
    side            VARCHAR2(4)     NOT NULL,       -- BUY / SELL

    -- ── 청산 ──
    exit_snap_id    NUMBER          REFERENCES TB_SNAPSHOT(snap_id),
    exit_price      NUMBER(20,8),                   -- 청산가
    exit_reason     VARCHAR2(20),                   -- TAKE_PROFIT / STOP_LOSS / TIMEOUT / MANUAL
    exit_slippage   NUMBER(12,8),                   -- 청산 슬리피지
    exit_latency    NUMBER(10,2),                   -- 청산 지연

    -- ── 결과 ──
    pnl_pct         NUMBER(12,8),                   -- 실현 손익 (%)
    pnl_amount      NUMBER(20,8),                   -- 실현 손익 (USDT)
    hold_time_sec   NUMBER(10,2),                   -- 보유 시간 (초)
    is_win          NUMBER(1),                      -- 1=승, 0=패

    -- ── 이론 vs 실전 비교 ──
    theo_mfe_5m     NUMBER(12,8),                   -- 이론적 MFE (TB_SNAPSHOT에서)
    real_mfe        NUMBER(12,8),                   -- 실제 경험 MFE
    theo_mae_5m     NUMBER(12,8),                   -- 이론적 MAE
    real_mae        NUMBER(12,8),                   -- 실제 경험 MAE
    execution_gap   NUMBER(12,8),                   -- 이론-실전 PnL 차이

    -- ── 수수료 상세 ──
    fee_entry_rate  NUMBER(8,6),                    -- 적용된 진입 수수료율
    fee_exit_rate   NUMBER(8,6),                    -- 적용된 청산 수수료율
    fee_entry       NUMBER(12,8),                   -- 진입 수수료 (USDT)
    fee_exit        NUMBER(12,8),                   -- 청산 수수료 (USDT)
    fee_total       NUMBER(12,8),                   -- 총 수수료 (USDT)
    pnl_gross       NUMBER(20,8),                   -- 수수료 전 총손익
    pnl_net         NUMBER(20,8),                   -- 수수료 후 순손익
    fee_impact_pct  NUMBER(8,4),                    -- 수수료가 총수익에서 차지하는 비율

    -- ── 거래 벡터 (상황+결과 통합) ──
    trade_vector    VECTOR(25, FLOAT32),
    /*
        차원 구성:
        [0-4]   진입 상황: 유사도, 신호강도, spread, imbalance, volume_chg
        [5-9]   체결 품질: entry_slip, exit_slip, entry_latency, exit_latency, fill_ratio
        [10-14] 실전 결과: pnl_pct, hold_time, real_mfe, real_mae, mfe_mae_ratio
        [15-19] 이론-실전 갭: mfe_gap, mae_gap, pnl_gap, latency_impact, slip_impact
        [20-24] 시장 상태: regime_enc, news_sentiment, vol_at_entry, vol_at_exit, trend_strength
    */

    CONSTRAINT chk_side CHECK (side IN ('BUY','SELL')),
    CONSTRAINT chk_exit CHECK (exit_reason IN ('TAKE_PROFIT','STOP_LOSS','TIMEOUT','MANUAL'))
);

-- 거래 벡터 HNSW 인덱스 ("이 거래와 비슷한 과거 거래" 검색)
CREATE VECTOR INDEX idx_trade_vec ON TB_SIM_TRADE(trade_vector)
    ORGANIZATION INMEMORY NEIGHBOR GRAPH
    DISTANCE COSINE
    WITH TARGET ACCURACY 95;

-- 패턴별 거래 조회
CREATE INDEX idx_trade_pattern ON TB_SIM_TRADE(entry_pattern_id, created_at DESC);

-- 심볼+시간 조회
CREATE INDEX idx_trade_sym_ts ON TB_SIM_TRADE(symbol, created_at DESC);


-- ============================================================
-- 4. TB_NEWS_SIGNAL — Tiingo 뉴스 신호
-- ============================================================
CREATE TABLE TB_NEWS_SIGNAL (
    news_id         NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fetched_at      TIMESTAMP(6) WITH TIME ZONE DEFAULT SYSTIMESTAMP,
    published_at    TIMESTAMP(6) WITH TIME ZONE,
    source          VARCHAR2(100),                  -- 출처
    title           VARCHAR2(500)   NOT NULL,
    tickers         VARCHAR2(200),                  -- 관련 티커 (콤마 구분)

    -- ── Qwen 분석 결과 ──
    sentiment       NUMBER(6,4),                    -- -1 ~ +1
    impact_score    NUMBER(6,4),                    -- 0 ~ 1 (가격 영향 예상 크기)
    topic           VARCHAR2(50),                   -- REGULATION, ADOPTION, HACK, MACRO 등
    summary         VARCHAR2(1000),                 -- Qwen 요약

    -- ── BGE-M3 임베딩 (뉴스 유사도 검색용) ──
    news_vector     VECTOR(1024, FLOAT32),

    -- ── 사후 검증 ──
    actual_impact   NUMBER(12,8),                   -- 발행 후 5분 실제 가격 변화 (%)
    impact_verified NUMBER(1)       DEFAULT 0       -- 검증 완료 여부
);

CREATE VECTOR INDEX idx_news_vec ON TB_NEWS_SIGNAL(news_vector)
    ORGANIZATION INMEMORY NEIGHBOR GRAPH
    DISTANCE COSINE
    WITH TARGET ACCURACY 90;

CREATE INDEX idx_news_ts ON TB_NEWS_SIGNAL(published_at DESC);
CREATE INDEX idx_news_ticker ON TB_NEWS_SIGNAL(tickers);


-- ============================================================
-- 5. TB_MACRO_REGIME — FRED 거시 데이터
-- ============================================================
CREATE TABLE TB_MACRO_REGIME (
    regime_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts              TIMESTAMP(6) WITH TIME ZONE NOT NULL,

    -- ── FRED 시리즈 원본 ──
    fedfunds        NUMBER(8,4),                    -- 연방기금금리
    cpiaucsl        NUMBER(12,4),                   -- CPI
    unrate          NUMBER(6,4),                    -- 실업률
    m2sl            NUMBER(16,4),                   -- M2 통화량
    walcl           NUMBER(16,4),                   -- 연준 대차대조표
    dgs10           NUMBER(8,4),                    -- 10년물 금리
    dgs2            NUMBER(8,4),                    -- 2년물 금리
    stlfsi4         NUMBER(8,4),                    -- 금융 스트레스 지수

    -- ── 파생 지표 ──
    dgs_spread      NUMBER(8,4),                    -- DGS10 - DGS2 (장단기 스프레드)
    walcl_chg_pct   NUMBER(8,4),                    -- WALCL 주간 변화율

    -- ── 산출 레짐 ──
    regime          VARCHAR2(10)    NOT NULL,        -- RISK_ON / NEUTRAL / RISK_OFF
    regime_score    NUMBER(6,4),                    -- 연속값 (-1=극단적 risk-off ~ +1=극단적 risk-on)
    regime_reason   VARCHAR2(200),                  -- 판단 근거

    CONSTRAINT chk_regime CHECK (regime IN ('RISK_ON','NEUTRAL','RISK_OFF'))
);

CREATE INDEX idx_regime_ts ON TB_MACRO_REGIME(ts DESC);


-- ============================================================
-- 6. TB_SEC_FILING — SEC EDGAR 공시
-- ============================================================
CREATE TABLE TB_SEC_FILING (
    filing_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fetched_at      TIMESTAMP(6) WITH TIME ZONE DEFAULT SYSTIMESTAMP,
    filed_at        TIMESTAMP(6) WITH TIME ZONE,
    form_type       VARCHAR2(10)    NOT NULL,       -- 8-K, 4, 10-K, 10-Q
    company_name    VARCHAR2(200),
    cik             VARCHAR2(20),
    accession_no    VARCHAR2(30),

    -- ── Qwen 분석 결과 ──
    crypto_relevant NUMBER(1)       DEFAULT 0,      -- 크립토 관련 여부
    impact_score    NUMBER(6,4),                    -- 0 ~ 1
    summary         VARCHAR2(1000),
    affected_coins  VARCHAR2(200),                  -- 영향 받을 코인 (콤마 구분)

    -- ── BGE-M3 임베딩 ──
    filing_vector   VECTOR(1024, FLOAT32)
);

CREATE INDEX idx_filing_ts ON TB_SEC_FILING(filed_at DESC);
CREATE INDEX idx_filing_crypto ON TB_SEC_FILING(crypto_relevant, filed_at DESC);


-- ============================================================
-- 7. TB_LLM_LOG — Qwen 분석 로그
-- ============================================================
CREATE TABLE TB_LLM_LOG (
    log_id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts              TIMESTAMP(6) WITH TIME ZONE DEFAULT SYSTIMESTAMP,
    task_type       VARCHAR2(30)    NOT NULL,
    /*
        SIGNAL_VALIDATE  = L2 신호 사후 검증
        PATTERN_LABEL    = 패턴 라벨링/설명 생성
        NEWS_ANALYZE     = 뉴스 분석
        SEC_ANALYZE      = SEC 공시 분석
        REGIME_REVIEW    = 시장 레짐 종합 리뷰
    */

    -- ── 입력/출력 ──
    ref_id          NUMBER,                         -- 참조 ID (snap_id, news_id 등)
    ref_table       VARCHAR2(30),                   -- 참조 테이블명
    prompt_summary  VARCHAR2(500),                  -- 프롬프트 요약
    response        CLOB,                           -- Qwen 전체 응답
    confidence      NUMBER(6,4),                    -- Qwen 자체 확신도 (0~1)

    -- ── 성능 ──
    inference_ms    NUMBER(10,2),                   -- 추론 소요 시간
    tokens_used     NUMBER(10),                     -- 사용 토큰 수

    -- ── 사후 검증 ──
    was_correct     NUMBER(1),                      -- 판단이 맞았는지 (사후 UPDATE)
    verified_at     TIMESTAMP(6) WITH TIME ZONE
);

CREATE INDEX idx_llm_task ON TB_LLM_LOG(task_type, ts DESC);
CREATE INDEX idx_llm_ref ON TB_LLM_LOG(ref_table, ref_id);


-- ============================================================
-- 8. TB_SYSTEM_CONFIG — 시스템 설정 (런타임 조정)
-- ============================================================
CREATE TABLE TB_SYSTEM_CONFIG (
    config_key      VARCHAR2(50)    PRIMARY KEY,
    config_value    VARCHAR2(500)   NOT NULL,
    description     VARCHAR2(200),
    updated_at      TIMESTAMP(6) WITH TIME ZONE DEFAULT SYSTIMESTAMP
);

-- 기본 설정값
INSERT INTO TB_SYSTEM_CONFIG VALUES ('SNAPSHOT_INTERVAL_SEC',  '3',      '스냅샷 수집 주기 (초)',        SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('LABEL_DELAY_MIN',       '15',     '라벨링 대기 시간 (분)',        SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('PATTERN_MIN_SAMPLES',   '30',     '패턴 승격 최소 출현 횟수',      SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('PATTERN_MIN_WINRATE',   '0.6',    '패턴 승격 최소 승률',          SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('PATTERN_MIN_MFE_MAE',   '2.0',    '패턴 승격 최소 MFE/MAE 비율',  SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('RISK_MAX_POSITION_PCT', '5.0',    '최대 포지션 비율 (%)',         SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('RISK_STOP_LOSS_PCT',    '1.0',    '손절 비율 (%)',               SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('RISK_MAX_DAILY_LOSS',   '3.0',    '일일 최대 손실 (%)',           SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('RISK_MAX_OPEN_TRADES',  '3',      '최대 동시 진입 수',            SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('L2_TOP_K',              '20',     'HNSW 1차 후보 수',            SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('L2_FINAL_K',            '5',      '최종 매칭 패턴 수',            SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('L2_MIN_SIMILARITY',     '0.85',   '최소 유사도 임계치',           SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('TRADING_SYMBOLS',       'BTCUSDT,ETHUSDT,SOLUSDT', '거래 대상 심볼', SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('TESTNET_MODE',          '1',      '모의거래 모드 (1=ON, 0=OFF)', SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('FEE_MAKER_RATE',        '0.075',  'Maker 수수료 (%, BNB 할인 적용 후)', SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('FEE_TAKER_RATE',        '0.075',  'Taker 수수료 (%, BNB 할인 적용 후)', SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('FEE_ENTRY_TYPE',        'MAKER',  '진입 주문 방식 (MAKER/TAKER)',  SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('FEE_EXIT_TYPE',         'TAKER',  '청산 주문 방식 (MAKER/TAKER)',  SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('FEE_BNB_DISCOUNT',      '0.25',   'BNB 할인율 (0.25 = 25%)',      SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('LABEL_MIN_RET_NET',     '0.8',    '라벨링 최소 순수익률 (%, 수수료 차감 후)', SYSTIMESTAMP);

INSERT INTO TB_SYSTEM_CONFIG VALUES ('RISK_TAKE_PROFIT_PCT',  '1.5',    '익절 비율 (%)',               SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('RISK_MAX_HOLD_SEC',    '300',    '최대 보유 시간 (초)',           SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('RISK_COOLDOWN_SEC',    '60',     '손절 후 대기 시간 (초)',        SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('ORDER_UNFILL_TIMEOUT', '10',     '미체결 취소 대기 (초)',         SYSTIMESTAMP);
INSERT INTO TB_SYSTEM_CONFIG VALUES ('ORDER_EXIT_LIMIT_TIMEOUT','3',   '익절 지정가 대기 (초)',         SYSTIMESTAMP);

COMMIT;


-- ============================================================
-- 9. TB_INFLECTION — 변곡점 (후방 추적용)
-- 급등/급락 등 유의미한 가격 변동을 감지하고,
-- 직전 시장 상태의 궤적을 전조 벡터로 저장.
-- ============================================================
CREATE TABLE TB_INFLECTION (
    inflection_id    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts               TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    symbol           VARCHAR2(20)    NOT NULL,

    -- ── 변곡점 유형 ──
    inflection_type  VARCHAR2(20)    NOT NULL,
    /*
        CRASH          = 5분 내 -0.8% 이상 급락
        SURGE          = 5분 내 +0.8% 이상 급등
        VOL_EXPLOSION  = 5분 변동성 3배 이상 폭발
        REVERSAL_UP    = 하락→상승 추세 반전
        REVERSAL_DOWN  = 상승→하락 추세 반전
    */
    magnitude        NUMBER(12,8)    NOT NULL,      -- 변곡점 크기 (%)
    duration_sec     NUMBER(10,2),                  -- 변곡 소요 시간 (초)

    -- ── 전조 벡터 (핵심: 변곡점 직전의 변화 궤적) ──
    precursor_vector VECTOR(50, FLOAT32) NOT NULL,
    /*
        차원 구성:
        [0-9]   T-30초 시점 상태 차분 (현재 대비)
                Δspread, Δimbalance, Δvwap_dev, Δbuy_sell_ratio,
                Δtrades_per_sec, Δvolume, Δprice_momentum,
                Δdepth_pressure, Δret_1m, Δvol_1m
        [10-19] T-1분 시점 상태 차분 (동일 10개)
        [20-29] T-3분 시점 상태 차분 (동일 10개)
        [30-39] T-5분 시점 상태 차분 (동일 10개)
        [40-49] 궤적 파생: spread_accel, imbalance_velocity,
                volume_jerk, price_curvature, event_sequence_enc,
                tps_accel, depth_drain_rate, momentum_divergence,
                microstructure_stress, regime_stability
    */

    -- ── 연결 ──
    anchor_snap_id   NUMBER          REFERENCES TB_SNAPSHOT(snap_id),

    -- ── 선행 이벤트 조합 ──
    precursor_events NUMBER(4),                     -- 직전 5분 이벤트 플래그 OR 합산
    precursor_count  NUMBER(4),                     -- 직전 5분 이벤트 발생 횟수

    -- ── 패턴 통계 (동일 유형 누적) ──
    occurrence_count NUMBER          DEFAULT 1,
    avg_magnitude    NUMBER(12,8),
    avg_lead_time    NUMBER(10,2),                  -- 전조 시작~변곡점 평균 시간 (초)

    CONSTRAINT chk_inflection CHECK (
        inflection_type IN ('CRASH','SURGE','VOL_EXPLOSION','REVERSAL_UP','REVERSAL_DOWN')
    )
);

-- 전조 벡터 HNSW 인덱스 (L2 위험 감지용)
CREATE VECTOR INDEX idx_inflect_precursor ON TB_INFLECTION(precursor_vector)
    ORGANIZATION INMEMORY NEIGHBOR GRAPH
    DISTANCE COSINE
    WITH TARGET ACCURACY 95;

CREATE INDEX idx_inflect_ts ON TB_INFLECTION(symbol, ts DESC);
CREATE INDEX idx_inflect_type ON TB_INFLECTION(inflection_type, symbol);


-- ============================================================
-- 핵심 쿼리 예시
-- ============================================================

-- [L2] 실시간 패턴 매칭 (2단계 검색)
-- 1차: 숫자 벡터 HNSW → Top 20
-- 2차: 관계형 필터로 최종 Top 5
/*
SELECT p.pattern_id, p.label, p.win_rate, p.mfe_mae_ratio,
       p.sim_win_rate, p.description,
       VECTOR_DISTANCE(p.num_vector, :current_vec, COSINE) AS dist
FROM   TB_PATTERN p
WHERE  p.is_active = 1
  AND  p.symbol = :symbol
  AND  (p.regime IS NULL OR p.regime = :current_regime)
  AND  VECTOR_DISTANCE(p.num_vector, :current_vec, COSINE) < (1 - :min_similarity)
ORDER  BY VECTOR_DISTANCE(p.num_vector, :current_vec, COSINE)
FETCH  FIRST :top_k ROWS ONLY;
*/

-- [Labeler] 사후 라벨링 (N분 지연, 수수료 반영)
/*
UPDATE TB_SNAPSHOT s
SET    ret_fwd_1m  = (미래가격 - s.price) / s.price * 100,
       ret_fwd_5m  = ...,
       mfe_5m      = ...,
       mae_5m      = ...,
       ret_fwd_5m_net  = ret_fwd_5m - s.fee_roundtrip,
       ret_fwd_15m_net = ret_fwd_15m - s.fee_roundtrip,
       mfe_5m_net      = mfe_5m - s.fee_roundtrip,
       mfe_mae_ratio_net = (mfe_5m - s.fee_roundtrip) / GREATEST(mae_5m, 0.001),
       outcome_vector = VECTOR('[...]', 15, FLOAT32),
       label       = CASE
                       WHEN ret_fwd_5m_net > :label_min_ret_net
                        AND mfe_mae_ratio_net >= 2.0
                         THEN 'BUY_GOOD'
                       WHEN ret_fwd_5m_net < -:label_min_ret_net
                         THEN 'SELL_GOOD'
                       ELSE 'HOLD'
                     END,
       labeled_at  = SYSTIMESTAMP
WHERE  s.snap_id = :target_snap_id
  AND  s.label IS NULL;
*/

-- [Trainer] 패턴 승격 후보 조회
/*
SELECT symbol, label,
       COUNT(*) AS cnt,
       AVG(ret_fwd_5m) AS avg_ret,
       AVG(mfe_5m) AS avg_mfe,
       AVG(mae_5m) AS avg_mae,
       AVG(mfe_5m) / GREATEST(AVG(mae_5m), 0.001) AS mfe_mae_ratio,
       STDDEV(ret_fwd_5m) AS ret_std
FROM   TB_SNAPSHOT
WHERE  label IN ('BUY_GOOD','SELL_GOOD')
  AND  labeled_at > SYSTIMESTAMP - INTERVAL '7' DAY
GROUP  BY symbol, label
HAVING COUNT(*) >= 30
   AND AVG(mfe_5m) / GREATEST(AVG(mae_5m), 0.001) >= 2.0;
*/

-- [분석] 모의거래 이론-실전 갭 분석
/*
SELECT t.entry_pattern_id,
       p.description,
       COUNT(*) AS trades,
       AVG(t.pnl_pct) AS avg_pnl,
       AVG(t.execution_gap) AS avg_gap,
       AVG(t.entry_slippage) AS avg_slip,
       AVG(t.entry_latency) AS avg_latency,
       p.win_rate AS theo_wr,
       AVG(CASE WHEN t.is_win=1 THEN 1 ELSE 0 END) AS real_wr
FROM   TB_SIM_TRADE t
JOIN   TB_PATTERN p ON t.entry_pattern_id = p.pattern_id
GROUP  BY t.entry_pattern_id, p.description, p.win_rate
ORDER  BY avg_gap DESC;
*/

-- [L2] 후방 추적: 현재 시장 궤적이 과거 급락 전조와 유사한지 검색
/*
SELECT i.inflection_id, i.inflection_type, i.magnitude,
       i.avg_lead_time, i.occurrence_count,
       VECTOR_DISTANCE(i.precursor_vector, :current_trajectory, COSINE) AS dist
FROM   TB_INFLECTION i
WHERE  i.symbol = :symbol
  AND  i.inflection_type IN ('CRASH','REVERSAL_DOWN')
  AND  VECTOR_DISTANCE(i.precursor_vector, :current_trajectory, COSINE) < 0.15
ORDER  BY dist
FETCH  FIRST 3 ROWS ONLY;
-- 결과가 있으면 → L3 진입 차단 또는 기존 포지션 조기 청산
*/
