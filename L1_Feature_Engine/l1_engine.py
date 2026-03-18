import logging
import numpy as np
from .normalizer import RollingNormalizer
from .microstructure import calculate_microstructure
from .event_detector import detect_events

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
        
    async def process_snapshot(self, symbol, ring_buffer):
        """
        L0의 스냅샷 트리거가 호출하는 메서드.
        35차원 숫자 벡터(num_vector)를 생성하고 이벤트를 감지합니다.
        """
        last_price = ring_buffer.get_last_price(symbol)
        if not last_price:
            return
            
        normalizer = self._get_normalizer(symbol)
        
        # 1. 미시구조 피처 계산
        micro_features = calculate_microstructure(symbol, ring_buffer)
        micro_features["price"] = last_price
        
        # price_z_score 계산
        micro_features["price_z_score"] = normalizer.normalize("price", last_price)
        
        # TODO: window_summary 및 derived_features 계산 로직 추가 필요
        # 현재는 미시구조 7개만 임시로 벡터화
        
        # 2. 이벤트 감지
        if symbol not in self.rolling_stats:
            self.rolling_stats[symbol] = {
                "imbalance_prev": micro_features["ob_imbalance"],
                "spread_avg_5m": micro_features["bid_ask_spread"]
            }
            
        event_flags = detect_events(micro_features, self.rolling_stats[symbol], symbol)
        
        # 상태 업데이트
        self.rolling_stats[symbol]["imbalance_prev"] = micro_features["ob_imbalance"]
        
        # 3. 벡터 조립 (임시 35차원 더미 벡터, 실제로는 35개 피처를 모두 채워야 함)
        vector_list = [
            micro_features["bid_ask_spread"],
            micro_features["ob_imbalance"],
            micro_features["vwap_dev"],
            micro_features["buy_sell_ratio"],
            micro_features["trades_per_sec"],
            micro_features["depth_pressure"],
            micro_features["price_z_score"]
        ]
        # 나머지 28개 차원을 0으로 채움
        vector_list.extend([0.0] * (35 - len(vector_list)))
        num_vector = np.array(vector_list, dtype=np.float32)
        
        log.info(f"[L1 Engine] {symbol} 스냅샷 완료 | 가격: {last_price} | 이벤트 플래그: {event_flags} | 벡터 차원: {len(num_vector)}")
        
        # TODO: Oracle DB TB_SNAPSHOT 비동기 INSERT 로직 추가
        
        return num_vector, micro_features, event_flags
