// Fleming WiFi WAN & Uptime Dashboard Engine - ISP1 (ether1) Outage & Throughput Edition
// Strict Asia/Manila (UTC+8) Timezone Normalization + O(1) Batch Ingest

const MANILA_TZ = 'Asia/Manila';
const CACHE_KEY = 'fleming_speedtest_cache_v4';

// Reusable Intl formatter (created once instead of per-call for 50x faster date parsing)
const manilaFormatter = new Intl.DateTimeFormat('en-US', {
  timeZone: MANILA_TZ,
  year: 'numeric',
  month: 'numeric',
  day: 'numeric',
  hour: 'numeric',
  minute: 'numeric',
  second: 'numeric',
  hour12: false
});

function makeManilaDate(year, month, day) {
  return new Date(Date.UTC(year, month, day, 0, 0, 0, 0));
}

function getManilaParts(d) {
  const parts = manilaFormatter.formatToParts(d);
  const map = {};
  for (let i = 0; i < parts.length; i++) {
    map[parts[i].type] = parts[i].value;
  }
  return {
    year: parseInt(map.year, 10),
    month: parseInt(map.month, 10) - 1,
    day: parseInt(map.day, 10),
    hour: parseInt(map.hour === '24' ? '0' : map.hour, 10),
    minute: parseInt(map.minute, 10),
    second: parseInt(map.second, 10)
  };
}

let currentManilaNow = getManilaParts(new Date());
let todayManilaDate = makeManilaDate(currentManilaNow.year, currentManilaNow.month, currentManilaNow.day);

let currentSelectionMode = 'preset'; // 'preset' or 'custom'
let activePreset = '7d'; // '24h', '7d', '14d', '30d'
let outageTableScope = 'range'; // 'range' or 'all30d'
let rangeEndDate = new Date(todayManilaDate.getTime());
let rangeStartDate = new Date(todayManilaDate.getTime() - (6 * 24 * 60 * 60 * 1000));
let calendarCurrentMonth = makeManilaDate(currentManilaNow.year, currentManilaNow.month, 1);

let selectingStartDate = null;
let hoveredDate = null;

let coreRouterLogs = [];
let homeMikroLogs = [];
const seenLogKeys = new Set(); // O(1) deduplication key set: "Device|YYYY-MM-DD HH:MM:SS"
let chartInstance = null;
let initialDateLoaded = false;

// Initialize Dashboard
document.addEventListener('DOMContentLoaded', async () => {
  setupEventListeners();
  setupRangeSelectorListeners();
  setupSynchronizedScrolling();

  // 1. Zero-Latency Render from LocalStorage Cache (0ms)
  const hadCache = loadFromLocalCache();
  if (hadCache) {
    renderCalendar();
    updateDashboard();
  }

  // 2. Fast Incremental Network Sync (logs_index.json + only unseen delta files)
  await syncLatestNetworkLogs(false);

  // Register PWA Service Worker
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('./sw.js').catch(() => {});
  }

  // PWA Install Prompt
  let deferredPrompt;
  const installBtn = document.getElementById('installPwaBtn');
  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault();
    deferredPrompt = e;
    if (installBtn) {
      installBtn.style.display = 'inline-flex';
      installBtn.addEventListener('click', async () => {
        if (deferredPrompt) {
          deferredPrompt.prompt();
          const { outcome } = await deferredPrompt.userChoice;
          if (outcome === 'accepted') installBtn.style.display = 'none';
          deferredPrompt = null;
        }
      });
    }
  });
});

function parseManilaTimestamp(tsStr) {
  if (!tsStr) return new Date();
  const clean = tsStr.trim().replace(' ', 'T');
  const withTz = clean.includes('+') || clean.endsWith('Z') ? clean : `${clean}+08:00`;
  const d = new Date(withTz);
  return isNaN(d.getTime()) ? new Date() : d;
}

// Fast O(1) log insertion (no per-item array sort)
function insertLogEntryFast(entry) {
  if (!entry || !entry.device) return false;
  const rawTs = entry.timestamp || (entry.date && entry.time ? `${entry.date} ${entry.time}` : null);
  if (!rawTs) return false;

  // Normalize key to minute/second
  const dedupKey = `${entry.device}|${rawTs.slice(0, 19)}`;
  if (seenLogKeys.has(dedupKey)) return false;

  const dateObj = parseManilaTimestamp(rawTs);
  const tsMs = dateObj.getTime();
  if (isNaN(tsMs)) return false;

  seenLogKeys.add(dedupKey);

  // Parse speed; for CoreRouter, old script clamped 0 Mbps to 1 Mbps when ether1-ISP1 was down
  let rawSpeed = Number(entry.speed_mbps);
  if (isNaN(rawSpeed) || rawSpeed < 0) rawSpeed = 0;
  if (entry.device === 'CoreRouter' && rawSpeed <= 1) {
    rawSpeed = 0;
  }

  // Fast Manila date extraction directly from ISO YYYY-MM-DD HH:MM:SS when formatted as Manila
  let manilaParts;
  if (/^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}$/.test(rawTs.trim())) {
    const s = rawTs.trim();
    manilaParts = {
      year: parseInt(s.slice(0, 4), 10),
      month: parseInt(s.slice(5, 7), 10) - 1,
      day: parseInt(s.slice(8, 10), 10),
      hour: parseInt(s.slice(11, 13), 10),
      minute: parseInt(s.slice(14, 16), 10),
      second: parseInt(s.slice(17, 19), 10)
    };
  } else {
    manilaParts = getManilaParts(dateObj);
  }

  const item = {
    device: entry.device,
    date: entry.date || rawTs.slice(0, 10),
    time: entry.time || rawTs.slice(11, 19),
    timestamp: rawTs,
    dateObj: dateObj,
    manila: manilaParts,
    dayMs: Date.UTC(manilaParts.year, manilaParts.month, manilaParts.day),
    speed_mbps: Math.round(rawSpeed),
    unit: 'Mbps',
    ping_ms: Number(entry.ping_ms) || (entry.device === 'CoreRouter' ? (rawSpeed === 0 ? 0 : 18) : 1),
    packet_loss: rawSpeed === 0 && entry.device === 'CoreRouter' ? 100 : (Number(entry.packet_loss) || 0),
    target: entry.device === 'CoreRouter'
      ? (rawSpeed === 0 ? 'ether1-ISP1 DOWN (Starlink Backup)' : 'ether1-ISP1 (Primary Fiber)')
      : 'vlan100 (10G Backbone)'
  };

  if (entry.device === 'CoreRouter') {
    coreRouterLogs.push(item);
  } else if (entry.device === 'HomeMikro') {
    homeMikroLogs.push(item);
  }
  return true;
}

function sortAllLogsOnce() {
  coreRouterLogs.sort((a, b) => a.dateObj - b.dateObj);
  homeMikroLogs.sort((a, b) => a.dateObj - b.dateObj);
}

function loadFromLocalCache() {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    if (!raw) return false;
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.length === 0) return false;
    for (let i = 0; i < parsed.length; i++) {
      insertLogEntryFast(parsed[i]);
    }
    sortAllLogsOnce();
    return (coreRouterLogs.length + homeMikroLogs.length) > 0;
  } catch {
    return false;
  }
}

function saveToLocalCache() {
  try {
    // Store compact representation of last 3,000 logs (~45 days) for instant 0ms startup
    const recentCore = coreRouterLogs.slice(-1500).map(l => ({
      device: l.device, date: l.date, time: l.time, speed_mbps: l.speed_mbps
    }));
    const recentHome = homeMikroLogs.slice(-1500).map(l => ({
      device: l.device, date: l.date, time: l.time, speed_mbps: l.speed_mbps
    }));
    localStorage.setItem(CACHE_KEY, JSON.stringify([...recentCore, ...recentHome]));
  } catch {}
}

// Fast Network Sync: 1 CDN request for logs_index.json + only unseen delta files from Git tree
async function syncLatestNetworkLogs(isManualRefresh = false) {
  const refreshBtnText = document.getElementById('refreshBtnText');
  if (isManualRefresh && refreshBtnText) {
    refreshBtnText.innerText = 'Syncing...';
  }

  let addedAny = false;
  const cb = Math.floor(Date.now() / 60000); // 1-minute cache bucket

  // 1. Load compiled logs_index.json (single compressed request)
  try {
    let res = await fetch(`Device Speedtest Logs/logs_index.json?v=${cb}`);
    if (!res.ok) {
      res = await fetch(`https://raw.githubusercontent.com/flemin/Fleming-Wifi-Speedtest/main/Device%20Speedtest%20Logs/logs_index.json?v=${cb}`);
    }
    if (res.ok) {
      let rawText = await res.text();
      if (rawText && rawText.charCodeAt(0) === 0xFEFF) {
        rawText = rawText.slice(1);
      }
      const logs = JSON.parse(rawText);
      if (Array.isArray(logs)) {
        for (let i = 0; i < logs.length; i++) {
          if (insertLogEntryFast(logs[i])) addedAny = true;
        }
      }
    }
  } catch (err) {
    console.warn('logs_index.json fetch note:', err);
  }

  if (addedAny) {
    sortAllLogsOnce();
    if (!initialDateLoaded && currentSelectionMode === 'preset') {
      autoSelectLatestActiveDate();
      initialDateLoaded = true;
    }
    if (selectingStartDate === null) renderCalendar();
    else updateCalendarCellClasses();
    updateDashboard();
  }

  // 2. Check Git Tree for any brand-new log_*.json files pushed since logs_index.json was compiled
  try {
    const treeRes = await fetch(`https://api.github.com/repos/flemin/Fleming-Wifi-Speedtest/git/trees/main?recursive=1&t=${Date.now()}`);
    if (treeRes.ok) {
      const treeData = await treeRes.json();
      if (treeData && Array.isArray(treeData.tree)) {
        // Parse filename "Device Speedtest Logs/CoreRouter/log_2026-11-06_133000.json" to check if already in seenLogKeys!
        const unseenFiles = [];
        const logRegex = /^Device Speedtest Logs\/(CoreRouter|HomeMikro)\/log_(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})(\d{2})\.json$/;

        for (let i = 0; i < treeData.tree.length; i++) {
          const p = treeData.tree[i].path;
          if (!p) continue;
          const m = p.match(logRegex);
          if (!m) continue;
          const dev = m[1];
          const dt = m[2];
          const tm = `${m[3]}:${m[4]}:${m[5]}`;
          const key = `${dev}|${dt} ${tm}`;
          if (!seenLogKeys.has(key)) {
            unseenFiles.push({ path: p, sortKey: `${dt}_${m[3]}${m[4]}${m[5]}` });
          }
        }

        // Only fetch the newest unseen delta files (at most 24 total)
        if (unseenFiles.length > 0) {
          unseenFiles.sort((a, b) => b.sortKey.localeCompare(a.sortKey));
          const toFetch = unseenFiles.slice(0, 24);
          let deltaAdded = false;
          await Promise.all(
            toFetch.map(async (f) => {
              try {
                const fileRes = await fetch(`https://raw.githubusercontent.com/flemin/Fleming-Wifi-Speedtest/main/${encodeURI(f.path)}`);
                if (fileRes.ok) {
                  const item = await fileRes.json();
                  if (insertLogEntryFast(item)) deltaAdded = true;
                }
              } catch {}
            })
          );
          if (deltaAdded) {
            sortAllLogsOnce();
            addedAny = true;
          }
        }
      }
    }
  } catch (err) {
    console.warn('Git tree delta note:', err);
  }

  if (addedAny || isManualRefresh) {
    saveToLocalCache();
    if (selectingStartDate === null) renderCalendar();
    else updateCalendarCellClasses();
    updateDashboard();
  }

  if (refreshBtnText) {
    refreshBtnText.innerText = 'Sync';
  }
}

// Setup Control Event Listeners
function setupEventListeners() {
  document.getElementById('prevMonthBtn').addEventListener('click', () => {
    calendarCurrentMonth.setUTCMonth(calendarCurrentMonth.getUTCMonth() - 1);
    renderCalendar();
  });
  
  document.getElementById('nextMonthBtn').addEventListener('click', () => {
    calendarCurrentMonth.setUTCMonth(calendarCurrentMonth.getUTCMonth() + 1);
    renderCalendar();
  });
  
  document.getElementById('btnToday').addEventListener('click', () => {
    const nowParts = getManilaParts(new Date());
    todayManilaDate = makeManilaDate(nowParts.year, nowParts.month, nowParts.day);
    rangeStartDate = new Date(todayManilaDate.getTime());
    rangeEndDate = new Date(todayManilaDate.getTime());
    calendarCurrentMonth = makeManilaDate(nowParts.year, nowParts.month, 1);
    currentSelectionMode = 'custom';
    selectingStartDate = null;
    hoveredDate = null;
    
    document.querySelectorAll('.range-btn[data-range]').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.quick-days .btn-pill').forEach(b => b.classList.remove('active'));
    document.getElementById('btnToday').classList.add('active');
    
    renderCalendar();
    updateDashboard();
  });
  
  document.getElementById('btnYesterday').addEventListener('click', () => {
    const nowParts = getManilaParts(new Date());
    const yest = new Date(makeManilaDate(nowParts.year, nowParts.month, nowParts.day).getTime() - (24 * 60 * 60 * 1000));
    rangeStartDate = new Date(yest.getTime());
    rangeEndDate = new Date(yest.getTime());
    calendarCurrentMonth = makeManilaDate(yest.getUTCFullYear(), yest.getUTCMonth(), 1);
    currentSelectionMode = 'custom';
    selectingStartDate = null;
    hoveredDate = null;
    
    document.querySelectorAll('.range-btn[data-range]').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.quick-days .btn-pill').forEach(b => b.classList.remove('active'));
    document.getElementById('btnYesterday').classList.add('active');
    
    renderCalendar();
    updateDashboard();
  });
  
  document.getElementById('btnPrevDay').addEventListener('click', () => {
    const daySpan = Math.max(1, Math.round((rangeEndDate.getTime() - rangeStartDate.getTime()) / (86400 * 1000)) + 1);
    const shiftMs = daySpan * 24 * 60 * 60 * 1000;
    rangeStartDate = new Date(rangeStartDate.getTime() - shiftMs);
    rangeEndDate = new Date(rangeEndDate.getTime() - shiftMs);
    calendarCurrentMonth = makeManilaDate(rangeStartDate.getUTCFullYear(), rangeStartDate.getUTCMonth(), 1);
    currentSelectionMode = 'custom';
    selectingStartDate = null;
    hoveredDate = null;
    
    document.querySelectorAll('.range-btn[data-range]').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.quick-days .btn-pill').forEach(b => b.classList.remove('active'));
    
    renderCalendar();
    updateDashboard();
  });
  
  document.getElementById('btnNextDay').addEventListener('click', () => {
    const daySpan = Math.max(1, Math.round((rangeEndDate.getTime() - rangeStartDate.getTime()) / (86400 * 1000)) + 1);
    const shiftMs = daySpan * 24 * 60 * 60 * 1000;
    rangeStartDate = new Date(rangeStartDate.getTime() + shiftMs);
    rangeEndDate = new Date(rangeEndDate.getTime() + shiftMs);
    calendarCurrentMonth = makeManilaDate(rangeEndDate.getUTCFullYear(), rangeEndDate.getUTCMonth(), 1);
    currentSelectionMode = 'custom';
    selectingStartDate = null;
    hoveredDate = null;
    
    document.querySelectorAll('.range-btn[data-range]').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.quick-days .btn-pill').forEach(b => b.classList.remove('active'));
    
    renderCalendar();
    updateDashboard();
  });

  const btnResetRange = document.getElementById('btnResetRange');
  if (btnResetRange) btnResetRange.addEventListener('click', resetToDefaultRange);

  const btnResetChart = document.getElementById('btnResetChart');
  if (btnResetChart) btnResetChart.addEventListener('click', resetToDefaultRange);

  const btnRefreshNow = document.getElementById('btnRefreshNow');
  if (btnRefreshNow) {
    btnRefreshNow.addEventListener('click', () => syncLatestNetworkLogs(true));
  }

  const btnScopeRange = document.getElementById('btnOutageScopeRange');
  const btnScopeAll = document.getElementById('btnOutageScopeAll');
  if (btnScopeRange && btnScopeAll) {
    btnScopeRange.addEventListener('click', () => {
      outageTableScope = 'range';
      btnScopeRange.classList.add('active');
      btnScopeAll.classList.remove('active');
      renderOutageBreakdownSection();
    });
    btnScopeAll.addEventListener('click', () => {
      outageTableScope = 'all30d';
      btnScopeAll.classList.add('active');
      btnScopeRange.classList.remove('active');
      renderOutageBreakdownSection();
    });
  }
}

function applyPreset(rangeKey) {
  currentSelectionMode = 'preset';
  activePreset = rangeKey;
  selectingStartDate = null;
  hoveredDate = null;
  
  const nowParts = getManilaParts(new Date());
  todayManilaDate = makeManilaDate(nowParts.year, nowParts.month, nowParts.day);
  rangeEndDate = new Date(todayManilaDate.getTime());

  if (rangeKey === '24h') {
    rangeStartDate = new Date(todayManilaDate.getTime());
  } else if (rangeKey === '7d') {
    rangeStartDate = new Date(todayManilaDate.getTime() - (6 * 24 * 60 * 60 * 1000));
  } else if (rangeKey === '14d') {
    rangeStartDate = new Date(todayManilaDate.getTime() - (13 * 24 * 60 * 60 * 1000));
  } else if (rangeKey === '30d') {
    rangeStartDate = new Date(todayManilaDate.getTime() - (29 * 24 * 60 * 60 * 1000));
  }
  
  calendarCurrentMonth = makeManilaDate(rangeEndDate.getUTCFullYear(), rangeEndDate.getUTCMonth(), 1);
  updatePresetButtonsUI();
  renderCalendar();
  updateDashboard();
}

function updatePresetButtonsUI() {
  document.querySelectorAll('.range-btn[data-range]').forEach(b => {
    if (currentSelectionMode === 'preset' && b.getAttribute('data-range') === activePreset) {
      b.classList.add('active');
    } else {
      b.classList.remove('active');
    }
  });
  document.querySelectorAll('.quick-days .btn-pill').forEach(b => b.classList.remove('active'));
}

function resetToDefaultRange() {
  applyPreset('7d');
}

function setupRangeSelectorListeners() {
  document.querySelectorAll('.range-btn[data-range]').forEach(btn => {
    btn.addEventListener('click', () => {
      applyPreset(btn.getAttribute('data-range') || '7d');
    });
  });
}

function setupSynchronizedScrolling() {
  const containerLeft = document.getElementById('scrollContainerCore');
  const containerRight = document.getElementById('scrollContainerHome');
  if (!containerLeft || !containerRight) return;
  
  let isSyncingLeft = false;
  let isSyncingRight = false;
  
  containerLeft.addEventListener('scroll', () => {
    if (!isSyncingLeft) {
      isSyncingRight = true;
      containerRight.scrollTop = containerLeft.scrollTop;
    }
    isSyncingLeft = false;
  });
  
  containerRight.addEventListener('scroll', () => {
    if (!isSyncingRight) {
      isSyncingLeft = true;
      containerLeft.scrollTop = containerRight.scrollTop;
    }
    isSyncingRight = false;
  });
}

function autoSelectLatestActiveDate() {
  const allLogs = [...coreRouterLogs, ...homeMikroLogs];
  if (allLogs.length === 0) return;
  
  const nowParts = getManilaParts(new Date());
  const todayMs = Date.UTC(nowParts.year, nowParts.month, nowParts.day);
  const hasToday = allLogs.some(l => l.dayMs === todayMs);
  
  if (!hasToday) {
    const latest = allLogs[allLogs.length - 1];
    if (latest) {
      const topManila = latest.manila;
      todayManilaDate = makeManilaDate(topManila.year, topManila.month, topManila.day);
      rangeEndDate = new Date(todayManilaDate.getTime());
      rangeStartDate = new Date(todayManilaDate.getTime() - (6 * 24 * 60 * 60 * 1000));
      calendarCurrentMonth = makeManilaDate(topManila.year, topManila.month, 1);
    }
  }
}

function formatRelativeTime(dateObj) {
  const now = new Date();
  const diffSec = Math.max(0, Math.floor((now - dateObj) / 1000));
  const diffMin = Math.floor(diffSec / 60);
  const diffHour = Math.floor(diffMin / 60);

  if (diffSec < 45) return 'Just now';
  if (diffMin < 60) return `${diffMin}m ago`;
  if (diffHour < 24) return `${diffHour}h ${diffMin % 60}m ago`;
  return dateObj.toLocaleDateString('en-US', { timeZone: MANILA_TZ, month: 'short', day: 'numeric' });
}

function formatHumanReadableManila(dateObj) {
  return dateObj.toLocaleDateString('en-US', {
    timeZone: MANILA_TZ,
    month: 'short',
    day: 'numeric',
    year: 'numeric'
  }) + ' • ' + dateObj.toLocaleTimeString('en-US', {
    timeZone: MANILA_TZ,
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: true
  }) + ' PHT';
}

function formatDurationMinutes(totalMins) {
  if (totalMins <= 0) return '0 mins';
  const hrs = Math.floor(totalMins / 60);
  const mins = Math.round(totalMins % 60);
  if (hrs === 0) return `${mins} mins`;
  if (mins === 0) return `${hrs} hr${hrs > 1 ? 's' : ''}`;
  return `${hrs}h ${mins}m`;
}

// Color coding: ONLY 0 Mbps is Red (Outage). All > 0 Mbps speeds are Cyan/Emerald!
function getSpeedColorStyle(speed, isCore = true) {
  if (speed === 0 && isCore) {
    return {
      bg: 'rgba(239, 68, 68, 0.22)',
      text: '#fca5a5',
      border: 'rgba(239, 68, 68, 0.55)'
    };
  }
  const ratio = Math.max(0, Math.min(1, speed / 800));
  const lightness = 32 + (ratio * 10);
  return {
    bg: `hsl(152, 65%, ${lightness.toFixed(0)}%)`,
    text: '#ffffff',
    border: 'rgba(16, 185, 129, 0.45)'
  };
}

function handleCalendarDateClick(clickedDate) {
  if (selectingStartDate === null) {
    selectingStartDate = clickedDate;
    rangeStartDate = clickedDate;
    rangeEndDate = clickedDate;
    currentSelectionMode = 'custom';
    hoveredDate = null;

    document.querySelectorAll('.range-btn[data-range]').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.quick-days .btn-pill').forEach(b => b.classList.remove('active'));

    updateCalendarCellClasses();
    updateDashboard();
  } else {
    const d1 = selectingStartDate;
    const d2 = clickedDate;
    rangeStartDate = d1.getTime() <= d2.getTime() ? d1 : d2;
    rangeEndDate = d1.getTime() <= d2.getTime() ? d2 : d1;
    selectingStartDate = null;
    hoveredDate = null;
    currentSelectionMode = 'custom';

    document.querySelectorAll('.range-btn[data-range]').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.quick-days .btn-pill').forEach(b => b.classList.remove('active'));

    updateCalendarCellClasses();
    updateDashboard();
  }
}

function updateCalendarCellClasses() {
  const cells = document.querySelectorAll('#calGrid .cal-day-cell:not(.other-month)');
  if (!cells || cells.length === 0) return;

  const nowParts = getManilaParts(new Date());
  const todayTime = makeManilaDate(nowParts.year, nowParts.month, nowParts.day).getTime();
  const startTime = rangeStartDate.getTime();
  const endTime = rangeEndDate.getTime();

  const loggedDateTimes = new Set();
  const outageDateTimes = new Set();

  for (let i = 0; i < coreRouterLogs.length; i++) {
    const l = coreRouterLogs[i];
    loggedDateTimes.add(l.dayMs);
    if (l.speed_mbps === 0) {
      outageDateTimes.add(l.dayMs);
    }
  }
  for (let i = 0; i < homeMikroLogs.length; i++) {
    loggedDateTimes.add(homeMikroLogs[i].dayMs);
  }

  cells.forEach(cell => {
    const timeAttr = cell.getAttribute('data-time');
    if (!timeAttr) return;
    const cellTime = parseInt(timeAttr, 10);

    cell.classList.remove('range-start', 'range-end', 'range-single', 'in-range', 'in-range-preview', 'selecting-start', 'has-data', 'has-outage');

    if (outageDateTimes.has(cellTime)) {
      cell.classList.add('has-data', 'has-outage');
    } else if (loggedDateTimes.has(cellTime)) {
      cell.classList.add('has-data');
    }

    if (cellTime === todayTime) {
      cell.classList.add('today');
    }

    if (selectingStartDate !== null) {
      const selStartTime = selectingStartDate.getTime();
      if (cellTime === selStartTime) cell.classList.add('selecting-start');

      if (hoveredDate !== null) {
        const hoverTime = hoveredDate.getTime();
        const minH = Math.min(selStartTime, hoverTime);
        const maxH = Math.max(selStartTime, hoverTime);

        if (cellTime === minH && cellTime === maxH) {
          cell.classList.add('range-start', 'range-end', 'range-single');
        } else if (cellTime === minH) {
          cell.classList.add('range-start');
        } else if (cellTime === maxH) {
          cell.classList.add('range-end');
        } else if (cellTime > minH && cellTime < maxH) {
          cell.classList.add('in-range-preview');
        }
      } else if (cellTime === selStartTime) {
        cell.classList.add('range-start', 'range-end', 'range-single');
      }
    } else {
      if (startTime === endTime) {
        if (cellTime === startTime) cell.classList.add('range-start', 'range-end', 'range-single');
      } else {
        if (cellTime === startTime) cell.classList.add('range-start');
        else if (cellTime === endTime) cell.classList.add('range-end');
        else if (cellTime > startTime && cellTime < endTime) cell.classList.add('in-range');
      }
    }
  });

  updateSelectedRangeText();
}

function updateSelectedRangeText() {
  const badge = document.getElementById('selectedDayText');
  if (!badge) return;

  if (selectingStartDate !== null) {
    badge.classList.remove('locked');
    badge.classList.add('selecting');
    const startStr = selectingStartDate.toLocaleDateString('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' });
    badge.innerHTML = `<span>📍</span> <span>Start: <strong>${startStr}</strong> • Click End Date</span>`;
    return;
  }

  badge.classList.remove('selecting');
  badge.classList.add('locked');
  const startStr = rangeStartDate.toLocaleDateString('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' });
  const endStr = rangeEndDate.toLocaleDateString('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' });
  const dayCount = Math.max(1, Math.round((rangeEndDate.getTime() - rangeStartDate.getTime()) / (86400 * 1000)) + 1);

  if (rangeStartDate.getTime() === rangeEndDate.getTime()) {
    badge.innerHTML = `<span>📅</span> <span>Viewing: <strong>${startStr}</strong> (1 Day)</span>`;
  } else {
    badge.innerHTML = `<span>✅</span> <span><strong>${startStr}</strong> &ndash; <strong>${endStr}</strong> (${dayCount} Days)</span>`;
  }
}

let _calGridClickHandler = null;
let _calGridMouseMoveHandler = null;
let _calGridMouseLeaveHandler = null;

function renderCalendar() {
  const monthTitle = document.getElementById('calMonthYear');
  const grid = document.getElementById('calGrid');
  if (!monthTitle || !grid) return;
  
  const monthNames = ["January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"];
                      
  const calYear = calendarCurrentMonth.getUTCFullYear();
  const calMonth = calendarCurrentMonth.getUTCMonth();
  
  monthTitle.innerText = `${monthNames[calMonth]} ${calYear}`;
  
  if (_calGridClickHandler) grid.removeEventListener('click', _calGridClickHandler);
  if (_calGridMouseMoveHandler) grid.removeEventListener('mousemove', _calGridMouseMoveHandler);
  if (_calGridMouseLeaveHandler) grid.removeEventListener('mouseleave', _calGridMouseLeaveHandler);

  grid.innerHTML = '';
  
  const daysOfWeek = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
  daysOfWeek.forEach(day => {
    const header = document.createElement('div');
    header.className = 'cal-day-header';
    header.innerText = day;
    grid.appendChild(header);
  });
  
  const firstDayIndex = new Date(Date.UTC(calYear, calMonth, 1)).getUTCDay();
  const totalDaysInMonth = new Date(Date.UTC(calYear, calMonth + 1, 0)).getUTCDate();
  const prevMonthDays = new Date(Date.UTC(calYear, calMonth, 0)).getUTCDate();
  
  for (let i = firstDayIndex - 1; i >= 0; i--) {
    const cell = document.createElement('div');
    cell.className = 'cal-day-cell other-month';
    cell.innerText = prevMonthDays - i;
    grid.appendChild(cell);
  }

  for (let day = 1; day <= totalDaysInMonth; day++) {
    const cellDate = makeManilaDate(calYear, calMonth, day);
    const cell = document.createElement('div');
    cell.className = 'cal-day-cell';
    cell.innerText = day;
    cell.setAttribute('data-time', cellDate.getTime().toString());
    grid.appendChild(cell);
  }

  _calGridClickHandler = (e) => {
    const cell = e.target.closest('.cal-day-cell');
    if (!cell || cell.classList.contains('other-month')) return;
    const t = parseInt(cell.getAttribute('data-time'), 10);
    if (!isNaN(t)) handleCalendarDateClick(new Date(t));
  };

  _calGridMouseMoveHandler = (e) => {
    if (selectingStartDate === null) return;
    const cell = e.target.closest('.cal-day-cell');
    if (!cell || cell.classList.contains('other-month')) return;
    const t = parseInt(cell.getAttribute('data-time'), 10);
    if (isNaN(t)) return;
    const newHover = new Date(t);
    if (!hoveredDate || hoveredDate.getTime() !== newHover.getTime()) {
      hoveredDate = newHover;
      updateCalendarCellClasses();
    }
  };

  _calGridMouseLeaveHandler = () => {
    if (selectingStartDate !== null && hoveredDate !== null) {
      hoveredDate = null;
      updateCalendarCellClasses();
    }
  };

  grid.addEventListener('click', _calGridClickHandler);
  grid.addEventListener('mousemove', _calGridMouseMoveHandler);
  grid.addEventListener('mouseleave', _calGridMouseLeaveHandler);

  updateCalendarCellClasses();
}

// Compute distinct CoreRouter (ether1-ISP1) Outage Episodes from chronological logs
function computeCoreOutageEpisodes(logsSubset) {
  const episodes = [];
  if (!logsSubset || logsSubset.length === 0) return episodes;

  let currentEp = null;

  for (let i = 0; i < logsSubset.length; i++) {
    const log = logsSubset[i];
    if (log.speed_mbps === 0) {
      if (!currentEp) {
        currentEp = {
          startLog: log,
          lastZeroLog: log,
          endLog: null,
          zeroChecks: 1,
          isOngoing: false
        };
      } else {
        currentEp.lastZeroLog = log;
        currentEp.zeroChecks++;
      }
    } else {
      if (currentEp) {
        currentEp.endLog = log;
        const diffMins = Math.round((log.dateObj.getTime() - currentEp.startLog.dateObj.getTime()) / 60000);
        currentEp.durationMins = Math.max(currentEp.zeroChecks * 30, diffMins);
        episodes.push(currentEp);
        currentEp = null;
      }
    }
  }

  if (currentEp) {
    // Check if this is the very latest log in coreRouterLogs
    const globalLast = coreRouterLogs.length > 0 ? coreRouterLogs[coreRouterLogs.length - 1] : null;
    currentEp.isOngoing = globalLast && (currentEp.lastZeroLog.dateObj.getTime() === globalLast.dateObj.getTime());
    const diffMins = Math.round((currentEp.lastZeroLog.dateObj.getTime() - currentEp.startLog.dateObj.getTime()) / 60000) + 30;
    currentEp.durationMins = Math.max(currentEp.zeroChecks * 30, diffMins);
    episodes.push(currentEp);
  }

  return episodes;
}

// Update All Dashboard Views
function updateDashboard() {
  renderLiveGauges();
  renderExecutiveSummaryMetrics();
  renderAdaptiveTrendChart();
  renderUptimeRibbon();
  renderOutageBreakdownSection();
  renderCongestionHeatmap();
  renderDualTables();
}

function renderLiveGauges() {
  const arcLength = 210;
  
  // 1. CoreRouter Live Gauge (ether1-ISP1)
  const latestCore = coreRouterLogs.length > 0 ? coreRouterLogs[coreRouterLogs.length - 1] : null;
  if (latestCore) {
    const isUp = latestCore.speed_mbps > 0;
    document.getElementById('coreLiveSpeed').innerText = isUp ? latestCore.speed_mbps : '0 (DOWN)';
    const manilaTimeStr = latestCore.dateObj.toLocaleTimeString('en-US', { timeZone: MANILA_TZ, hour: '2-digit', minute:'2-digit' });
    document.getElementById('coreLastTime').innerText = `${formatRelativeTime(latestCore.dateObj)} (${manilaTimeStr} PHT)`;
    
    // Update Header Pill & Card Badge
    const headerPill = document.getElementById('isp1HeaderPill');
    const headerDot = document.getElementById('isp1HeaderDot');
    const headerText = document.getElementById('liveStatusText');
    const wanBadge = document.getElementById('coreWanStateBadge');

    if (isUp) {
      if (headerPill) headerPill.classList.remove('down');
      if (headerDot) headerDot.classList.remove('down');
      if (headerText) headerText.innerText = `ISP1 (ether1) Online • ${latestCore.speed_mbps} Mbps`;
      if (wanBadge) {
        wanBadge.className = 'wan-state-pill online';
        wanBadge.innerText = '🟢 ISP1 (ether1) ONLINE';
      }
    } else {
      if (headerPill) headerPill.classList.add('down');
      if (headerDot) headerDot.classList.add('down');
      if (headerText) headerText.innerText = 'ISP1 (ether1) DOWN • On Starlink Backup';
      if (wanBadge) {
        wanBadge.className = 'wan-state-pill down';
        wanBadge.innerText = '🔴 ISP1 DOWN • STARLINK ACTIVE';
      }
    }

    // 24h Uptime Pill on Core Card
    const last48Core = coreRouterLogs.slice(-48);
    const up48 = last48Core.filter(l => l.speed_mbps > 0).length;
    const pct24h = last48Core.length > 0 ? ((up48 / last48Core.length) * 100).toFixed(1) : '100.0';
    const pingPill = document.getElementById('coreLatencyPill');
    if (pingPill) {
      pingPill.innerText = `🛡️ Last 24h Uptime: ${pct24h}% (${up48}/${last48Core.length})`;
      if (up48 < last48Core.length) pingPill.classList.add('loss');
      else pingPill.classList.remove('loss');
    }

    const speedRatio = Math.min(1, Math.max(0, latestCore.speed_mbps / 1000));
    const offset = arcLength - (speedRatio * arcLength);
    const arcElem = document.getElementById('coreGaugeArc');
    if (arcElem) {
      arcElem.style.strokeDashoffset = offset;
      arcElem.setAttribute('stroke', isUp ? '#38bdf8' : '#ef4444');
    }
  }
  
  // 2. HomeMikro Live Gauge
  const latestHome = homeMikroLogs.length > 0 ? homeMikroLogs[homeMikroLogs.length - 1] : null;
  if (latestHome) {
    document.getElementById('homeLiveSpeed').innerText = latestHome.speed_mbps;
    const manilaTimeStr = latestHome.dateObj.toLocaleTimeString('en-US', { timeZone: MANILA_TZ, hour: '2-digit', minute:'2-digit' });
    document.getElementById('homeLastTime').innerText = `${formatRelativeTime(latestHome.dateObj)} (${manilaTimeStr} PHT)`;
    
    const last48Home = homeMikroLogs.slice(-48);
    const peak24h = last48Home.length > 0 ? Math.max(...last48Home.map(l => l.speed_mbps)) : latestHome.speed_mbps;
    const homePingPill = document.getElementById('homeLatencyPill');
    if (homePingPill) {
      homePingPill.innerText = `⚡ 24h Peak: ${peak24h} Mbps • 1 ms`;
    }

    const speedRatio = Math.min(1, Math.max(0, latestHome.speed_mbps / 1000));
    const offset = arcLength - (speedRatio * arcLength);
    const arcElem = document.getElementById('homeGaugeArc');
    if (arcElem) {
      arcElem.style.strokeDashoffset = offset;
      arcElem.setAttribute('stroke', '#c084fc');
    }
  }
}

// Executive ISP1 (ether1) Uptime & Outage Summary
function renderExecutiveSummaryMetrics() {
  const startMs = rangeStartDate.getTime();
  const endMs = rangeEndDate.getTime();
  const dayCount = Math.max(1, Math.round((endMs - startMs) / (86400 * 1000)) + 1);

  const filteredCore = coreRouterLogs.filter(l => l.dayMs >= startMs && l.dayMs <= endMs);

  const titleElem = document.getElementById('metricsSectionTitle');
  const uptimeLabelElem = document.getElementById('metricUptimeLabel');
  if (titleElem) {
    titleElem.innerText = `${dayCount}-Day ISP1 (ether1) Uptime & Outage Summary`;
  }
  if (uptimeLabelElem) {
    uptimeLabelElem.innerText = `${dayCount}-Day ISP1 Uptime`;
  }
  
  if (filteredCore.length === 0) {
    document.getElementById('metricCompliance').innerText = `100%`;
    document.getElementById('metricComplianceFill').style.width = `100%`;
    document.getElementById('metricComplianceSub').innerText = `No CoreRouter checks in selected range`;
    document.getElementById('metricOutage').innerText = `0 mins`;
    document.getElementById('metricOutageSub').innerText = `0 failed intervals`;
    document.getElementById('metricSlowSpeed').innerText = `0 incidents`;
    document.getElementById('metricIncidentSub').innerText = `Longest outage: 0 mins`;
    document.getElementById('metricAvgSpeed').innerText = `0 Mbps`;
    return;
  }

  const onlineCore = filteredCore.filter(l => l.speed_mbps > 0);
  const downCore = filteredCore.filter(l => l.speed_mbps === 0);

  const uptimePct = ((onlineCore.length / filteredCore.length) * 100).toFixed(1);
  const downPct = (100 - parseFloat(uptimePct)).toFixed(1);

  const episodes = computeCoreOutageEpisodes(filteredCore);
  const totalDowntimeMins = downCore.length * 30;
  const longestMins = episodes.length > 0 ? Math.max(...episodes.map(e => e.durationMins)) : 0;

  const avgOnlineSpeed = onlineCore.length > 0
    ? Math.round(onlineCore.reduce((acc, l) => acc + l.speed_mbps, 0) / onlineCore.length)
    : 0;
  const peakSpeed = onlineCore.length > 0
    ? Math.max(...onlineCore.map(l => l.speed_mbps))
    : 0;

  document.getElementById('metricCompliance').innerText = `${uptimePct}%`;
  document.getElementById('metricComplianceFill').style.width = `${uptimePct}%`;
  document.getElementById('metricComplianceSub').innerText = `${onlineCore.length} Online • ${downCore.length} Down (${downPct}% Outage)`;

  document.getElementById('metricOutage').innerText = formatDurationMinutes(totalDowntimeMins);
  document.getElementById('metricOutageSub').innerText = `${downCore.length} intervals at 0 Mbps (ether1 down)`;

  document.getElementById('metricSlowSpeed').innerText = `${episodes.length} incident${episodes.length === 1 ? '' : 's'}`;
  document.getElementById('metricIncidentSub').innerText = `Longest drop: ${formatDurationMinutes(longestMins)}`;

  document.getElementById('metricAvgSpeed').innerText = `${avgOnlineSpeed} / ${peakSpeed} Mbps`;
  document.getElementById('metricAvgSpeedSub').innerText = `Avg: ${avgOnlineSpeed} Mbps • Peak burst: ${peakSpeed} Mbps`;
}

// Render ISP1 Availability Timeline Ribbon
function renderUptimeRibbon() {
  const bar = document.getElementById('uptimeRibbonBar');
  const meta = document.getElementById('uptimeRibbonMeta');
  if (!bar) return;
  bar.innerHTML = '';

  const startMs = rangeStartDate.getTime();
  const endMs = rangeEndDate.getTime();
  const filteredCore = coreRouterLogs.filter(l => l.dayMs >= startMs && l.dayMs <= endMs);

  if (filteredCore.length === 0) {
    if (meta) meta.innerText = 'No checks in range';
    return;
  }

  const onlineCount = filteredCore.filter(l => l.speed_mbps > 0).length;
  const pct = ((onlineCount / filteredCore.length) * 100).toFixed(1);
  if (meta) {
    meta.innerText = `${pct}% Uptime (${onlineCount}/${filteredCore.length} checks online)`;
    meta.style.color = onlineCount === filteredCore.length ? '#34d399' : '#fca5a5';
  }

  // Decimate into at most 120 visual slices so DOM stays super light
  const maxSlices = 120;
  const step = Math.max(1, Math.ceil(filteredCore.length / maxSlices));

  for (let i = 0; i < filteredCore.length; i += step) {
    const chunk = filteredCore.slice(i, i + step);
    const hasOutage = chunk.some(c => c.speed_mbps === 0);
    const sample = hasOutage ? chunk.find(c => c.speed_mbps === 0) : chunk[0];
    const slice = document.createElement('div');
    slice.className = `ribbon-slice ${hasOutage ? 'down' : 'up'}`;
    slice.title = hasOutage
      ? `🔴 ISP1 OUTAGE (0 Mbps) • ${formatHumanReadableManila(sample.dateObj)}`
      : `🟢 ISP1 ONLINE (${sample.speed_mbps} Mbps) • ${formatHumanReadableManila(sample.dateObj)}`;
    bar.appendChild(slice);
  }
}

// Render Dedicated ISP1 Outage Breakdown Table & Summary Banner
function renderOutageBreakdownSection() {
  const tbody = document.getElementById('tbodyOutageBreakdown');
  const banner = document.getElementById('outageSummaryBanner');
  if (!tbody || !banner) return;

  tbody.innerHTML = '';

  let targetLogs;
  let periodDesc;
  if (outageTableScope === 'all30d') {
    const cutoffDayMs = todayManilaDate.getTime() - (29 * 86400 * 1000);
    targetLogs = coreRouterLogs.filter(l => l.dayMs >= cutoffDayMs);
    periodDesc = 'the last 30 days';
  } else {
    const startMs = rangeStartDate.getTime();
    const endMs = rangeEndDate.getTime();
    targetLogs = coreRouterLogs.filter(l => l.dayMs >= startMs && l.dayMs <= endMs);
    periodDesc = 'the selected date range';
  }

  const episodes = computeCoreOutageEpisodes(targetLogs).reverse(); // Newest first

  if (episodes.length === 0) {
    banner.className = 'outage-summary-banner clean';
    banner.innerHTML = `
      <span>✅ <strong>100% ISP1 (ether1) Availability</strong> — Zero 0 Mbps outages recorded during ${periodDesc}.</span>
      <span>${targetLogs.length} checks verified</span>
    `;
    tbody.innerHTML = `
      <tr>
        <td colspan="6" style="text-align: center; color: #6ee7b7; padding: 1.75rem 1rem; font-weight: 600;">
          🎉 No ISP1 (ether1-ISP1) outages occurred during ${periodDesc}.
        </td>
      </tr>
    `;
    return;
  }

  const totalMins = episodes.reduce((acc, e) => acc + e.durationMins, 0);
  const totalChecks = episodes.reduce((acc, e) => acc + e.zeroChecks, 0);

  banner.className = 'outage-summary-banner has-outages';
  banner.innerHTML = `
    <span>🚨 <strong>${episodes.length} ISP1 (ether1) Outage Incident${episodes.length === 1 ? '' : 's'}</strong> detected in ${periodDesc}</span>
    <span>Total Downtime: <strong>${formatDurationMinutes(totalMins)}</strong> (${totalChecks} failed checks)</span>
  `;

  episodes.forEach(ep => {
    const tr = document.createElement('tr');
    tr.style.cursor = 'pointer';
    tr.title = 'Click to view this date on the chart';

    const statusHtml = ep.isOngoing
      ? `<span class="outage-status-chip ongoing">🔴 ONGOING (ISP1 Down)</span>`
      : `<span class="outage-status-chip resolved">🟢 RESOLVED</span>`;

    const startStr = formatHumanReadableManila(ep.startLog.dateObj);
    const endStr = ep.endLog
      ? formatHumanReadableManila(ep.endLog.dateObj)
      : `${formatHumanReadableManila(ep.lastZeroLog.dateObj)} (Still Down)`;

    const recoveryStr = ep.endLog
      ? `<span class="speed-badge" style="background: hsl(152, 65%, 35%); color: #fff; border: 1px solid rgba(16,185,129,0.45);">${ep.endLog.speed_mbps} Mbps</span>`
      : `<span class="target-badge" style="color: #fca5a5; border-color: rgba(239,68,68,0.4);">On Starlink Backup</span>`;

    tr.innerHTML = `
      <td>${statusHtml}</td>
      <td class="time-cell">${startStr}</td>
      <td class="time-cell">${endStr}</td>
      <td><span class="duration-pill">⏱️ ~${formatDurationMinutes(ep.durationMins)}</span></td>
      <td style="font-family: var(--font-mono); font-weight: 700; color: #fca5a5;">${ep.zeroChecks} check${ep.zeroChecks === 1 ? '' : 's'}</td>
      <td>${recoveryStr}</td>
    `;

    tr.addEventListener('click', () => {
      const d = new Date(ep.startLog.dayMs);
      rangeStartDate = d;
      rangeEndDate = d;
      calendarCurrentMonth = makeManilaDate(d.getUTCFullYear(), d.getUTCMonth(), 1);
      currentSelectionMode = 'custom';
      selectingStartDate = null;
      document.querySelectorAll('.range-btn[data-range]').forEach(b => b.classList.remove('active'));
      renderCalendar();
      updateDashboard();
    });

    tbody.appendChild(tr);
  });
}

// 24-Hour Hourly Availability & Active Usage Profile
function renderCongestionHeatmap() {
  const container = document.getElementById('heatmapGrid');
  if (!container) return;
  container.innerHTML = '';

  const startMs = rangeStartDate.getTime();
  const endMs = rangeEndDate.getTime();

  const targetSource = coreRouterLogs.length > 0 ? coreRouterLogs : homeMikroLogs;
  const filtered = targetSource.filter(l => l.dayMs >= startMs && l.dayMs <= endMs);
  const activeLogs = filtered.length > 0 ? filtered : targetSource;
  
  const hourlyData = Array(24).fill(null).map(() => ({ speeds: [], outages: 0 }));
  activeLogs.forEach(l => {
    const hr = l.manila.hour;
    if (hr >= 0 && hr < 24) {
      hourlyData[hr].speeds.push(l.speed_mbps);
      if (l.speed_mbps === 0) hourlyData[hr].outages++;
    }
  });

  for (let hr = 0; hr < 24; hr++) {
    const cell = document.createElement('div');
    cell.className = 'heatmap-hour-cell';
    
    const slot = hourlyData[hr];
    const speeds = slot.speeds;
    const onlineSpeeds = speeds.filter(s => s > 0);
    const avg = onlineSpeeds.length > 0
      ? Math.round(onlineSpeeds.reduce((a, b) => a + b, 0) / onlineSpeeds.length)
      : (speeds.length > 0 ? 0 : null);
    
    const hrDisplay = hr === 0 ? '12A' : hr < 12 ? `${hr}A` : hr === 12 ? '12P' : `${hr-12}P`;
    
    let bg = 'rgba(255, 255, 255, 0.05)';
    let text = '--';
    let titleText = `Hour ${hr}:00 Manila: No test data recorded`;

    if (avg !== null) {
      if (avg === 0 || slot.outages === speeds.length) {
        text = 'DOWN';
        bg = 'linear-gradient(180deg, #ef4444, #b91c1c)';
        titleText = `Hour ${hr}:00 (${hrDisplay} PHT): ISP1 DOWN (0 Mbps across ${slot.outages} check(s))`;
      } else if (slot.outages > 0) {
        text = `${avg}M*`;
        bg = 'linear-gradient(180deg, #f59e0b, #b45309)';
        titleText = `Hour ${hr}:00 (${hrDisplay} PHT): Avg ${avg} Mbps when up • Had ${slot.outages} outage check(s)`;
      } else {
        text = `${avg}M`;
        bg = avg >= 300
          ? 'linear-gradient(180deg, #0ea5e9, #0284c7)'
          : 'linear-gradient(180deg, #10b981, #059669)';
        titleText = `Hour ${hr}:00 (${hrDisplay} PHT): 100% Online • Avg Active Speed ${avg} Mbps`;
      }
    }

    cell.title = titleText;
    cell.innerHTML = `
      <span class="heatmap-hour-label">${hrDisplay}</span>
      <div class="heatmap-hour-bar" style="background: ${bg};">${text}</div>
    `;

    container.appendChild(cell);
  }
}

// Side-by-Side Dual Tables
function renderDualTables() {
  const tbodyCore = document.getElementById('tbodyCoreRouter');
  const tbodyHome = document.getElementById('tbodyHomeMikro');
  if (!tbodyCore || !tbodyHome) return;
  
  tbodyCore.innerHTML = '';
  tbodyHome.innerHTML = '';
  
  const startMs = rangeStartDate.getTime();
  const endMs = rangeEndDate.getTime();
  
  const filteredCore = coreRouterLogs
    .filter(l => l.dayMs >= startMs && l.dayMs <= endMs)
    .slice()
    .reverse();
  
  const filteredHome = homeMikroLogs
    .filter(l => l.dayMs >= startMs && l.dayMs <= endMs)
    .slice()
    .reverse();

  const coreCountEl = document.getElementById('coreTableCount');
  const homeCountEl = document.getElementById('homeTableCount');
  if (coreCountEl) coreCountEl.innerText = `${filteredCore.length} checks`;
  if (homeCountEl) homeCountEl.innerText = `${filteredHome.length} checks`;
  
  if (filteredCore.length === 0) {
    tbodyCore.innerHTML = `
      <tr>
        <td colspan="3" style="text-align: center; color: #64748b; padding: 2rem 1rem;">
          No CoreRouter logs recorded for the selected date range.
        </td>
      </tr>
    `;
  } else {
    // Cap rendered DOM rows to 250 for instant 60fps scrolling
    const rowsToRender = filteredCore.slice(0, 250);
    const frag = document.createDocumentFragment();
    rowsToRender.forEach((log) => {
      const tr = document.createElement('tr');
      const colorStyle = getSpeedColorStyle(log.speed_mbps, true);
      const label = log.speed_mbps === 0 ? '0 Mbps (DOWN)' : `${log.speed_mbps} Mbps`;
      
      tr.innerHTML = `
        <td class="time-cell">${formatHumanReadableManila(log.dateObj)}</td>
        <td>
          <span class="speed-badge" style="background: ${colorStyle.bg}; color: ${colorStyle.text}; border: 1px solid ${colorStyle.border};">
            ${label}
          </span>
        </td>
        <td><span class="target-badge">${log.target}</span></td>
      `;
      frag.appendChild(tr);
    });
    tbodyCore.appendChild(frag);
  }
  
  if (filteredHome.length === 0) {
    tbodyHome.innerHTML = `
      <tr>
        <td colspan="3" style="text-align: center; color: #64748b; padding: 2rem 1rem;">
          No HomeMikro logs recorded for the selected date range.
        </td>
      </tr>
    `;
  } else {
    const rowsToRender = filteredHome.slice(0, 250);
    const frag = document.createDocumentFragment();
    rowsToRender.forEach((log) => {
      const tr = document.createElement('tr');
      const colorStyle = getSpeedColorStyle(log.speed_mbps, false);
      
      tr.innerHTML = `
        <td class="time-cell">${formatHumanReadableManila(log.dateObj)}</td>
        <td>
          <span class="speed-badge" style="background: ${colorStyle.bg}; color: ${colorStyle.text}; border: 1px solid ${colorStyle.border};">
            ${log.speed_mbps} Mbps
          </span>
        </td>
        <td><span class="target-badge">${log.target}</span></td>
      `;
      frag.appendChild(tr);
    });
    tbodyHome.appendChild(frag);
  }
}

// Adaptive Trend Chart Renderer with Red Outage Point Highlighting & Dynamic 1 Gbps Scale
function renderAdaptiveTrendChart() {
  const canvas = document.getElementById('speedTrendChart');
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  
  const startMs = rangeStartDate.getTime();
  const endMs = rangeEndDate.getTime();
  const dayCount = Math.max(1, Math.round((endMs - startMs) / (86400 * 1000)) + 1);

  const filteredCore = coreRouterLogs.filter(l => l.dayMs >= startMs && l.dayMs <= endMs);
  const filteredHome = homeMikroLogs.filter(l => l.dayMs >= startMs && l.dayMs <= endMs);
  const allFilteredLogs = [...filteredCore, ...filteredHome];

  let bucketMinutes = 30;
  let titleText = `${dayCount}-Day ISP1 Throughput & Outage Trend (30-Min Intervals)`;
  let subtitleText = `Red markers on CoreRouter highlight 0 Mbps ISP1 (ether1) outage intervals`;

  if (currentSelectionMode === 'preset') {
    if (activePreset === '24h') {
      bucketMinutes = 30;
      titleText = '24-Hour ISP1 Throughput & Outage Trend (30-Min Intervals)';
    } else if (activePreset === '7d') {
      bucketMinutes = 30;
      titleText = '7-Day ISP1 Throughput & Outage Trend (30-Min Intervals)';
    } else if (activePreset === '14d') {
      bucketMinutes = 60;
      titleText = '14-Day ISP1 Throughput & Outage Trend (1-Hour Intervals)';
    } else if (activePreset === '30d') {
      bucketMinutes = 120;
      titleText = '30-Day ISP1 Throughput & Outage Trend (2-Hour Intervals)';
    }
  } else {
    if (dayCount <= 7) bucketMinutes = 30;
    else if (dayCount <= 14) bucketMinutes = 60;
    else if (dayCount <= 35) bucketMinutes = 120;
    else bucketMinutes = 1440;
    titleText = `${dayCount}-Day ISP1 Throughput & Outage Trend`;
  }

  const titleElem = document.getElementById('chartTitle');
  const subElem = document.getElementById('chartSubtitle');
  if (titleElem) titleElem.innerText = titleText;
  if (subElem) subElem.innerText = subtitleText;

  if (allFilteredLogs.length === 0) {
    if (chartInstance) chartInstance.destroy();
    chartInstance = null;
    return;
  }

  const buckets = new Map();

  const getBucketInfo = (l) => {
    const m = l.manila;
    let rHour = m.hour;
    let rMin = 0;
    if (bucketMinutes < 60) {
      rMin = Math.floor(m.minute / bucketMinutes) * bucketMinutes;
    } else if (bucketMinutes < 1440) {
      const hpb = bucketMinutes / 60;
      rHour = Math.floor(m.hour / hpb) * hpb;
    } else {
      rHour = 0;
    }
    const sortVal = Date.UTC(m.year, m.month, m.day, rHour, rMin, 0);
    const label = bucketMinutes >= 1440
      ? `${m.month + 1}/${m.day}`
      : `${m.month + 1}/${m.day} ${String(rHour).padStart(2, '0')}:${String(rMin).padStart(2, '0')}`;
    return { sortVal, label };
  };

  for (let i = 0; i < filteredCore.length; i++) {
    const l = filteredCore[i];
    const b = getBucketInfo(l);
    if (!buckets.has(b.sortVal)) {
      buckets.set(b.sortVal, { sortVal: b.sortVal, label: b.label, core: [], home: [], hasCoreZero: false });
    }
    const slot = buckets.get(b.sortVal);
    slot.core.push(l.speed_mbps);
    if (l.speed_mbps === 0) slot.hasCoreZero = true;
  }

  for (let i = 0; i < filteredHome.length; i++) {
    const l = filteredHome[i];
    const b = getBucketInfo(l);
    if (!buckets.has(b.sortVal)) {
      buckets.set(b.sortVal, { sortVal: b.sortVal, label: b.label, core: [], home: [], hasCoreZero: false });
    }
    buckets.get(b.sortVal).home.push(l.speed_mbps);
  }

  const sortedSlots = Array.from(buckets.values()).sort((a, b) => a.sortVal - b.sortVal);
  const labels = sortedSlots.map(s => s.label);
  const coreData = [];
  const homeData = [];
  const corePointColors = [];
  const corePointRadii = [];

  let maxObserved = 600;

  for (let i = 0; i < sortedSlots.length; i++) {
    const s = sortedSlots[i];
    let cVal = null;
    if (s.core.length > 0) {
      // If any check in the bucket was 0 Mbps, preserve 0 so outages are never hidden by averaging!
      cVal = s.hasCoreZero ? 0 : Math.round(s.core.reduce((a, b) => a + b, 0) / s.core.length);
      if (cVal > maxObserved) maxObserved = cVal;
    }
    coreData.push(cVal);
    corePointColors.push(cVal === 0 ? '#ef4444' : '#38bdf8');
    corePointRadii.push(cVal === 0 ? 6 : (labels.length > 150 ? 2 : 3.5));

    let hVal = null;
    if (s.home.length > 0) {
      hVal = Math.round(s.home.reduce((a, b) => a + b, 0) / s.home.length);
      if (hVal > maxObserved) maxObserved = hVal;
    }
    homeData.push(hVal);
  }

  const yMax = maxObserved > 600 ? Math.min(1100, Math.ceil(maxObserved / 100) * 100) : 600;

  if (chartInstance) {
    chartInstance.destroy();
  }
  
  chartInstance = new Chart(ctx, {
    type: 'line',
    data: {
      labels: labels,
      datasets: [
        {
          label: 'CoreRouter (ether1-ISP1 WAN)',
          data: coreData,
          borderColor: '#38bdf8',
          backgroundColor: 'rgba(56, 189, 248, 0.12)',
          borderWidth: 2.5,
          pointRadius: corePointRadii,
          pointHoverRadius: 7,
          pointBackgroundColor: corePointColors,
          pointBorderColor: corePointColors,
          spanGaps: true,
          tension: 0.2,
          fill: true
        },
        {
          label: 'HomeMikro (vlan100 Backbone)',
          data: homeData,
          borderColor: '#c084fc',
          backgroundColor: 'rgba(192, 132, 252, 0.08)',
          borderWidth: 2,
          pointRadius: labels.length > 150 ? 1.5 : 3,
          pointHoverRadius: 6,
          pointBackgroundColor: '#c084fc',
          spanGaps: true,
          tension: 0.2,
          fill: false
        }
      ]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: { duration: 250 },
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: {
          labels: {
            color: '#94a3b8',
            font: { family: 'Inter', size: 12, weight: 600 }
          }
        },
        tooltip: {
          backgroundColor: '#0f172a',
          titleColor: '#38bdf8',
          bodyColor: '#e2e8f0',
          borderColor: 'rgba(255,255,255,0.12)',
          borderWidth: 1,
          padding: 10,
          callbacks: {
            label: function(context) {
              const v = context.parsed.y;
              if (context.datasetIndex === 0 && v === 0) {
                return 'CoreRouter (ether1-ISP1): 0 Mbps — 🔴 ISP1 OUTAGE';
              }
              return `${context.dataset.label}: ${v} Mbps`;
            }
          }
        }
      },
      scales: {
        x: {
          grid: { color: 'rgba(255, 255, 255, 0.04)' },
          ticks: {
            color: '#64748b',
            font: { size: 11 },
            maxRotation: 0,
            autoSkip: true,
            maxTicksLimit: 12
          }
        },
        y: {
          min: 0,
          max: yMax,
          grid: { color: 'rgba(255, 255, 255, 0.06)' },
          ticks: {
            color: '#64748b',
            font: { size: 11 },
            callback: value => `${value}M`
          }
        }
      }
    }
  });
}
