import asyncio
import json
import logging
import websockets
from .stream_normalizer import normalize

log = logging.getLogger(__name__)

# Combined stream을 위한 Base URL (testnet 기준)
# 주의: /ws 가 아니라 기본 도메인 뒤에 /stream?streams= 가 붙어야 합니다.
WS_BASE = "wss://testnet.binance.vision"

async def connect_with_retry(symbols, ring_buffer, max_retries=10):
    retry_delay = 1  # 초기 1초, 최대 60초까지 지수 백오프
    
    for attempt in range(max_retries):
        try:
            # Combined stream URL 생성
            streams = "/".join(f"{s.lower()}@trade/{s.lower()}@depth20@100ms/{s.lower()}@kline_1m" for s in symbols)
            url = f"{WS_BASE}/stream?streams={streams}"
            
            log.info(f"WebSocket 연결 시도 (시도 {attempt+1}): {url}")
            
            async with websockets.connect(url, ping_interval=20) as ws:
                log.info("WebSocket 연결 성공")
                retry_delay = 1  # 연결 성공 시 딜레이 초기화
                
                async for msg in ws:
                    data = json.loads(msg)
                    normalized = normalize(data)
                    
                    if not normalized:
                        continue
                        
                    symbol = normalized["symbol"]
                    
                    if normalized["type"] == "trade":
                        ring_buffer.push_trade(symbol, normalized)
                    elif normalized["type"] == "depth":
                        ring_buffer.push_depth(symbol, normalized)
                    elif normalized["type"] == "kline":
                        ring_buffer.push_kline(symbol, normalized)
                        
        except Exception as e:
            log.warning(f"WS 끊김 (시도 {attempt+1}): {e}")
            await asyncio.sleep(retry_delay)
            retry_delay = min(retry_delay * 2, 60)
            
    log.error("최대 재연결 시도 횟수를 초과했습니다. 시스템을 종료하거나 점검하세요.")
