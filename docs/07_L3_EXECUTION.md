# L3 : 리스크 관리 + 주문 실행 — 상세 설계서

> Binance Spot Testnet · Python asyncio 기반  
> 실전 전환 시 URL만 변경 (코드 변경 0)

---

## 1. Binance Testnet 환경 정보

| 항목 | Testnet | 실전 (전환 시) |
|------|---------|---------------|
| REST API | `https://testnet.binance.vision/api/v3` | `https://api.binance.com/api/v3` |
| WebSocket 시장 | `wss://testnet.binance.vision/ws` | `wss://stream.binance.com:9443/ws` |
| WebSocket 사용자 | `wss://testnet.binance.vision/ws/{listenKey}` | `wss://stream.binance.com:9443/ws/{listenKey}` |
| API Key 발급 | testnet.binance.vision (GitHub 로그인) | binance.com 계정 |
| 인증 방식 | HMAC-SHA256 (또는 Ed25519/RSA) | 동일 |
| 잔고 | 자동 지급 (가상 자산) | 실제 잔고 |
| 데이터 리셋 | 월 1회 전체 초기화 | 없음 |
| 수수료 | 실제와 동일 구조 적용 | 동일 |

### 주의사항
- Testnet은 월 1회 전체 리셋됨 → 주문/잔고 모두 초기화
- Testnet 호가창 유동성이 실서버보다 훨씬 낮음 → 슬리피지 과대 측정 가능
- payload percent-encode 후 서명 필수 (2026-01-15부터 실서버에도 적용)

---

## 2. L3 내부 구성요소

```
L3_OrderDispatcher/
├── config.py              # 설정 로더 (TB_SYSTEM_CONFIG에서 읽기)
├── risk_gate.py           # 1단계: 진입 전 리스크 게이트
├── order_builder.py       # 2단계: 주문 생성 (수량 계산, 필터 검증)
├── executor.py            # 3단계: 주문 발송 + 체결 확인
├── position_monitor.py    # 3단계: 포지션 감시 (SL/TP/타임아웃)
├── exit_handler.py        # 4단계: 청산 실행
├── trade_recorder.py      # 5단계: 결과 기록 (TB_SIM_TRADE + 벡터 생성)
├── balance_manager.py     # 잔고 조회 + 캐시
├── binance_client.py      # Binance API 래퍼 (Testnet/실전 URL 전환)
└── state_machine.py       # 거래 상태 관리 (FSM)
```

---

## 3. 거래 상태 기계 (State Machine)

```
IDLE → SIGNAL_RECEIVED → RISK_CHECK → ORDER_PLACED → 
  ├→ FILLED → MONITORING → EXIT_TRIGGERED → EXIT_FILLED → RECORDING → IDLE
  ├→ PARTIAL_FILL → (대기 or 취소) → ...
  ├→ REJECTED → RECORDING → IDLE
  ├→ TIMEOUT_UNFILLED → CANCEL → RECORDING → IDLE
  └→ ERROR → RECORDING → IDLE
```

### 상태 정의

| 상태 | 설명 | 다음 상태 | 최대 체류 시간 |
|------|------|----------|-------------|
| IDLE | 대기 중, 신호 수신 가능 | SIGNAL_RECEIVED | 무제한 |
| SIGNAL_RECEIVED | L2에서 신호 수신 | RISK_CHECK | 즉시 |
| RISK_CHECK | 리스크 게이트 검증 중 | ORDER_PLACED 또는 REJECTED | < 10ms |
| ORDER_PLACED | 주문 발송됨, 체결 대기 | FILLED / PARTIAL_FILL / TIMEOUT_UNFILLED | 10초 |
| FILLED | 전량 체결 완료 | MONITORING | 즉시 |
| PARTIAL_FILL | 부분 체결 | FILLED 또는 CANCEL | 10초 |
| MONITORING | 포지션 보유 중, SL/TP 감시 | EXIT_TRIGGERED / TIMEOUT | 300초 |
| EXIT_TRIGGERED | 청산 조건 충족 | EXIT_FILLED | 5초 |
| EXIT_FILLED | 청산 체결 완료 | RECORDING | 즉시 |
| RECORDING | DB 기록 중 | IDLE | < 100ms |
| REJECTED | 리스크 게이트 거부 | RECORDING | 즉시 |
| ERROR | 예외 발생 | RECORDING | 즉시 |

---

## 4. 1단계: 진입 전 리스크 게이트 (risk_gate.py)

```python
# 의사코드
async def check_entry(signal, account_state, config) -> (bool, str):
    """
    모든 체크를 통과해야 주문 진행.
    하나라도 실패하면 (False, 사유) 반환.
    """
    
    # 체크 1: 최대 동시 포지션 수
    if account_state.open_positions >= config.RISK_MAX_OPEN_TRADES:
        return False, "MAX_OPEN_TRADES 초과"
    
    # 체크 2: 단일 포지션 비율
    position_value = signal.quantity * signal.price
    if position_value / account_state.total_equity > config.RISK_MAX_POSITION_PCT / 100:
        return False, "POSITION_SIZE 초과"
    
    # 체크 3: 일일 최대 손실
    if account_state.daily_pnl_pct <= -config.RISK_MAX_DAILY_LOSS:
        return False, "DAILY_LOSS_LIMIT 도달"
    
    # 체크 4: 손절 후 쿨다운
    if account_state.last_stop_loss_at:
        elapsed = now() - account_state.last_stop_loss_at
        if elapsed < timedelta(seconds=config.RISK_COOLDOWN_SEC):
            return False, f"COOLDOWN 잔여 {config.RISK_COOLDOWN_SEC - elapsed.seconds}초"
    
    # 체크 5: 잔고 충분한지
    required = signal.quantity * signal.price * (1 + config.FEE_TAKER_RATE / 100)
    available = await get_available_balance(signal.quote_asset)
    if available < required:
        return False, f"잔고 부족 (필요: {required}, 가용: {available})"
    
    # 체크 6: 심볼 필터 (LOT_SIZE, MIN_NOTIONAL, PRICE_FILTER)
    ok, reason = validate_symbol_filters(signal.symbol, signal.quantity, signal.price)
    if not ok:
        return False, f"필터 미충족: {reason}"
    
    # 체크 7: 동일 심볼 중복 진입 방지
    if signal.symbol in account_state.open_symbols:
        return False, f"{signal.symbol} 이미 포지션 보유 중"
    
    return True, "PASS"
```

### 리스크 파라미터 (TB_SYSTEM_CONFIG에서 런타임 조정 가능)

| 키 | 기본값 | 설명 |
|----|--------|------|
| RISK_MAX_POSITION_PCT | 5.0 | 단일 포지션 최대 비율 (%) |
| RISK_MAX_OPEN_TRADES | 3 | 최대 동시 진입 수 |
| RISK_MAX_DAILY_LOSS | 3.0 | 일일 최대 손실 (%) |
| RISK_COOLDOWN_SEC | 60 | 손절 후 대기 시간 (초) |
| RISK_STOP_LOSS_PCT | 1.0 | 손절 비율 (%) |
| RISK_TAKE_PROFIT_PCT | 1.5 | 익절 비율 (%) |
| RISK_MAX_HOLD_SEC | 300 | 최대 보유 시간 (초) |

---

## 5. 2단계: 주문 생성 (order_builder.py)

### 진입 주문 — LIMIT (maker)

```python
async def build_entry_order(signal, config):
    """
    지정가 주문으로 진입 (수수료 절감).
    best bid/ask 기준으로 유리한 가격에 걸기.
    """
    
    # 현재 호가와 심볼 필터 조회
    ticker = await client.get_ticker(signal.symbol)
    filters = get_symbol_filters(signal.symbol)
    lot_step = filters["LOT_SIZE"]["stepSize"]
    
    if signal.side == "BUY":
        # best bid 가격에 걸기 (maker)
        entry_price = ticker.best_bid
    else:
        # best ask 가격에 걸기 (maker)
        entry_price = ticker.best_ask
    
    # 수량 계산
    equity = await get_total_equity()
    position_value = equity * (config.RISK_MAX_POSITION_PCT / 100)
    raw_qty = position_value / entry_price
    
    # 심볼 필터 적용
    qty = apply_lot_size_filter(signal.symbol, raw_qty)  # stepSize 맞춤
    price = apply_price_filter(signal.symbol, entry_price)  # tickSize 맞춤
    
    # MIN_NOTIONAL 체크
    min_notional = get_min_notional(signal.symbol)
    if qty * price < min_notional:
        qty = math.ceil(min_notional / price / lot_step) * lot_step
        qty = apply_lot_size_filter(signal.symbol, qty)
    
    return {
        "symbol": signal.symbol,
        "side": signal.side,
        "type": "LIMIT",
        "timeInForce": "GTC",
        "quantity": qty,
        "price": price,
        "newOrderRespType": "FULL",  # 체결 정보 포함 응답
        "timestamp": int(time.time() * 1000),
        "recvWindow": 5000,
    }
```

### 심볼 필터 처리

```python
# Binance exchangeInfo에서 가져오는 필터들
# 시스템 시작 시 한 번 조회 후 캐시 (1시간 갱신)

FILTERS = {
    "BTCUSDT": {
        "LOT_SIZE": {"minQty": 0.00001, "maxQty": 9000, "stepSize": 0.00001},
        "PRICE_FILTER": {"minPrice": 0.01, "maxPrice": 1000000, "tickSize": 0.01},
        "MIN_NOTIONAL": {"minNotional": 5.0},  # 최소 주문 금액 5 USDT
    }
}
```

---

## 6. 3단계: 주문 발송 + 체결 감시 (executor.py)

### 주문 발송

```python
async def place_order(order_params):
    """
    POST /api/v3/order
    """
    # 서명 생성 (HMAC-SHA256)
    query_string = urlencode(order_params)
    signature = hmac.new(
        SECRET_KEY.encode(), 
        query_string.encode(), 
        hashlib.sha256
    ).hexdigest()
    
    order_params["signature"] = signature
    
    headers = {"X-MBX-APIKEY": API_KEY}
    
    response = await session.post(
        f"{BASE_URL}/api/v3/order",
        params=order_params,
        headers=headers,
    )
    
    return response.json()
```

### 체결 확인 — User Data Stream

```python
async def listen_user_data():
    """
    WebSocket으로 체결 이벤트 실시간 수신.
    REST 폴링보다 훨씬 빠름.
    """
    # 1) listenKey 발급
    listen_key = await create_listen_key()  # POST /api/v3/userDataStream
    
    # 2) WebSocket 연결
    ws_url = f"wss://testnet.binance.vision/ws/{listen_key}"
    
    async with websockets.connect(ws_url) as ws:
        while True:
            msg = json.loads(await ws.recv())
            
            if msg["e"] == "executionReport":
                order_id = msg["i"]
                status = msg["X"]  # NEW, FILLED, PARTIALLY_FILLED, CANCELED
                exec_qty = float(msg["l"])  # 이번 체결 수량
                exec_price = float(msg["L"])  # 이번 체결 가격
                commission = float(msg["n"])  # 수수료
                commission_asset = msg["N"]  # 수수료 자산 (BNB 등)
                
                await handle_execution(order_id, status, exec_qty, exec_price, 
                                      commission, commission_asset)
    
    # 3) listenKey 갱신 (30분마다)
    # PUT /api/v3/userDataStream?listenKey={key}
```

### 미체결 타임아웃 처리

```python
async def watch_unfilled(order_id, symbol, timeout_sec=10):
    """
    LIMIT 주문이 timeout_sec 내에 체결되지 않으면 취소.
    """
    await asyncio.sleep(timeout_sec)
    
    # 주문 상태 확인
    order = await client.get_order(symbol, order_id)
    
    if order["status"] in ("NEW", "PARTIALLY_FILLED"):
        # 미체결 → 취소
        await client.cancel_order(symbol, order_id)
        
        if order["status"] == "PARTIALLY_FILLED":
            # 부분 체결 → 이미 보유한 수량은 즉시 시장가 청산
            filled_qty = float(order["executedQty"])
            if filled_qty > 0:
                await market_close(symbol, filled_qty, "PARTIAL_TIMEOUT")
        
        return "TIMEOUT_UNFILLED"
    
    return "FILLED"
```

---

## 7. 3단계: 포지션 감시 (position_monitor.py)

```python
async def monitor_position(position):
    """
    체결 후 매 틱마다 SL/TP/타임아웃 체크.
    L0 Ring Buffer의 가격 데이터를 직접 읽음 (REST 호출 없음).
    """
    entry_time = time.time()
    entry_price = position.entry_price
    
    sl_price = entry_price * (1 - config.RISK_STOP_LOSS_PCT / 100)   # 매수 기준
    tp_price = entry_price * (1 + config.RISK_TAKE_PROFIT_PCT / 100)
    max_hold = config.RISK_MAX_HOLD_SEC
    
    # 실시간 MFE/MAE 추적
    mfe = 0.0  # 최대 유리 움직임
    mae = 0.0  # 최대 불리 움직임
    
    while True:
        current_price = ring_buffer.get_last_price(position.symbol)
        elapsed = time.time() - entry_time
        
        # MFE/MAE 갱신
        if position.side == "BUY":
            pnl = (current_price - entry_price) / entry_price * 100
        else:
            pnl = (entry_price - current_price) / entry_price * 100
        
        mfe = max(mfe, pnl)
        mae = min(mae, pnl)
        
        # 손절 체크
        if pnl <= -config.RISK_STOP_LOSS_PCT:
            return ExitSignal("STOP_LOSS", current_price, mfe, mae, elapsed)
        
        # 익절 체크
        if pnl >= config.RISK_TAKE_PROFIT_PCT:
            return ExitSignal("TAKE_PROFIT", current_price, mfe, mae, elapsed)
        
        # 타임아웃 체크
        if elapsed >= max_hold:
            return ExitSignal("TIMEOUT", current_price, mfe, mae, elapsed)
        
        # Qwen 비동기 검증 결과 반영
        if position.qwen_exit_signal:
            return ExitSignal("QWEN_ALERT", current_price, mfe, mae, elapsed)
        
        await asyncio.sleep(0.1)  # 100ms 주기
```

---

## 8. 4단계: 청산 실행 (exit_handler.py)

| 청산 사유 | 주문 방식 | 이유 |
|----------|----------|------|
| STOP_LOSS | 시장가 (MARKET) | 즉시 탈출 최우선 |
| TAKE_PROFIT | 지정가 (LIMIT) 시도 → 3초 미체결 시 시장가 | maker 수수료 절감 시도 |
| TIMEOUT | 시장가 (MARKET) | 빠른 정리 |
| MANUAL | 시장가 (MARKET) | UI 버튼 |
| QWEN_ALERT | 시장가 (MARKET) | 위험 회피 |

```python
async def execute_exit(position, exit_signal):
    """
    청산 주문 실행.
    """
    # 청산 방향 결정
    exit_side = "SELL" if position.side == "BUY" else "BUY"
    
    if exit_signal.reason == "TAKE_PROFIT":
        # 익절: 지정가 시도
        order = await place_limit_order(
            symbol=position.symbol,
            side=exit_side,
            qty=position.quantity,
            price=exit_signal.price,
        )
        
        # 3초 대기
        result = await watch_unfilled(order["orderId"], position.symbol, timeout_sec=3)
        
        if result == "TIMEOUT_UNFILLED":
            # 미체결 → 시장가로 전환
            await cancel_order(position.symbol, order["orderId"])
            order = await place_market_order(
                symbol=position.symbol,
                side=exit_side,
                qty=position.quantity,
            )
    else:
        # SL / 타임아웃 / 수동 / Qwen → 시장가 즉시
        order = await place_market_order(
            symbol=position.symbol,
            side=exit_side,
            qty=position.quantity,
        )
    
    return order
```

---

## 9. 5단계: 결과 기록 (trade_recorder.py)

```python
async def record_trade(position, entry_order, exit_order, exit_signal, snap_id):
    """
    TB_SIM_TRADE INSERT + trade_vector 생성.
    """
    
    # 체결 정보 추출
    entry_price = float(entry_order["fills"][0]["price"])
    exit_price = float(exit_order["fills"][0]["price"]) if exit_order["fills"] else exit_signal.price
    
    entry_commission = sum(float(f["commission"]) for f in entry_order["fills"])
    exit_commission = sum(float(f["commission"]) for f in exit_order.get("fills", []))
    
    # PnL 계산
    if position.side == "BUY":
        pnl_gross = (exit_price - entry_price) / entry_price * 100
    else:
        pnl_gross = (entry_price - exit_price) / entry_price * 100
    
    fee_entry_pct = entry_commission / (position.quantity * entry_price) * 100
    fee_exit_pct = exit_commission / (position.quantity * exit_price) * 100
    fee_total_pct = fee_entry_pct + fee_exit_pct
    pnl_net = pnl_gross - fee_total_pct
    
    # 이론 vs 실전 비교 (TB_SNAPSHOT에서 가져옴)
    snap = await get_snapshot(snap_id)
    theo_mfe = snap.mfe_5m if snap.mfe_5m else 0
    theo_mae = snap.mae_5m if snap.mae_5m else 0
    
    execution_gap = pnl_net - (snap.ret_fwd_5m_net or 0)
    
    # 슬리피지 계산
    entry_slippage = abs(entry_price - position.signal_price) / position.signal_price * 100
    exit_slippage = abs(exit_price - exit_signal.price) / exit_signal.price * 100
    
    # trade_vector (25D) 생성
    trade_vector = build_trade_vector(
        similarity=position.similarity,
        signal_strength=position.signal_strength,
        spread_at_entry=snap.bid_ask_spread,
        imbalance_at_entry=snap.ob_imbalance,
        volume_chg_at_entry=snap.volume_chg_1m,
        entry_slippage=entry_slippage,
        exit_slippage=exit_slippage,
        entry_latency=position.entry_latency_ms,
        exit_latency=position.exit_latency_ms,
        fill_ratio=1.0,  # 전량 체결 가정
        pnl_pct=pnl_net,
        hold_time=exit_signal.elapsed,
        real_mfe=exit_signal.mfe,
        real_mae=abs(exit_signal.mae),
        mfe_mae_ratio=exit_signal.mfe / max(abs(exit_signal.mae), 0.001),
        mfe_gap=exit_signal.mfe - theo_mfe,
        mae_gap=abs(exit_signal.mae) - theo_mae,
        pnl_gap=execution_gap,
        latency_impact=entry_slippage + exit_slippage,
        slip_impact=(entry_slippage + exit_slippage) / max(abs(pnl_gross), 0.001),
        regime_enc=encode_regime(snap.regime),
        news_sentiment=snap.news_sentiment,
        vol_at_entry=snap.vol_1m,
        vol_at_exit=current_volatility(),
        trend_strength=snap.ret_5m,
    )
    
    # DB INSERT
    await db.execute("""
        INSERT INTO TB_SIM_TRADE (
            symbol, entry_snap_id, entry_pattern_id, entry_similarity,
            signal_price, entry_price, entry_slippage, entry_latency,
            side, exit_price, exit_reason, exit_slippage, exit_latency,
            pnl_gross, pnl_net, fee_entry, fee_exit, fee_total, fee_impact_pct,
            hold_time_sec, is_win,
            theo_mfe_5m, real_mfe, theo_mae_5m, real_mae, execution_gap,
            fee_entry_rate, fee_exit_rate,
            trade_vector
        ) VALUES (
            :symbol, :snap_id, :pattern_id, :similarity,
            :signal_price, :entry_price, :entry_slip, :entry_latency,
            :side, :exit_price, :exit_reason, :exit_slip, :exit_latency,
            :pnl_gross, :pnl_net, :fee_entry, :fee_exit, :fee_total, :fee_impact,
            :hold_time, :is_win,
            :theo_mfe, :real_mfe, :theo_mae, :real_mae, :exec_gap,
            :fee_entry_rate, :fee_exit_rate,
            VECTOR(:trade_vec, 25, FLOAT32)
        )
    """, params)
    
    # TB_PATTERN 통계 갱신
    await update_pattern_stats(position.pattern_id, pnl_net, is_win)
```

---

## 10. 잔고 관리 (balance_manager.py)

```python
class BalanceManager:
    """
    Testnet 잔고를 추적하고 캐시.
    REST 호출 최소화를 위해 체결 이벤트에서 로컬 갱신.
    """
    
    def __init__(self):
        self.balances = {}       # {"USDT": 10000, "BTC": 0.5, ...}
        self.locked = {}         # 주문 중 잠긴 금액
        self.daily_pnl = 0.0     # 오늘 누적 PnL (%)
        self.daily_trades = 0
        self.daily_wins = 0
        self.last_stop_loss_at = None
    
    async def sync_from_exchange(self):
        """GET /api/v3/account — 전체 잔고 동기화"""
        account = await client.get_account()
        for bal in account["balances"]:
            self.balances[bal["asset"]] = float(bal["free"])
            self.locked[bal["asset"]] = float(bal["locked"])
    
    def get_equity(self, quote="USDT"):
        """총 자산 가치 (USDT 환산)"""
        return self.balances.get(quote, 0) + sum(
            self.balances.get(asset, 0) * get_price(asset + quote)
            for asset in self.balances
            if asset != quote and self.balances[asset] > 0
        )
    
    def update_on_fill(self, side, symbol, qty, price, commission, commission_asset):
        """체결 이벤트에서 로컬 잔고 갱신 (REST 호출 없이)"""
        base, quote = parse_symbol(symbol)  # BTCUSDT → BTC, USDT
        
        if side == "BUY":
            self.balances[base] = self.balances.get(base, 0) + qty
            self.balances[quote] = self.balances.get(quote, 0) - qty * price
        else:
            self.balances[base] = self.balances.get(base, 0) - qty
            self.balances[quote] = self.balances.get(quote, 0) + qty * price
        
        # 수수료 차감
        self.balances[commission_asset] -= commission
    
    def reset_daily(self):
        """매일 00:00 UTC에 호출"""
        self.daily_pnl = 0.0
        self.daily_trades = 0
        self.daily_wins = 0
```

---

## 11. Testnet ↔ 실전 전환

```python
# config.py
import os

TESTNET_MODE = os.getenv("TESTNET_MODE", "1") == "1"

if TESTNET_MODE:
    REST_BASE   = "https://testnet.binance.vision"
    WS_BASE     = "wss://testnet.binance.vision/ws"
    API_KEY     = os.getenv("TESTNET_API_KEY")
    SECRET_KEY  = os.getenv("TESTNET_SECRET_KEY")
else:
    REST_BASE   = "https://api.binance.com"
    WS_BASE     = "wss://stream.binance.com:9443/ws"
    API_KEY     = os.getenv("BINANCE_API_KEY")
    SECRET_KEY  = os.getenv("BINANCE_SECRET_KEY")

# L3 코드는 이 변수들만 참조 → 전환 시 코드 변경 0
```

### 실전 전환 체크리스트

1. `TESTNET_MODE=0` 환경변수 변경
2. 실서버 API Key/Secret 환경변수 설정
3. TB_SYSTEM_CONFIG에서 리스크 파라미터 보수적으로 재설정
   - `RISK_MAX_POSITION_PCT`: 5% → 2%
   - `RISK_MAX_DAILY_LOSS`: 3% → 1.5%
   - `RISK_MAX_OPEN_TRADES`: 3 → 1
4. 첫 1주일: 최소 수량으로 단일 심볼만 거래
5. 모의거래 승률 60% 이상 + 100회 이상 검증 후 전환

---

## 12. 에러 처리 시나리오

| 시나리오 | 처리 방식 |
|---------|----------|
| 주문 API 타임아웃 (-1007) | 3초 후 주문 상태 조회 → 체결/미체결 확인 |
| 잔고 부족 (-2010) | 리스크 게이트에서 사전 차단, 도달 시 로그 후 IDLE |
| 심볼 필터 위반 (-1013) | 수량/가격 재조정 1회 시도, 실패 시 포기 |
| 네트워크 끊김 | 5초 간격 3회 재시도, 실패 시 포지션 보유 상태면 긴급 시장가 청산 |
| WebSocket 연결 끊김 | 자동 재연결 + listenKey 갱신, 재연결 중 REST 폴링 전환 |
| Testnet 리셋 (월 1회) | 잔고 재조회 + 미청산 포지션 초기화 + 로그 기록 |
| 부분 체결 후 취소 | 체결된 수량만큼 포지션 진입, 목표 수량 미달 시 포지션 비율 재계산 |
| 연속 손절 3회 | 쿨다운 3배 적용 (60초 → 180초), 알림 전송 |

---

## 13. REST API 호출 목록

| 용도 | 메서드 | 엔드포인트 | 빈도 |
|------|--------|-----------|------|
| 잔고 조회 | GET | /api/v3/account | 시스템 시작 + 체결 시 |
| 심볼 필터 | GET | /api/v3/exchangeInfo | 시작 시 1회 (1시간 캐시) |
| 호가 조회 | GET | /api/v3/ticker/bookTicker | 주문 직전 |
| 주문 생성 | POST | /api/v3/order | 신호당 1회 |
| 주문 취소 | DELETE | /api/v3/order | 미체결/부분체결 시 |
| 주문 상태 | GET | /api/v3/order | 타임아웃 확인 시 |
| listenKey 발급 | POST | /api/v3/userDataStream | 시작 시 1회 |
| listenKey 갱신 | PUT | /api/v3/userDataStream | 30분마다 |
| 서버 시간 | GET | /api/v3/time | 시작 시 1회 (시간 보정) |
