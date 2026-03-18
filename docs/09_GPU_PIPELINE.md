# 09. GPU 파이프라인 — BGE-M3 + Qwen3.5-27B

## 하드웨어
- RTX 3090 24GB VRAM
- BGE-M3: ~2GB VRAM
- Qwen3.5-27B Q4: ~16GB VRAM
- 여유: ~6GB (KV cache + 배치)

## VRAM 충돌 방지
BGE-M3는 실시간 틱 처리 (뉴스 임베딩), Qwen은 비동기 분석 (수초 소요). 동시 추론 시 피크가 겹치지 않도록 시간 분리.

```python
# GPU 스케줄러 (간단한 세마포어)
gpu_lock = asyncio.Lock()

async def embed_with_bge(text):
    """BGE-M3 임베딩 (~5ms, 실시간 경로에 사용 가능)"""
    async with gpu_lock:
        return bge_model.encode(text)

async def analyze_with_qwen(prompt):
    """Qwen3.5 분석 (~2-5초, 반드시 비동기)"""
    async with gpu_lock:
        return qwen_model.generate(prompt, max_tokens=500)
```

## BGE-M3 역할 (보조)

| 용도 | 입력 | 출력 | 저장 위치 | 빈도 |
|------|------|------|----------|------|
| 뉴스 임베딩 | Tiingo 기사 제목+본문 | 1024D | TB_NEWS_SIGNAL.news_vector | ~100/일 |
| SEC 공시 임베딩 | 8-K/Form4 요약 | 1024D | TB_SEC_FILING.filing_vector | ~10/일 |
| 스냅샷 컨텍스트 (선택) | 시장 상태 텍스트 요약 | 1024D | TB_SNAPSHOT.ctx_vector | 필요 시 |

**현재는 뉴스/공시 임베딩만 사용. 스냅샷 ctx_vector는 향후 2단계 검색 활성화 시 사용.**

## Qwen3.5-27B 역할 (비동기 분석가)

| 용도 | 트리거 | 입력 | 출력 | 빈도 |
|------|--------|------|------|------|
| 뉴스 감성 분석 | Tiingo 새 기사 | 기사 제목+본문 | sentiment, impact, topic | ~100/일 |
| SEC 공시 분석 | EDGAR 새 공시 | 공시 요약 | crypto_relevant, impact | ~10/일 |
| 신호 검증 | L2 매수 신호 발생 | 현재 시장 상태 + 패턴 정보 | 진입 적합성 판단 | 신호당 1회 |
| 패턴 라벨링 | Trainer 배치 | 패턴 통계 + 샘플 스냅샷 | 패턴 설명 텍스트 | 일 1회 |
| 레짐 종합 리뷰 | 일 1회 | FRED + 뉴스 + 시장 요약 | 레짐 진단 리포트 | 일 1회 |

### 신호 검증 프롬프트 예시
```
현재 시장 상태:
- 심볼: BTCUSDT, 가격: $87,234
- 레짐: RISK_ON (STLFSI: -0.42)
- Spread: 0.025%, Imbalance: +0.65 (매수 우세)
- 1분 수익률: +0.12%, 5분: +0.45%
- 최근 뉴스: "SEC, 비트코인 현물 ETF 추가 승인" (impact: 0.7)

매칭된 패턴 (#12):
- 승률: 68%, MFE/MAE: 2.3
- 설명: "매수 우세 호가 + 상승 모멘텀 + 긍정 뉴스 결합"
- 유사도: 0.94

이 진입이 합리적인지 판단하세요. JSON으로 응답:
{"decision": "APPROVE|CAUTION|REJECT", "confidence": 0.0~1.0, "reason": "..."}
```

**주의: Qwen 검증은 비동기. 결과가 오기 전에 L3가 이미 주문을 넣을 수 있음. Qwen이 REJECT하면 포지션 조기 청산 신호를 보냄.**

## 모델 서빙 방식

```python
# Ollama 로컬 서빙 (추천)
# ollama run qwen3.5:27b

import httpx

OLLAMA_URL = "http://localhost:11434/v1/chat/completions"

async def qwen_generate(prompt, system="You are a crypto trading analyst."):
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(OLLAMA_URL, json={
            "model": "qwen3.5:27b",
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.1,
        })
        return resp.json()["choices"][0]["message"]["content"]
```

## 로그 기록
모든 Qwen 호출은 TB_LLM_LOG에 기록:
- task_type, ref_id, ref_table, prompt_summary, response, confidence
- inference_ms, tokens_used
- was_correct (사후 UPDATE로 검증)
