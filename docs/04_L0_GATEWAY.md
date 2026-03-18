# 04. L0 : 게이트웨이 — WebSocket 연결 + 링 버퍼

## 역할
시스템의 유일한 입력 관문. Binance WebSocket에서 실시간 데이터를 수신하여 정규화하고 인메모리 링 버퍼에 적재.

## 구성요소

```
L0_Gateway/
├── ws_connector.py       # WebSocket 연결 관리 (재연결 포함)
├── stream_normalizer.py  # 이벤트 타입별 정규화
├── ring_buffer.py        # 인메모리 고정 크기 버퍼
└── snapshot_trigger.py   # N초 간격 스냅샷 트리거 → L1 호출
```

## WebSocket 스트림

### 구독 스트림 (심볼당)
```
wss://testnet.binance.vision/ws

Combined stream 방식:
wss://testnet.binance.vision/stream?streams=
  btcusdt@trade/
  btcusdt@depth20@100ms/
  btcusdt@kline_1m
```

| 스트림 | 데이터 | 빈도 | 용도 |
|--------|--------|------|------|
| `{symbol}@trade` | 개별 체결 | 틱마다 (초당 수십~수백) | 체결 강도, 가격 |
| `{symbol}@depth20@100ms` | 호가창 상위 20호가 | 100ms | imbalance, spread, depth |
| `{symbol}@kline_1m` | 1분 캔들 | 1분 | OHLCV, 보조 지표 |

### 재연결 로직
```python
async def connect_with_retry(symbols, max_retries=10):
    retry_delay = 1  # 초기 1초, 최대 60초까지 지수 백오프
    for attempt in range(max_retries):
        try:
            streams = "/".join(f"{s.lower()}@trade/{s.lower()}@depth20@100ms/{s.lower()}@kline_1m" for s in symbols)
            url = f"{WS_BASE}/stream?streams={streams}"
            async with websockets.connect(url, ping_interval=20) as ws:
                retry_delay = 1
                async for msg in ws:
                    data = json.loads(msg)
                    normalized = normalize(data)
                    ring_buffer.push(normalized)
        except Exception as e:
            log.warning(f"WS 끊김 (시도 {attempt+1}): {e}")
            await asyncio.sleep(retry_delay)
            retry_delay = min(retry_delay * 2, 60)
```

## 링 버퍼

```python
from collections import deque

class RingBuffer:
    def __init__(self, max_size=10000):
        self.max_size = max_size
        self.trades = {}    # {symbol: deque(maxlen=max_size)}
        self.depths = {}    # {symbol: 최신 depth snapshot}
        self.klines = {}    # {symbol: deque(maxlen=100)}
    
    def push_trade(self, symbol, trade):
        if symbol not in self.trades:
            self.trades[symbol] = deque(maxlen=self.max_size)
        self.trades[symbol].append(trade)
    
    def push_depth(self, symbol, depth):
        self.depths[symbol] = depth  # 항상 최신만 유지
    
    def get_last_price(self, symbol):
        return self.trades[symbol][-1]["price"]
    
    def get_trades_window(self, symbol, seconds):
        """직전 N초간의 체결 데이터 반환"""
        cutoff = time.time() - seconds
        return [t for t in self.trades[symbol] if t["ts"] >= cutoff]
    
    def get_depth(self, symbol):
        return self.depths.get(symbol)
```

## 정규화 포맷

```python
# Trade 이벤트 정규화
{
    "type": "trade",
    "symbol": "BTCUSDT",
    "ts": 1710648000.123,      # Unix timestamp (초, 소수점 밀리초)
    "price": 87234.50,
    "qty": 0.015,
    "is_buyer_maker": False,   # True=매도 체결, False=매수 체결
    "trade_id": 123456789,
}

# Depth 이벤트 정규화
{
    "type": "depth",
    "symbol": "BTCUSDT",
    "ts": 1710648000.200,
    "bids": [[87234.00, 1.5], [87233.50, 2.3], ...],  # [가격, 수량] × 20
    "asks": [[87235.00, 0.8], [87235.50, 1.1], ...],
}
```

## 스냅샷 트리거

```python
async def snapshot_loop(ring_buffer, config, l1_engine):
    """매 N초마다 L1에 스냅샷 생성 요청"""
    interval = config.SNAPSHOT_INTERVAL_SEC  # 기본 3초
    
    while True:
        await asyncio.sleep(interval)
        for symbol in config.TRADING_SYMBOLS:
            if symbol in ring_buffer.trades and len(ring_buffer.trades[symbol]) > 0:
                await l1_engine.process_snapshot(symbol, ring_buffer)
```

## 구현 참고사항

- Python `websockets` 또는 `aiohttp` 사용
- 심볼 3개 기준 초당 ~300~1000 이벤트 처리 필요
- Ring buffer는 스레드 안전 불필요 (단일 asyncio 루프)
- 메모리 사용량: 심볼당 ~10MB (10,000 trades × ~1KB)
