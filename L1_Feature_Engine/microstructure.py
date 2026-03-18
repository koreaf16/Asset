import time

def calculate_microstructure(symbol, ring_buffer):
    """
    Ring Buffer에서 원시 데이터를 읽어 7개의 미시구조 피처를 계산합니다.
    """
    features = {
        "bid_ask_spread": 0.0,
        "ob_imbalance": 0.0,
        "vwap_dev": 0.0,
        "buy_sell_ratio": 0.0,
        "trades_per_sec": 0.0,
        "depth_pressure": 0.0,
        "price_z_score": 0.0 # L1 엔진 레벨에서 normalizer를 통해 계산됨
    }
    
    # 1. 호가창(Depth) 기반 피처
    depth = ring_buffer.get_depth(symbol)
    if depth and depth.get("bids") and depth.get("asks"):
        bids = depth["bids"]
        asks = depth["asks"]
        
        best_bid = bids[0][0]
        best_ask = asks[0][0]
        mid_price = (best_bid + best_ask) / 2.0
        
        if mid_price > 0:
            features["bid_ask_spread"] = (best_ask - best_bid) / mid_price * 100.0
            
        # 상위 5호가 수량 합
        bid_vol_5 = sum(qty for price, qty in bids[:5])
        ask_vol_5 = sum(qty for price, qty in asks[:5])
        
        if (bid_vol_5 + ask_vol_5) > 0:
            features["ob_imbalance"] = (bid_vol_5 - ask_vol_5) / (bid_vol_5 + ask_vol_5)
            
        if ask_vol_5 > 0:
            features["depth_pressure"] = bid_vol_5 / ask_vol_5
            
    # 2. 체결(Trade) 기반 피처
    trades_10s = ring_buffer.get_trades_window(symbol, 10)
    features["trades_per_sec"] = len(trades_10s) / 10.0
    
    trades_30s = ring_buffer.get_trades_window(symbol, 30)
    if trades_30s:
        buy_vol = sum(t["qty"] for t in trades_30s if not t["is_buyer_maker"])
        total_vol = sum(t["qty"] for t in trades_30s)
        if total_vol > 0:
            features["buy_sell_ratio"] = buy_vol / total_vol
            
    trades_60s = ring_buffer.get_trades_window(symbol, 60)
    if trades_60s:
        vol_sum = sum(t["qty"] for t in trades_60s)
        if vol_sum > 0:
            vwap_1m = sum(t["price"] * t["qty"] for t in trades_60s) / vol_sum
            last_price = ring_buffer.get_last_price(symbol)
            if last_price and vwap_1m > 0:
                features["vwap_dev"] = (last_price - vwap_1m) / vwap_1m * 100.0
                
    return features
