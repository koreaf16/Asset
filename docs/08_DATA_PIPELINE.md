# 08. 외부 데이터 파이프라인 — Tiingo, FRED, SEC EDGAR

## 데이터 소스 우선순위

| 순위 | 소스 | 단타 영향도 | 수집 주기 | 처리 방식 |
|------|------|-----------|----------|----------|
| 1 | Tiingo News | 직접적 (가격 즉시 반응) | 30초 폴링 | Qwen 감성분석 + BGE-M3 임베딩 |
| 2 | FRED | 간접적 (시장 레짐 분류) | 일 1회 | 규칙 기반 regime 분류 |
| 3 | SEC EDGAR | 간접적 (크립토 관련사 공시) | 시간 1회 | Qwen 영향도 분석 |

---

## 1. Tiingo News

### 설정값 (기존 .env에서 가져옴)
```
TIINGO_API_KEY=YOUR_TIINGO_API_KEY
TIINGO_BASE_URL=https://api.tiingo.com
TIINGO_NEWS_LIMIT=100
TIINGO_NEWS_TICKERS=BTC,ETH,SOL,XRP,DOGE,LINK,APT,SUI,ARB,PEPE
TIINGO_NEWS_TAGS=crypto,cryptocurrency
```

### 수집 흐름
```
[30초마다]
1. GET /tiingo/news?tickers={tickers}&tags={tags}&limit=20&startDate={last_fetch}
2. 중복 체크 (title hash 기준)
3. 새 기사마다:
   a. Qwen3.5 분석 → sentiment(-1~1), impact_score(0~1), topic, summary
   b. BGE-M3 임베딩 → news_vector(1024D)
   c. TB_NEWS_SIGNAL INSERT
4. impact_score > 0.5 → 해당 심볼 스냅샷에 event_flags |= 16 설정
```

### Qwen 뉴스 분석 프롬프트
```
다음 암호화폐 뉴스를 분석하세요.

제목: {title}
본문: {content}
관련 티커: {tickers}

다음 형식으로 JSON만 출력:
{
  "sentiment": -1.0 ~ 1.0 (부정 ~ 긍정),
  "impact_score": 0.0 ~ 1.0 (가격 영향 예상 크기),
  "topic": "REGULATION | ADOPTION | HACK | MACRO | PARTNERSHIP | LISTING | OTHER",
  "affected_tickers": ["BTC", "ETH"],
  "summary": "한 줄 요약"
}
```

### 사후 검증
- 뉴스 발행 후 5분간 해당 코인의 실제 가격 변화를 측정하여 `actual_impact` UPDATE
- impact_score vs actual_impact 상관관계로 Qwen 분석 정확도 추적

---

## 2. FRED API

### 설정값
```
FRED_API_KEY=YOUR_FRED_API_KEY
FRED_SERIES_IDS=FEDFUNDS,CPIAUCSL,UNRATE,M2SL,WALCL,DGS10,DGS2,STLFSI4
```

### 수집 흐름
```
[매일 09:00 KST]
1. GET /fred/series/observations?series_id={id}&api_key={key}&sort_order=desc&limit=1
2. 8개 시리즈 모두 조회
3. 파생 지표 계산:
   - dgs_spread = DGS10 - DGS2 (장단기 금리차)
   - walcl_chg_pct = (WALCL - WALCL_prev) / WALCL_prev * 100
4. 레짐 분류 (규칙 기반)
5. TB_MACRO_REGIME INSERT
```

### 레짐 분류 규칙
```python
def classify_regime(fred_data):
    score = 0
    
    # 장단기 스프레드 (역전이면 risk-off)
    dgs_spread = fred_data["DGS10"] - fred_data["DGS2"]
    if dgs_spread < 0:
        score -= 2
    elif dgs_spread > 0.5:
        score += 1
    
    # 금융 스트레스 지수
    if fred_data["STLFSI4"] > 1.0:
        score -= 2
    elif fred_data["STLFSI4"] < -0.5:
        score += 1
    
    # 연준 대차대조표 변화
    if fred_data["walcl_chg_pct"] > 0:
        score += 1  # 유동성 확대
    else:
        score -= 1  # 유동성 축소
    
    # 실업률 추세
    if fred_data["UNRATE"] > 4.5:
        score -= 1
    
    if score >= 2:
        return "RISK_ON", score / 5.0
    elif score <= -2:
        return "RISK_OFF", score / 5.0
    else:
        return "NEUTRAL", score / 5.0
```

---

## 3. SEC EDGAR

### 설정값
```
SEC_EDGAR_RSS_URL=https://efts.sec.gov/LATEST/search-index?q="8-K"&dateRange=custom&startdt={start}&enddt={end}&forms=8-K
SEC_EDGAR_FULL_TEXT_BASE=https://www.sec.gov/Archives/edgar/data
SEC_USER_AGENT=QuantBot/1.0 (your-email@example.com)
SEC_RATE_LIMIT_RPS=10
SEC_FEED_FORMS=8-K,4,10-K,10-Q
SEC_FEED_LOOKBACK_DAYS=7
```

### 수집 흐름
```
[매시간]
1. 8-K, Form 4 검색 (직전 1시간)
2. 크립토 관련사 필터링 (MicroStrategy, Coinbase, Marathon Digital, Riot, Galaxy Digital 등)
3. 관련 공시만 Qwen 분석:
   a. crypto_relevant (0/1)
   b. impact_score (0~1)
   c. affected_coins
   d. summary
4. BGE-M3 임베딩 → filing_vector(1024D)
5. TB_SEC_FILING INSERT
```

### 크립토 관련사 CIK 목록 (사전 등록)
```python
CRYPTO_CIKS = {
    "0001050446": "MicroStrategy",
    "0001679788": "Coinbase",
    "0001507605": "Marathon Digital",
    "0001167419": "Riot Platforms",
    "0001725134": "Galaxy Digital",
    # ... 확장 가능
}
```

---

## L2 연동 방식

세 소스 모두 **실시간 경로에 직접 개입하지 않음**. 대신:

1. **Tiingo** → `TB_NEWS_SIGNAL.sentiment` → TB_SNAPSHOT.news_sentiment에 반영 → num_vector[26]에 포함
2. **FRED** → `TB_MACRO_REGIME.regime` → TB_SNAPSHOT.regime에 반영 → num_vector[25]에 포함 + L2 WHERE 필터
3. **SEC** → 고임팩트 공시 시 event_flags |= 16 → 이벤트 스냅샷 가중치 증가

모두 비동기 경로이며, 데이터가 없어도 시스템은 정상 동작함.
