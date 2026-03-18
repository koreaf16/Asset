// COIN 단타 시스템 — UI 템플릿 (최종)
// 문서: 11_UI_SPEC.md 참조
// 구조: 대시보드 (포트폴리오+차트+거래내역) + 벡터 탐색기 (목록+상세+차트)
// 데이터: Mock → Oracle REST API로 교체

// [NOTE] 이 파일의 전체 소스(~500줄)는 대화 중 아티팩트로 생성되었습니다.
// 아래는 핵심 컴포넌트 구조와 인터페이스 명세입니다.
// 실제 실행 가능한 코드는 대화의 coin_dashboard.jsx 아티팩트를 사용하세요.

import { useState, useEffect, useMemo } from "react";

// ═══ COMPONENT STRUCTURE ═══
//
// App
//  ├─ Header: COIN 로고, TESTNET 뱃지, LIVE 표시, 탭 네비게이션, 상태표시등(L0~GPU)
//  ├─ DashboardPage
//  │   ├─ Left Column
//  │   │   ├─ PortfolioCard: 투입금, 현재가치, 손익 (거래중 테두리 주황색)
//  │   │   ├─ StatsGrid: 거래횟수, 승률, 수수료, 평균보유
//  │   │   └─ FREDPanel: 8개 거시지표 + 레짐 판단
//  │   ├─ Right Column
//  │   │   ├─ MainChart: 가격차트 + 거래마커 (activeTrade 시 자동 LIVE 전환)
//  │   │   ├─ LiveBar: 패턴ID, 유사도, 진입가, 현재가, PnL, SL/TP (거래중만)
//  │   │   └─ TradeTable: 거래내역 (LIVE 행 최상단, 완료 거래 아래)
//  │   └─ IndicatorBar: 레짐, BTC가격, 패턴수, 스냅샷수, 가동시간, 뉴스감성
//  └─ VectorExplorer
//      ├─ FilterBar: 정렬, 라벨필터, 이벤트체크, 날짜/시간 범위
//      ├─ StatsRow: 결과수, 매수적합, 매도적합, 관망, 미라벨, 평균순수익, 최고순수익
//      ├─ Content (grid)
//      │   ├─ SnapList: 스냅샷 목록 (정렬, 클릭 선택)
//      │   └─ DetailPanel: 상황벡터 바차트 + 결과벡터 + 수수료 + 패턴매칭
//      └─ SnapChart: 선택 스냅샷 중심 ±35캔들 차트, MFE/MAE 라인, 관측윈도우

// ═══ DATA INTERFACES ═══

/*
// Dashboard API
GET /api/dashboard → {
  portfolio: { invested, current, pnl, pnlPct },
  active_trade: { id, symbol, side, entryIdx, entryPrice, similarity, patternId } | null,
  trades: [{ id, symbol, side, entryPrice, exitPrice, pnlNet, fee, isWin, holdSec, similarity, ts }],
  prices: [number],  // 최근 180개 가격
  fred: { FEDFUNDS, DGS10, DGS2, STLFSI4, ... },
  regime: "RISK_ON" | "NEUTRAL" | "RISK_OFF",
  metrics: { activePatterns, todaySnapshots, uptime, newsSentiment }
}

// Live WebSocket
WS /ws/live → {
  type: "price",       data: { symbol, price, ts }
  type: "trade_open",  data: { id, symbol, side, entryPrice, patternId, similarity }
  type: "trade_close", data: { id, exitPrice, pnlNet, exitReason }
  type: "snapshot",    data: { snap_id, event_flags }
}

// Vector Explorer API
GET /api/snapshots?sort=ret_desc&label=BUY_GOOD&event_only=true&from=...&to=...&limit=80 → {
  snapshots: [{
    snap_id, priceIdx, ts, price, label,
    spread, imbalance, vwap_dev, buy_sell_ratio, trades_per_sec,
    ret_fwd_5m_net, mfe_5m, mae_5m, mfe_mae_ratio,
    event_flags, similarity, patternId, regime
  }],
  stats: { total, buy, sell, hold, unlabeled, avgRet, bestRet }
}

GET /api/snapshots/{snap_id}/chart?window=35 → {
  prices: [number],  // lo~hi 범위 가격
  lo, hi, ci,        // 인덱스 범위
  snaps_in_window: [{snap_id, priceIdx, price, label, event_flags}],
  mfe_price, mae_price
}
*/

// ═══ KEY BEHAVIORS ═══
//
// 1. 거래 자동 전환:
//    - activeTrade !== null → 차트 주황색, LIVE 뱃지, 진입선 표시
//    - activeTrade === null → 차트 파란색, 일반 모드
//    - 전환은 L3 상태에 의해 자동 (수동 버튼 없음)
//
// 2. 벡터 탐색기 차트:
//    - 목록에서 스냅샷 클릭 → 하단에 SnapChart 펼침
//    - SnapChart: 선택 지점 주황색 마커 + MFE/MAE 점선 + 관측윈도우 배경
//    - 우측 DetailPanel: 상황벡터 바차트 + 결과벡터 수치 + 수수료 차감
//
// 3. 정렬:
//    - 기본: 순수익 높은순 (가장 수익 좋은 스냅샷 최상단)
//    - 옵션: 순수익 낮은순, MFE/MAE순, 유사도순, 최신순

export default function App() {
  return (
    <div style={{ fontFamily: '"JetBrains Mono",monospace', color: "#ccc", background: "#0a0a0f", padding: 20 }}>
      <h2 style={{ color: "#e2e2e2", marginBottom: 8 }}>COIN 단타 시스템 — UI 템플릿</h2>
      <p style={{ color: "#666", fontSize: 13, lineHeight: 1.7 }}>
        이 파일은 UI 구조 명세입니다.<br/>
        실행 가능한 전체 코드는 대화 중 생성된 아티팩트(coin_dashboard.jsx)를 사용하세요.<br/>
        데이터 인터페이스는 위 주석의 API 스펙을 참조하여 Oracle REST API로 연결합니다.<br/><br/>
        <span style={{ color: "#f59e0b" }}>문서 참조: 11_UI_SPEC.md</span>
      </p>
    </div>
  );
}
