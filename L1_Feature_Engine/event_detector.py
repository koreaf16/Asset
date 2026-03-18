def detect_events(current_features, rolling_stats, symbol):
    """
    비트마스크를 사용하여 이벤트를 감지합니다.
    """
    flags = 0
    
    # 0: VOL_SURGE (1분 거래량 > 5분 평균 × 2) - 임시 로직
    if current_features.get("volume_1m", 0) > rolling_stats.get("volume_avg_5m", 0) * 2:
        flags |= 1
        
    # 1: OB_SHIFT (imbalance 변화 > 0.4)
    current_imb = current_features.get("ob_imbalance", 0)
    prev_imb = rolling_stats.get("imbalance_prev", current_imb)
    if abs(current_imb - prev_imb) > 0.4:
        flags |= 2
        
    # 2: SPREAD_WIDE (spread > 5분 평균 × 3)
    current_spread = current_features.get("bid_ask_spread", 0)
    spread_avg_5m = rolling_stats.get("spread_avg_5m", current_spread)
    if current_spread > spread_avg_5m * 3:
        flags |= 4
        
    # 3: BB_BREAK (볼린저 밴드 돌파) - 임시 로직
    price = current_features.get("price", 0)
    if price > rolling_stats.get("bb_upper", float('inf')) or price < rolling_stats.get("bb_lower", 0):
        flags |= 8
        
    # 4: NEWS_EVENT (뉴스 감지) - 외부 연동 필요
    # if has_news_event(symbol):
    #     flags |= 16
        
    return flags
