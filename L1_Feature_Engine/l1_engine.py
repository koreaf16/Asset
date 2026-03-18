import logging
import numpy as np
import math
import json
from .normalizer import RollingNormalizer
from .microstructure import calculate_microstructure
from .event_detector import detect_events
from database.db_connector import db

log = logging.getLogger(__name__)

class L1Engine:
    def __init__(self, config):
        self.config = config
        self.normalizers = {} # {symbol: RollingNormalizer}
        self.rolling_stats = {} # {symbol: dict}
        
    def _get_normalizer(self, symbol):
        if symbol not in self.normalizers:
            self.normalizers[symbol] = RollingNormalizer()
        return self.normalizers[symbol]

    def _calc_window_features(self, symbol, ring_buffer, window_sec):
        """특정 시간 윈도우(1분, 5분, 15분)에 대한 6개 피처 계산"""
        trades = ring_buffer.get_trades_window(symbol, window_sec)
        prev_trades = ring_buffer.get_trades_window(symbol, window_sec * 2)
        # prev_trades에서 현재 윈도우에 해당하는 부분 제외
        prev_trades = [t for t in prev_trades if t not in trades]

        if not trades:
            return [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

        prices = [t["price"] for t in trades]
        volumes = [t["qty"] for t in trades]
        
        current_price = prices[-1]
        start_price = prices[0]
        high_price = max(prices)
        low_price = min(prices)
        
        # 1. ret (수익률)
        ret = (current_price - start_price) / start_price * 100.0 if start_price > 0 else 0.0
        
        # 2. vol (변동성 - 표준편차)
        vol = float(np.std(prices)) if len(prices) > 1 else 0.0
        
        # 3. volume_chg (거래량 변화율)
        current_vol_sum = sum(volumes)
        prev_vol_sum = sum(t["qty"] for t in prev_trades)
        volume_chg = (current_vol_sum - prev_vol_sum) / prev_vol_sum if prev_vol_sum > 0 else 0.0
        
        # 4. high_low_range (고저 범위)
        hl_range = (high_price - low_price) / low_price * 100.0 if low_price > 0 else 0.0
        
        # 5. close_position (종가 위치 0~1)
        close_pos = (current_price - low_price) / (high_price - low_price) if high_price != low_price else 0.5
        
        # 6. tick_count (체결 건수)
        tick_count = float(len(trades))

        return [ret, vol, volume_chg, hl_range, close_pos, tick_count]
        
    async def process_snapshot(self, symbol, ring_buffer):
        """
        L0의 스냅샷 트리거가 호출하는 메서드.
        35차원 숫자 벡터(num_vector)를 생성하고 DB에 저장합니다.
        """
        last_price = ring_buffer.get_last_price(symbol)
        if not last_price:
            return
            
        normalizer = self._get_normalizer(symbol)
        
        # 1. 미시구조 피처 계산 [0-6]
        micro_features = calculate_microstructure(symbol, ring_buffer)
        micro_features["price"] = last_price
        micro_features["price_z_score"] = normalizer.normalize("price", last_price)
        
        # 2. 윈도우 피처 계산 [7-24]
        win_1m = self._calc_window_features(symbol, ring_buffer, 60)
        win_5m = self._calc_window_features(symbol, ring_buffer, 300)
        win_15m = self._calc_window_features(symbol, ring_buffer, 900)
        
        # 3. 거시 컨텍스트 (임시 기본값) [25-29]
        # 실제로는 TB_MACRO_REGIME 등에서 주기적으로 읽어와 캐싱해두어야 함
        macro_features = [
            0.0,  # regime_enc (neutral=0)
            0.0,  # news_sentiment
            0.0,  # btc_dom_chg
            0.0,  # dgs_spread
            0.0   # stlfsi
        ]
        
        # 4. 파생 지표 계산 [30-34]
        momentum_1m = win_1m[0] * 2.0  # 임시 가속도 계산
        momentum_5m = win_5m[0] * 2.0
        
        # RSI 14 (간단한 근사치)
        rsi_14 = 0.5
        if win_15m[0] > 0: rsi_14 = 0.7
        elif win_15m[0] < 0: rsi_14 = 0.3
            
        vol_ratio_1m5m = win_1m[1] / win_5m[1] if win_5m[1] > 0 else 1.0
        spread_z_score = normalizer.normalize("spread", micro_features["bid_ask_spread"])
        
        derived_features = [momentum_1m, momentum_5m, rsi_14, vol_ratio_1m5m, spread_z_score]
        
        # 5. 이벤트 감지
        if symbol not in self.rolling_stats:
            self.rolling_stats[symbol] = {
                "imbalance_prev": micro_features["ob_imbalance"],
                "spread_avg_5m": micro_features["bid_ask_spread"]
            }
            
        event_flags = detect_events(micro_features, self.rolling_stats[symbol], symbol)
        self.rolling_stats[symbol]["imbalance_prev"] = micro_features["ob_imbalance"]
        
        # 6. 35차원 벡터 조립
        vector_list = [
            micro_features["bid_ask_spread"],
            micro_features["ob_imbalance"],
            micro_features["vwap_dev"],
            micro_features["buy_sell_ratio"],
            micro_features["trades_per_sec"],
            micro_features["depth_pressure"],
            micro_features["price_z_score"]
        ] + win_1m + win_5m + win_15m + macro_features + derived_features
        
        num_vector = np.array(vector_list, dtype=np.float32)
        
        log.info(f"[L1 Engine] {symbol} 스냅샷 완료 | 가격: {last_price} | 이벤트: {event_flags} | 벡터 차원: {len(num_vector)}")
        
        # 7. Oracle DB TB_SNAPSHOT 비동기 INSERT
        try:
            # oracledb 벡터 바인딩을 위해 리스트 형태로 변환
            vector_str = json.dumps(vector_list)
            
            sql = """
                INSERT INTO TB_SNAPSHOT (
                    ts, symbol, price, bid_ask_spread, ob_imbalance, vwap_dev, 
                    buy_sell_ratio, trades_per_sec, depth_pressure, event_flags, num_vector
                ) VALUES (
                    SYSTIMESTAMP, :symbol, :price, :spread, :imb, :vwap, 
                    :bs_ratio, :tps, :dp, :flags, :vec
                )
            """
            binds = {
                "symbol": symbol,
                "price": last_price,
                "spread": micro_features["bid_ask_spread"],
                "imb": micro_features["ob_imbalance"],
                "vwap": micro_features["vwap_dev"],
                "bs_ratio": micro_features["buy_sell_ratio"],
                "tps": micro_features["trades_per_sec"],
                "dp": micro_features["depth_pressure"],
                "flags": event_flags,
                "vec": vector_str
            }
            
            if db.pool is not None:
                await db.execute_insert(sql, binds)
                
        except Exception as e:
            log.error(f"[L1 Engine] DB INSERT 실패 ({symbol}): {e}")
            
        return num_vector, micro_features, event_flags
