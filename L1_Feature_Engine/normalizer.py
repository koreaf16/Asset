import numpy as np
from collections import deque

class RollingNormalizer:
    """직전 1시간 (1200개 스냅샷, 3초 간격) 기준 z-score 정규화"""
    def __init__(self, window=1200):
        self.window = window
        self.history = {}  # {feature_name: deque(maxlen=window)}
    
    def normalize(self, feature_name, value):
        if feature_name not in self.history:
            self.history[feature_name] = deque(maxlen=self.window)
        
        self.history[feature_name].append(value)
        
        # 초기 워밍업 기간 (30개 스냅샷 = 90초) 동안은 0.0 반환
        if len(self.history[feature_name]) < 30:
            return 0.0
        
        arr = np.array(self.history[feature_name])
        mean, std = arr.mean(), arr.std()
        
        if std < 1e-10:
            return 0.0
            
        return float((value - mean) / std)
