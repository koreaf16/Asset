# COIN 단타 시스템 — 개발 문서 인덱스

> Binance Spot 현물 모의거래 · Oracle 26ai 벡터DB · RTX 3090 로컬 GPU  
> 최종 정리일: 2026-03-17  
> 문서 버전: v1.2

---

## 문서 목록

| # | 파일명 | 내용 | 담당 우선순위 |
|---|--------|------|-------------|
| 00 | `00_INDEX.md` | 이 문서 (전체 인덱스) | — |
| 01 | `01_ARCHITECTURE.md` | 시스템 전체 구조, 레이어 정의, 데이터 흐름 | 필독 |
| 02 | `02_SCHEMA.md` | Oracle 26ai 테이블 설계 + DDL | DB 담당 |
| 03 | `03_VECTOR_DESIGN.md` | 벡터 4종 설계 (상황/결과/전조/거래) | 핵심 |
| 04 | `04_L0_GATEWAY.md` | WebSocket 연결, 스트림 정규화, 링 버퍼 | 1순위 |
| 05 | `05_L1_FEATURE_ENGINE.md` | 피처 산출, 35차원 벡터 생성, 이벤트 감지 | 2순위 |
| 06 | `06_L2_STRATEGY_ENGINE.md` | 패턴 매칭, 후방 추적, 신호 판단 | 3순위 |
| 07 | `07_L3_EXECUTION.md` | 리스크 게이트, 주문 실행, Testnet 연동 | 4순위 |
| 08 | `08_DATA_PIPELINE.md` | Tiingo, FRED, SEC EDGAR 수집 파이프라인 | 병렬 |
| 09 | `09_GPU_PIPELINE.md` | BGE-M3 임베딩, Qwen3.5 분석 역할 | 병렬 |
| 10 | `10_FEE_AND_LABELING.md` | 수수료 체계, 라벨링 로직, 패턴 승격 기준 | 핵심 |
| 11 | `11_UI_SPEC.md` | 대시보드 + 벡터 탐색기 화면 명세 | 5순위 |
| 12 | `12_ROADMAP.md` | 구현 순서, 마일스톤, 체크리스트 | 필독 |

---

## 기술 스택 요약

| 구분 | 기술 |
|------|------|
| 언어 | Python 3.11+ (asyncio), 병목 시 Cython/Rust |
| DB | Oracle 26ai (VECTOR 타입, HNSW 인덱스) |
| GPU | RTX 3090 24GB (BGE-M3 ~2GB + Qwen3.5-27B Q4 ~16GB) |
| 거래소 | Binance Spot Testnet → 실전 전환 (URL만 변경) |
| 외부 API | Tiingo News, FRED, SEC EDGAR |
| UI | React (JSX), 다크 테마 |

## 핵심 설계 원칙

1. **숫자 벡터 주력** — 패턴 매칭은 35차원 숫자 벡터, BGE-M3는 텍스트 보조
2. **양방향 추적** — 전방(현재→미래 결과) + 후방(결과→과거 전조) 동시
3. **수수료 내재화** — 모든 라벨링/패턴 승격 기준이 수수료 차감 후 기준
4. **무조건 수집** — 패턴 매칭 여부 무관, 모든 스냅샷 기록 (HOLD 포함)
5. **실전 전환 0코드** — 환경변수 하나로 Testnet↔실전 전환
