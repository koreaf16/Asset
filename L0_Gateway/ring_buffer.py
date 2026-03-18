import time
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
        
    def push_kline(self, symbol, kline):
        if symbol not in self.klines:
            self.klines[symbol] = deque(maxlen=100)
        self.klines[symbol].append(kline)
    
    def get_last_price(self, symbol):
        if symbol in self.trades and self.trades[symbol]:
            return self.trades[symbol][-1]["price"]
        return None
    
    def get_trades_window(self, symbol, seconds):
        """직전 N초간의 체결 데이터 반환"""
        if symbol not in self.trades:
            return []
        cutoff = time.time() - seconds
        return [t for t in self.trades[symbol] if t["ts"] >= cutoff]
    
    def get_depth(self, symbol):
        return self.depths.get(symbol)
