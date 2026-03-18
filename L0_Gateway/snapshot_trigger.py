import asyncio
import logging

log = logging.getLogger(__name__)

async def snapshot_loop(ring_buffer, config, l1_engine):
    """매 N초마다 L1에 스냅샷 생성 요청"""
    interval = getattr(config, 'SNAPSHOT_INTERVAL_SEC', 3)  # 기본 3초
    symbols = getattr(config, 'TRADING_SYMBOLS', [])
    
    log.info(f"스냅샷 트리거 시작 (주기: {interval}초, 대상: {symbols})")
    
    while True:
        await asyncio.sleep(interval)
        for symbol in symbols:
            if symbol in ring_buffer.trades and len(ring_buffer.trades[symbol]) > 0:
                try:
                    await l1_engine.process_snapshot(symbol, ring_buffer)
                except Exception as e:
                    log.error(f"[{symbol}] 스냅샷 처리 중 오류 발생: {e}")
