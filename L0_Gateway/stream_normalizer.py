def normalize(data):
    """
    Binance WebSocket Combined Stream 데이터를 정규화합니다.
    """
    if "stream" not in data or "data" not in data:
        return None
        
    stream_name = data["stream"]
    payload = data["data"]
    event_type = payload.get("e")
    
    # Trade 이벤트 정규화
    if event_type == "trade":
        return {
            "type": "trade",
            "symbol": payload.get("s"),
            "ts": payload.get("T", 0) / 1000.0,  # ms to seconds
            "price": float(payload.get("p", 0)),
            "qty": float(payload.get("q", 0)),
            "is_buyer_maker": payload.get("m", False),
            "trade_id": payload.get("t")
        }
        
    # Depth 이벤트 정규화 (depth20@100ms는 event_type이 없을 수 있음)
    elif "bids" in payload and "asks" in payload:
        # 부분 호가창(Partial Book Depth) 스트림 처리
        symbol = stream_name.split('@')[0].upper()
        return {
            "type": "depth",
            "symbol": symbol,
            "ts": payload.get("T", 0) / 1000.0 if "T" in payload else None,
            "bids": [[float(price), float(qty)] for price, qty in payload.get("bids", [])],
            "asks": [[float(price), float(qty)] for price, qty in payload.get("asks", [])]
        }
        
    # Kline 이벤트 정규화
    elif event_type == "kline":
        kline = payload.get("k", {})
        return {
            "type": "kline",
            "symbol": payload.get("s"),
            "ts": kline.get("t", 0) / 1000.0,
            "open": float(kline.get("o", 0)),
            "high": float(kline.get("h", 0)),
            "low": float(kline.get("l", 0)),
            "close": float(kline.get("c", 0)),
            "volume": float(kline.get("v", 0)),
            "is_closed": kline.get("x", False)
        }
        
    return None
