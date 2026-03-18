import os
import logging
import oracledb
import asyncio

log = logging.getLogger(__name__)

class OracleDBConnector:
    def __init__(self):
        self.pool = None
        # 환경 변수에서 DB 접속 정보 로드
        self.user = os.getenv("DB_USER", "admin")
        self.password = os.getenv("DB_PASSWORD", "password")
        self.dsn = os.getenv("DB_DSN", "localhost:1521/FREEPDB1")
        
    async def initialize(self):
        """비동기 커넥션 풀 초기화"""
        try:
            log.info(f"Oracle DB 커넥션 풀 생성 중... (DSN: {self.dsn})")
            self.pool = oracledb.create_pool_async(
                user=self.user,
                password=self.password,
                dsn=self.dsn,
                min=2,
                max=10,
                increment=1
            )
            log.info("Oracle DB 커넥션 풀 생성 완료.")
        except Exception as e:
            log.error(f"Oracle DB 커넥션 풀 생성 실패: {e}")
            raise

    async def close(self):
        """커넥션 풀 종료"""
        if self.pool:
            await self.pool.close()
            log.info("Oracle DB 커넥션 풀 종료됨.")

    async def execute_query(self, sql, binds=None, fetch_all=True):
        """단순 조회 쿼리 실행"""
        if binds is None:
            binds = {}
            
        async with self.pool.acquire() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(sql, binds)
                if fetch_all:
                    rows = await cursor.fetchall()
                    return rows
                else:
                    row = await cursor.fetchone()
                    return row

    async def execute_insert(self, sql, binds=None):
        """단건 INSERT/UPDATE/DELETE 실행"""
        if binds is None:
            binds = {}
            
        async with self.pool.acquire() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(sql, binds)
                await connection.commit()

    async def execute_many(self, sql, binds_list):
        """다건 INSERT/UPDATE 실행 (배치 처리용)"""
        async with self.pool.acquire() as connection:
            async with connection.cursor() as cursor:
                await cursor.executemany(sql, binds_list)
                await connection.commit()

# 싱글톤 인스턴스로 사용하기 위한 전역 객체
db = OracleDBConnector()
