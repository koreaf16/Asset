# 12. 구현 로드맵 — 마일스톤 + 체크리스트

## 전체 일정 (권장)

```
Phase 1: 기반 구축          (1~2주)  ← DB + L0 + L1
Phase 2: 데이터 축적         (1~2주)  ← 수집만 돌리며 TB_SNAPSHOT 축적
Phase 3: 전략 엔진           (1~2주)  ← L2 + 라벨링 + 패턴 승격
Phase 4: 거래 실행           (1~2주)  ← L3 + Testnet 연동
Phase 5: GPU + 외부 데이터    (병렬)   ← Qwen, BGE-M3, Tiingo, FRED, EDGAR
Phase 6: UI + 모니터링       (1주)    ← 대시보드 + 벡터 탐색기
Phase 7: 검증 + 튜닝        (2~4주)  ← 모의거래 100회+ 달성, 파라미터 최적화
```

---

## Phase 1: 기반 구축

### M1.1 Oracle 26ai 환경 설정
- [ ] Oracle 26ai 인스턴스 설치/접속 확인
- [ ] COMPATIBLE 파라미터 23.4.0 이상 확인
- [ ] VECTOR_MEMORY_SIZE 설정 (최소 200M 권장)
- [ ] `schema_v1.2.sql` 실행 → 9개 테이블 생성
- [ ] HNSW 인덱스 5개 생성 확인
- [ ] TB_SYSTEM_CONFIG 기본값 INSERT 확인
- [ ] Python oracledb 드라이버 연결 테스트

### M1.2 L0 게이트웨이
- [ ] Binance Testnet WebSocket 연결 (`04_L0_GATEWAY.md` 참조)
- [ ] Combined stream 구독 (trade + depth20 + kline_1m)
- [ ] 이벤트 정규화 (trade, depth 포맷)
- [ ] Ring Buffer 구현 (심볼별 deque)
- [ ] 재연결 로직 (지수 백오프)
- [ ] 연결 상태 로깅

### M1.3 L1 피처 엔진
- [ ] 미시구조 피처 7개 계산 (`05_L1_FEATURE_ENGINE.md` 참조)
- [ ] 시간 윈도우 요약 18개 (1/5/15분 × 6)
- [ ] 파생 지표 10개
- [ ] Rolling z-score 정규화기
- [ ] 이벤트 감지 (5종 비트마스크)
- [ ] 35D 벡터 조립
- [ ] TB_SNAPSHOT 비동기 INSERT
- [ ] 스냅샷 트리거 루프 (N초 간격)

### M1.4 검증
- [ ] WebSocket → Ring Buffer → 피처 계산 파이프라인 E2E 테스트
- [ ] TB_SNAPSHOT에 데이터 정상 적재 확인
- [ ] num_vector 35차원 값 범위 검증 (z-score이므로 대부분 -3~+3)
- [ ] 초당 처리량 측정 (목표: > 500 이벤트/초)

---

## Phase 2: 데이터 축적

### M2.1 수집 전용 모드 운영
- [ ] L0 + L1만 가동 (L2, L3 비활성)
- [ ] 최소 3일 연속 운영하여 TB_SNAPSHOT 축적
- [ ] 3초 간격 × 3심볼 × 24시간 = 일 ~86,400 row 확인
- [ ] 데이터 품질 점검 (NULL, 이상치, 정규화 범위)

### M2.2 사후 라벨링 배치 구현
- [ ] 15분 지연 라벨링 로직 (`10_FEE_AND_LABELING.md` 참조)
- [ ] ret_fwd_1m/5m/15m 계산
- [ ] MFE/MAE 계산
- [ ] 수수료 차감 순지표 계산
- [ ] outcome_vector(15D) 생성
- [ ] label 부여 (BUY_GOOD/SELL_GOOD/HOLD)
- [ ] 라벨 분포 확인 (HOLD 90%+ 예상)

### M2.3 변곡점 감지 배치
- [ ] 변곡점 감지 로직 (CRASH/SURGE/VOL_EXPLOSION/REVERSAL)
- [ ] 전조 벡터(50D) 조립 (`03_VECTOR_DESIGN.md` 벡터 3 참조)
- [ ] TB_INFLECTION INSERT
- [ ] 변곡점 발생 빈도 확인 (일 수십 건 예상)

---

## Phase 3: 전략 엔진

### M3.1 L2 전방 패턴 매칭
- [ ] Oracle HNSW 쿼리 래퍼 (`06_L2_STRATEGY_ENGINE.md` 참조)
- [ ] TB_PATTERN에서 유사도 검색
- [ ] 관계형 필터 (regime, symbol, is_active) 결합
- [ ] 유사도 임계치 (0.85) 필터링
- [ ] 쿼리 응답 시간 측정 (목표: < 1ms)

### M3.2 L2 후방 전조 검색
- [ ] TrajectoryBuilder — 실시간 50D 전조 벡터 조립
- [ ] TB_INFLECTION HNSW 검색 (위험 + 기회)
- [ ] 전방 + 후방 결과 종합 판단 로직

### M3.3 패턴 승격 Trainer
- [ ] TB_SNAPSHOT 라벨 통계 집계 (symbol × label × 7일)
- [ ] 승격 조건 검증 (30회 + 60% + MFE/MAE 2.0)
- [ ] 클러스터 centroid 계산 → TB_PATTERN INSERT
- [ ] 기존 패턴 성능 재평가 → 비활성화 로직
- [ ] 매시간 배치 스케줄링

### M3.4 검증
- [ ] 축적된 데이터로 L2 시뮬레이션 (실제 주문 없이 신호만 생성)
- [ ] 패턴 승격 결과 검토 (설명이 합리적인지)
- [ ] 전방+후방 결합 시 신호 품질 개선 확인

---

## Phase 4: 거래 실행

### M4.1 Binance Testnet 설정
- [ ] testnet.binance.vision GitHub 로그인 + API Key 발급
- [ ] HMAC-SHA256 서명 로직 구현 (`07_L3_EXECUTION.md` 참조)
- [ ] 서버 시간 동기화 (GET /api/v3/time)
- [ ] 잔고 조회 테스트 (GET /api/v3/account)
- [ ] exchangeInfo 조회 + 심볼 필터 캐시

### M4.2 L3 리스크 게이트
- [ ] 7가지 진입 전 체크 구현
- [ ] TB_SYSTEM_CONFIG에서 런타임 파라미터 로드

### M4.3 L3 주문 실행
- [ ] LIMIT 진입 주문 생성 + 발송
- [ ] User Data Stream WebSocket 연결 (체결 이벤트)
- [ ] 미체결 타임아웃 (10초) + 취소 로직
- [ ] 부분 체결 처리

### M4.4 L3 포지션 감시 + 청산
- [ ] SL/TP/타임아웃 감시 루프 (100ms 주기)
- [ ] 손절: MARKET 즉시
- [ ] 익절: LIMIT 3초 시도 → MARKET 전환
- [ ] 타임아웃 (300초): MARKET 강제
- [ ] 수동 청산 (UI 버튼 연동)

### M4.5 결과 기록
- [ ] TB_SIM_TRADE INSERT (모든 필드)
- [ ] trade_vector(25D) 생성
- [ ] 이론-실전 갭 계산 (execution_gap)
- [ ] TB_PATTERN 통계 갱신 (sim_trade_count, sim_win_rate)

### M4.6 잔고 관리
- [ ] BalanceManager 구현 (로컬 캐시 + 체결 시 갱신)
- [ ] 일일 PnL 추적
- [ ] 쿨다운 로직

### M4.7 에러 처리
- [ ] API 타임아웃 복구
- [ ] WebSocket 재연결 + REST 폴링 전환
- [ ] 연속 손절 시 쿨다운 강화

---

## Phase 5: GPU + 외부 데이터 (Phase 2~4와 병렬 가능)

### M5.1 Qwen3.5 서빙
- [ ] Ollama 설치 + qwen3.5:27b 모델 로드
- [ ] OpenAI 호환 API 엔드포인트 확인
- [ ] 뉴스 분석 프롬프트 테스트
- [ ] 신호 검증 프롬프트 테스트
- [ ] TB_LLM_LOG 기록 로직

### M5.2 BGE-M3 서빙
- [ ] BGE-M3 모델 로드 (sentence-transformers)
- [ ] 임베딩 생성 테스트 (뉴스 텍스트 → 1024D)
- [ ] GPU 세마포어 (Qwen과 충돌 방지)

### M5.3 Tiingo News 수집
- [ ] 30초 폴링 루프 (`08_DATA_PIPELINE.md` 참조)
- [ ] Qwen 감성 분석 + BGE-M3 임베딩
- [ ] TB_NEWS_SIGNAL INSERT
- [ ] 사후 검증 (actual_impact UPDATE)

### M5.4 FRED 수집
- [ ] 일 1회 배치
- [ ] 레짐 분류 규칙 기반
- [ ] TB_MACRO_REGIME INSERT

### M5.5 SEC EDGAR 수집
- [ ] 시간 1회 배치
- [ ] 크립토 관련사 필터
- [ ] Qwen 분석 + BGE-M3 임베딩
- [ ] TB_SEC_FILING INSERT

---

## Phase 6: UI + 모니터링

### M6.1 대시보드
- [ ] React 프로젝트 셋업 (`11_UI_SPEC.md` 참조)
- [ ] 포트폴리오 카드 (투입금, 현재 가치, 손익)
- [ ] 메인 차트 (거래 마커 + 라이브 모드 자동 전환)
- [ ] 거래 내역 테이블 (LIVE 행 포함)
- [ ] FRED 거시 지표 패널
- [ ] 하단 지표 바 (6개)
- [ ] 시스템 상태 표시등 (L0~L3, DB, GPU)

### M6.2 벡터 탐색기
- [ ] 필터 바 (정렬, 라벨, 이벤트, 날짜/시간)
- [ ] 스냅샷 목록 테이블 (수익순 정렬)
- [ ] 상세 패널 (상황 벡터 + 결과 벡터)
- [ ] **컨텍스트 차트** (클릭 시 하단 펼침, MFE/MAE 라인)
- [ ] 통계 요약 카드

### M6.3 API 서버
- [ ] FastAPI 또는 Flask 기반
- [ ] GET /api/dashboard, GET /api/snapshots, GET /api/snapshots/{id}/chart
- [ ] WebSocket /ws/live (가격, 거래 이벤트)
- [ ] Oracle DB 커넥션 풀

---

## Phase 7: 검증 + 튜닝

### M7.1 모의거래 100회 달성
- [ ] 최소 100회 모의거래 완료
- [ ] 승률 60% 이상 확인
- [ ] 이론-실전 갭(execution_gap) 분석
- [ ] 슬리피지 평균 확인 (Testnet 특성 감안)
- [ ] 수수료 영향 분석 (fee_impact_pct 분포)

### M7.2 파라미터 최적화
- [ ] 유사도 임계치 (0.85) 조정 테스트
- [ ] SL/TP 비율 최적화
- [ ] 최대 보유 시간 조정
- [ ] 스냅샷 간격 (3초) 조정 테스트
- [ ] 패턴 승격 기준 조정

### M7.3 후방 추적 효과 검증
- [ ] 전방만 vs 양방향 A/B 비교
- [ ] 전조 패턴 감지 정확도 측정
- [ ] 위험 회피로 인한 손실 방어 효과 수치화

### M7.4 실전 전환 체크리스트
- [ ] 모의거래 100회+ 달성
- [ ] 승률 60%+ 유지
- [ ] execution_gap < 0.1% 수준
- [ ] TESTNET_MODE=0 전환
- [ ] 리스크 파라미터 보수화 (포지션 2%, 일일 손실 1.5%, 동시 1건)
- [ ] 첫 1주: 최소 수량, 단일 심볼
- [ ] 모니터링 강화 (알림 설정)

---

## 파일 의존성 그래프

```
Phase 1 (기반)
  01_ARCHITECTURE.md  ← 전체 이해
  02_SCHEMA.md        ← DB 구축
  04_L0_GATEWAY.md    ← 데이터 수신
  05_L1_FEATURE_ENGINE.md ← 피처 계산
  03_VECTOR_DESIGN.md ← 벡터 구조 이해

Phase 2 (축적)
  10_FEE_AND_LABELING.md ← 라벨링 로직

Phase 3 (전략)
  06_L2_STRATEGY_ENGINE.md ← 패턴 매칭
  03_VECTOR_DESIGN.md ← 전조 벡터

Phase 4 (거래)
  07_L3_EXECUTION.md ← 주문 실행

Phase 5 (GPU/데이터, 병렬)
  09_GPU_PIPELINE.md ← 모델 서빙
  08_DATA_PIPELINE.md ← 외부 API

Phase 6 (UI)
  11_UI_SPEC.md ← 화면 명세
```
