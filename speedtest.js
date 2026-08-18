// Fleming WiFi Speedtest Dashboard Engine - Strict Manila (UTC+8) Timezone Edition

const MANILA_TZ = 'Asia/Manila';

// Helper: Get Manila date components for any date
function getManilaParts(d) {
  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: MANILA_TZ,
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
    hour: 'numeric',
    minute: 'numeric',
    second: 'numeric',
    hour12: false
  });
  const parts = formatter.formatToParts(d);
  const map = {};
  parts.forEach(p => map[p.type] = p.value);
  return {
    year: parseInt(map.year, 10),
    month: parseInt(map.month, 10) - 1, // 0-indexed
    day: parseInt(map.day, 10),
    hour: parseInt(map.hour === '24' ? '0' : map.hour, 10),
    minute: parseInt(map.minute, 10),
    second: parseInt(map.second, 10)
  };
}

// Current Manila Date initialization
let currentManilaNow = getManilaParts(new Date());
let selectedDate = new Date(Date.UTC(currentManilaNow.year, currentManilaNow.month, currentManilaNow.day, 12, 0, 0));
let calendarCurrentMonth = new Date(Date.UTC(currentManilaNow.year, currentManilaNow.month, 1, 12, 0, 0));

let coreRouterLogs = [];
let homeMikroLogs = [];
let chartInstance = null;
let initialDateLoaded = false;
let currentChartRange = '7d'; // '24h', '7d', '14d', '30d'

// Initialize Dashboard
document.addEventListener('DOMContentLoaded', async () => {
  setupEventListeners();
  setupRangeSelectorListeners();
  
  // 1. Instant Render: Fetch latest.json first (Instant < 50ms)
  await loadInstantLatestData();
  renderCalendar();
  updateDashboard();
  setupSynchronizedScrolling();

  // 2. Fast Async Fetch: Load recent historical log files in parallel background
  loadHistoricalDataAsync().then(() => {
    if (!initialDateLoaded) {
      autoSelectLatestActiveDate();
      initialDateLoaded = true;
      renderCalendar();
    }
    updateDashboard();
  });

  // Register PWA Service Worker for Mobile / Offline support
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('./sw.js').catch(err => {
      console.log('SW registration note:', err);
    });
  }

  // PWA Install Prompt Handler
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
          if (outcome === 'accepted') {
            installBtn.style.display = 'none';
          }
          deferredPrompt = null;
        }
      });
    }
  });

  window.addEventListener('appinstalled', () => {
    if (installBtn) installBtn.style.display = 'none';
  });
});

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
    selectedDate = new Date(Date.UTC(nowParts.year, nowParts.month, nowParts.day, 12, 0, 0));
    calendarCurrentMonth = new Date(Date.UTC(nowParts.year, nowParts.month, 1, 12, 0, 0));
    renderCalendar();
    updateDashboard();
  });
  
  document.getElementById('btnYesterday').addEventListener('click', () => {
    selectedDate.setUTCDate(selectedDate.getUTCDate() - 1);
    calendarCurrentMonth = new Date(Date.UTC(selectedDate.getUTCFullYear(), selectedDate.getUTCMonth(), 1, 12, 0, 0));
    renderCalendar();
    updateDashboard();
  });
  
  document.getElementById('btnPrevDay').addEventListener('click', () => {
    selectedDate.setUTCDate(selectedDate.getUTCDate() - 1);
    calendarCurrentMonth = new Date(Date.UTC(selectedDate.getUTCFullYear(), selectedDate.getUTCMonth(), 1, 12, 0, 0));
    renderCalendar();
    updateDashboard();
  });
  
  document.getElementById('btnNextDay').addEventListener('click', () => {
    selectedDate.setUTCDate(selectedDate.getUTCDate() + 1);
    calendarCurrentMonth = new Date(Date.UTC(selectedDate.getUTCFullYear(), selectedDate.getUTCMonth(), 1, 12, 0, 0));
    renderCalendar();
    updateDashboard();
  });
}

// Synchronized Table Scrolling
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

// Auto-select latest active date in Manila timezone
function autoSelectLatestActiveDate() {
  const allLogs = [...coreRouterLogs, ...homeMikroLogs];
  if (allLogs.length === 0) return;
  
  const nowParts = getManilaParts(new Date());
  const todayLogs = allLogs.filter(l => 
    l.manila.year === nowParts.year &&
    l.manila.month === nowParts.month &&
    l.manila.day === nowParts.day
  );
  
  if (todayLogs.length === 0) {
    const sorted = [...allLogs].sort((a, b) => b.dateObj - a.dateObj);
    if (sorted[0]) {
      const topManila = sorted[0].manila;
      selectedDate = new Date(Date.UTC(topManila.year, topManila.month, topManila.day, 12, 0, 0));
      calendarCurrentMonth = new Date(Date.UTC(topManila.year, topManila.month, 1, 12, 0, 0));
    }
  }
}

// 1. Instant Load from CDN latest.json (0-50ms)
async function loadInstantLatestData() {
  try {
    const cb = Date.now();
    const [resCore, resHome] = await Promise.all([
      fetch(`Device Speedtest Logs/CoreRouter/latest.json?t=${cb}`),
      fetch(`Device Speedtest Logs/HomeMikro/latest.json?t=${cb}`)
    ]);
    
    if (resCore.ok) {
      const dataCore = await resCore.json();
      insertLogEntry(dataCore);
    }
    if (resHome.ok) {
      const dataHome = await resHome.json();
      insertLogEntry(dataHome);
    }
  } catch (err) {
    console.warn("Could not load relative latest.json:", err);
  }
}

// Helper: Parse RouterOS timestamp strictly as Manila Time (UTC+8)
function parseManilaTimestamp(tsStr) {
  if (!tsStr) return new Date();
  const clean = tsStr.trim().replace(' ', 'T');
  // If no timezone offset present, append Manila (+08:00)
  const withTz = clean.includes('+') || clean.endsWith('Z') ? clean : `${clean}+08:00`;
  const d = new Date(withTz);
  return isNaN(d.getTime()) ? new Date() : d;
}

// Helper: Insert single log entry avoiding duplicates
function insertLogEntry(entry) {
  if (!entry || !entry.device) return;
  const rawTs = entry.timestamp || (entry.date && entry.time ? `${entry.date} ${entry.time}` : null);
  const dateObj = parseManilaTimestamp(rawTs);
  const manilaParts = getManilaParts(dateObj);
  
  const item = {
    device: entry.device,
    timestamp: rawTs || entry.timestamp,
    dateObj: dateObj,
    manila: manilaParts,
    speed_mbps: Number(entry.speed_mbps) || 0,
    unit: entry.unit || 'Mbps',
    ping_ms: Number(entry.ping_ms) || (entry.device === 'CoreRouter' ? 18 : 1),
    packet_loss: Number(entry.packet_loss) || 0,
    target: entry.target || (entry.device === 'CoreRouter' ? 'Manila Cloudflare CDN' : 'Backbone Transit')
  };

  const targetArray = entry.device === 'CoreRouter' ? coreRouterLogs : homeMikroLogs;
  const exists = targetArray.some(l => l.dateObj.getTime() === dateObj.getTime());
  if (!exists) {
    targetArray.push(item);
    targetArray.sort((a, b) => a.dateObj - b.dateObj);
  }
}

// 2. High-Speed Parallel Background Fetch for Historical Logs
async function loadHistoricalDataAsync() {
  const repoOwner = 'flemin';
  const repoName = 'Fleming-Wifi-Speedtest';
  const devices = ['CoreRouter', 'HomeMikro'];

  const cacheKey = 'fleming_speedtest_logs_v2';
  const cached = sessionStorage.getItem(cacheKey);
  if (cached) {
    try {
      const parsed = JSON.parse(cached);
      if (Array.isArray(parsed) && parsed.length > 0) {
        parsed.forEach(insertLogEntry);
      }
    } catch {}
  }

  const fetchPromises = devices.map(async (dev) => {
    try {
      const url = `https://api.github.com/repos/${repoOwner}/${repoName}/contents/Device%20Speedtest%20Logs/${dev}`;
      const res = await fetch(url);
      if (!res.ok) return [];

      const files = await res.json();
      if (!Array.isArray(files)) return [];

      const jsonFiles = files.filter(f => f.name.endsWith('.json') && !f.name.includes('test')).slice(-30);

      const fileContents = await Promise.all(
        jsonFiles.map(async (file) => {
          try {
            const contentRes = await fetch(file.download_url);
            if (contentRes.ok) return await contentRes.json();
          } catch {}
          return null;
        })
      );

      return fileContents.filter(Boolean);
    } catch (e) {
      console.error(`Error fetching logs for ${dev}:`, e);
      return [];
    }
  });

  const results = await Promise.all(fetchPromises);
  const allFetched = results.flat();
  allFetched.forEach(insertLogEntry);

  try {
    sessionStorage.setItem(cacheKey, JSON.stringify([...coreRouterLogs, ...homeMikroLogs]));
  } catch {}
}

function formatRelativeTime(dateObj) {
  const now = new Date();
  const diffMs = now - dateObj;
  const diffSec = Math.floor(diffMs / 1000);
  const diffMin = Math.floor(diffSec / 60);
  const diffHour = Math.floor(diffMin / 60);

  if (diffSec < 45) return 'Just now';
  if (diffMin < 60) return `${diffMin} min${diffMin === 1 ? '' : 's'} ago`;
  if (diffHour < 24) return `${diffHour} hr${diffHour === 1 ? '' : 's'} ago`;
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
  }) + ' (PHT)';
}

function getSpeedColorStyle(speed) {
  if (speed < 200) {
    const ratio = Math.max(0, Math.min(1, speed / 200));
    const saturation = 85 - (ratio * 60);
    const lightness = 42 + (ratio * 8);
    const opacity = 0.85 + (1 - ratio) * 0.15;
    
    return {
      bg: `hsl(0, ${saturation.toFixed(1)}%, ${lightness.toFixed(1)}%)`,
      text: '#ffffff',
      border: `rgba(239, 68, 68, ${opacity.toFixed(2)})`
    };
  } else {
    const ratio = Math.max(0, Math.min(1, (speed - 200) / 800));
    const saturation = 25 + (ratio * 65);
    const lightness = 35 + (ratio * 12);
    
    return {
      bg: `hsl(142, ${saturation.toFixed(1)}%, ${lightness.toFixed(1)}%)`,
      text: '#ffffff',
      border: `rgba(16, 185, 129, 0.4)`
    };
  }
}

// Graphical Calendar Renderer (Strict Manila Timezone)
function renderCalendar() {
  const monthTitle = document.getElementById('calMonthYear');
  const grid = document.getElementById('calGrid');
  if (!monthTitle || !grid) return;
  
  const monthNames = ["January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"];
                      
  const calYear = calendarCurrentMonth.getUTCFullYear();
  const calMonth = calendarCurrentMonth.getUTCMonth();
  
  monthTitle.innerText = `${monthNames[calMonth]} ${calYear}`;
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
  
  const manilaToday = getManilaParts(new Date());
  const selYear = selectedDate.getUTCFullYear();
  const selMonth = selectedDate.getUTCMonth();
  const selDay = selectedDate.getUTCDate();
  
  for (let day = 1; day <= totalDaysInMonth; day++) {
    const cell = document.createElement('div');
    cell.className = 'cal-day-cell';
    cell.innerText = day;
    
    if (calYear === selYear && calMonth === selMonth && day === selDay) {
      cell.classList.add('selected');
    }
    
    if (calYear === manilaToday.year && calMonth === manilaToday.month && day === manilaToday.day) {
      cell.classList.add('today');
    }
    
    cell.addEventListener('click', () => {
      selectedDate = new Date(Date.UTC(calYear, calMonth, day, 12, 0, 0));
      renderCalendar();
      updateDashboard();
    });
    
    grid.appendChild(cell);
  }
  
  const selectedLabel = document.getElementById('selectedDayText');
  if (selectedLabel) {
    selectedLabel.innerText = `Selected (PHT): ${selectedDate.toLocaleDateString('en-US', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })}`;
  }
}

// Update All Views
function updateDashboard() {
  renderLiveGauges();
  renderCongestionHeatmap();
  renderDualTables();
  render7DayMetrics();
  render30MinAverageChart();
}

// Render Live Speedometer Gauges with Latency Tracking
function renderLiveGauges() {
  const arcLength = 210;
  
  // 1. CoreRouter Live Gauge
  const latestCore = coreRouterLogs.length > 0 ? coreRouterLogs[coreRouterLogs.length - 1] : null;
  if (latestCore) {
    document.getElementById('coreLiveSpeed').innerText = latestCore.speed_mbps;
    const manilaTimeStr = latestCore.dateObj.toLocaleTimeString('en-US', { timeZone: MANILA_TZ, hour: '2-digit', minute:'2-digit' });
    document.getElementById('coreLastTime').innerText = `${formatRelativeTime(latestCore.dateObj)} (${manilaTimeStr} PHT)`;
    
    const pingPill = document.getElementById('coreLatencyPill');
    if (pingPill) {
      pingPill.innerText = `⚡ ${latestCore.ping_ms} ms • ${latestCore.packet_loss}% Loss`;
      if (latestCore.packet_loss > 0) {
        pingPill.classList.add('loss');
      } else {
        pingPill.classList.remove('loss');
      }
    }

    const speedRatio = Math.min(1, Math.max(0, latestCore.speed_mbps / 600));
    const offset = arcLength - (speedRatio * arcLength);
    const arcElem = document.getElementById('coreGaugeArc');
    if (arcElem) {
      arcElem.style.strokeDashoffset = offset;
      arcElem.setAttribute('stroke', latestCore.speed_mbps >= 200 ? '#38bdf8' : '#ef4444');
    }
  }
  
  // 2. HomeMikro Live Gauge
  const latestHome = homeMikroLogs.length > 0 ? homeMikroLogs[homeMikroLogs.length - 1] : null;
  if (latestHome) {
    document.getElementById('homeLiveSpeed').innerText = latestHome.speed_mbps;
    const manilaTimeStr = latestHome.dateObj.toLocaleTimeString('en-US', { timeZone: MANILA_TZ, hour: '2-digit', minute:'2-digit' });
    document.getElementById('homeLastTime').innerText = `${formatRelativeTime(latestHome.dateObj)} (${manilaTimeStr} PHT)`;
    
    const homePingPill = document.getElementById('homeLatencyPill');
    if (homePingPill) {
      homePingPill.innerText = `⚡ ${latestHome.ping_ms} ms • ${latestHome.packet_loss}% Loss`;
    }

    const speedRatio = Math.min(1, Math.max(0, latestHome.speed_mbps / 600));
    const offset = arcLength - (speedRatio * arcLength);
    const arcElem = document.getElementById('homeGaugeArc');
    if (arcElem) {
      arcElem.style.strokeDashoffset = offset;
      arcElem.setAttribute('stroke', latestHome.speed_mbps >= 200 ? '#c084fc' : '#ef4444');
    }
  }
}

// 24-Hour Congestion Heatmap Renderer (Strict Manila Hours 00..23)
function renderCongestionHeatmap() {
  const container = document.getElementById('heatmapGrid');
  if (!container) return;
  container.innerHTML = '';

  const allLogs = coreRouterLogs.length > 0 ? coreRouterLogs : homeMikroLogs;
  
  const hourlyData = Array(24).fill(null).map(() => []);
  allLogs.forEach(l => {
    const hr = l.manila.hour;
    if (hr >= 0 && hr < 24) {
      hourlyData[hr].push(l.speed_mbps);
    }
  });

  for (let hr = 0; hr < 24; hr++) {
    const cell = document.createElement('div');
    cell.className = 'heatmap-hour-cell';
    
    const speeds = hourlyData[hr];
    const avg = speeds.length > 0 ? Math.round(speeds.reduce((a, b) => a + b, 0) / speeds.length) : null;
    
    const hrDisplay = hr === 0 ? '12A' : hr < 12 ? `${hr}A` : hr === 12 ? '12P' : `${hr-12}P`;
    
    let bg = 'rgba(255, 255, 255, 0.05)';
    let text = '--';
    let titleText = `Hour ${hr}:00 Manila: No test data recorded`;

    if (avg !== null) {
      text = `${avg}M`;
      if (avg >= 200) {
        bg = 'linear-gradient(180deg, #10b981, #059669)';
        titleText = `Hour ${hr}:00 (${hrDisplay} Manila): Avg ${avg} Mbps (Fast / Optimal)`;
      } else if (avg >= 100) {
        bg = 'linear-gradient(180deg, #f59e0b, #d97706)';
        titleText = `Hour ${hr}:00 (${hrDisplay} Manila): Avg ${avg} Mbps (Moderate Congestion)`;
      } else {
        bg = 'linear-gradient(180deg, #ef4444, #b91c1c)';
        titleText = `Hour ${hr}:00 (${hrDisplay} Manila): Avg ${avg} Mbps (Heavy Peak Throttle)`;
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

// Side-by-Side Dual Tables (Strict Manila Date Filter)
function renderDualTables() {
  const tbodyCore = document.getElementById('tbodyCoreRouter');
  const tbodyHome = document.getElementById('tbodyHomeMikro');
  if (!tbodyCore || !tbodyHome) return;
  
  tbodyCore.innerHTML = '';
  tbodyHome.innerHTML = '';
  
  const selYear = selectedDate.getUTCFullYear();
  const selMonth = selectedDate.getUTCMonth();
  const selDay = selectedDate.getUTCDate();
  
  const filteredCore = coreRouterLogs.filter(l => 
    l.manila.year === selYear &&
    l.manila.month === selMonth &&
    l.manila.day === selDay
  ).sort((a, b) => b.dateObj - a.dateObj);
  
  const filteredHome = homeMikroLogs.filter(l => 
    l.manila.year === selYear &&
    l.manila.month === selMonth &&
    l.manila.day === selDay
  ).sort((a, b) => b.dateObj - a.dateObj);
  
  if (filteredCore.length === 0) {
    tbodyCore.innerHTML = `
      <tr>
        <td colspan="3" style="text-align: center; color: #64748b; padding: 2rem 1rem;">
          No CoreRouter speed test logs recorded for this date.<br>
          <small style="color: #475569;">Scheduled tests run automatically every 30 minutes.</small>
        </td>
      </tr>
    `;
  } else {
    filteredCore.forEach((log) => {
      const tr = document.createElement('tr');
      const colorStyle = getSpeedColorStyle(log.speed_mbps);
      
      tr.innerHTML = `
        <td class="time-cell">${formatHumanReadableManila(log.dateObj)}</td>
        <td>
          <span class="speed-badge" style="background: ${colorStyle.bg}; color: ${colorStyle.text}; border: 1px solid ${colorStyle.border};">
            ${log.speed_mbps} Mbps
          </span>
        </td>
        <td><span class="target-badge">${log.target}</span></td>
      `;
      tbodyCore.appendChild(tr);
    });
  }
  
  if (filteredHome.length === 0) {
    tbodyHome.innerHTML = `
      <tr>
        <td colspan="3" style="text-align: center; color: #64748b; padding: 2rem 1rem;">
          No HomeMikro speed test logs recorded for this date.<br>
          <small style="color: #475569;">Scheduled tests run automatically every 30 minutes.</small>
        </td>
      </tr>
    `;
  } else {
    filteredHome.forEach((log) => {
      const tr = document.createElement('tr');
      const colorStyle = getSpeedColorStyle(log.speed_mbps);
      
      tr.innerHTML = `
        <td class="time-cell">${formatHumanReadableManila(log.dateObj)}</td>
        <td>
          <span class="speed-badge" style="background: ${colorStyle.bg}; color: ${colorStyle.text}; border: 1px solid ${colorStyle.border};">
            ${log.speed_mbps} Mbps
          </span>
        </td>
        <td><span class="target-badge">${log.target}</span></td>
      `;
      tbodyHome.appendChild(tr);
    });
  }
}

// 7-Day SLA Metrics
function render7DayMetrics() {
  const allLogs = [...coreRouterLogs, ...homeMikroLogs];
  
  if (allLogs.length === 0) {
    document.getElementById('metricAvgSpeed').innerText = `0 Mbps`;
    document.getElementById('metricSlowSpeed').innerText = `0.0 hrs (0 tests)`;
    document.getElementById('metricOutage').innerText = `0 mins (0 events)`;
    document.getElementById('metricCompliance').innerText = `100%`;
    document.getElementById('metricComplianceFill').style.width = `100%`;
    document.getElementById('metricComplianceSub').innerText = `0 authentic tests recorded so far`;
    return;
  }
  
  const totalSpeed = allLogs.reduce((acc, l) => acc + l.speed_mbps, 0);
  const avgSpeed = Math.round(totalSpeed / allLogs.length);
  
  const slowLogs = allLogs.filter(l => l.speed_mbps > 0 && l.speed_mbps < 200);
  const slowCount = slowLogs.length;
  const slowHours = (slowCount * 30 / 60).toFixed(1);
  
  const outageLogs = allLogs.filter(l => l.speed_mbps === 0);
  const outageCount = outageLogs.length;
  const outageMinutes = outageCount * 30;
  
  const compliantLogs = allLogs.filter(l => l.speed_mbps >= 200);
  const compliantPercent = ((compliantLogs.length / allLogs.length) * 100).toFixed(1);
  const slowPercent = (100 - parseFloat(compliantPercent)).toFixed(1);
  
  document.getElementById('metricAvgSpeed').innerText = `${avgSpeed} Mbps`;
  document.getElementById('metricSlowSpeed').innerText = `${slowHours} hrs (${slowCount} tests)`;
  document.getElementById('metricOutage').innerText = `${outageMinutes} mins (${outageCount} events)`;
  document.getElementById('metricCompliance').innerText = `${compliantPercent}%`;
  document.getElementById('metricComplianceFill').style.width = `${compliantPercent}%`;
  document.getElementById('metricComplianceSub').innerText = `${compliantPercent}% ≥ 200Mbps | ${slowPercent}% < 200Mbps (${allLogs.length} authentic tests recorded)`;
}

function setupRangeSelectorListeners() {
  const buttons = document.querySelectorAll('.range-btn');
  buttons.forEach(btn => {
    btn.addEventListener('click', (e) => {
      buttons.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      currentChartRange = btn.getAttribute('data-range') || '7d';
      renderAdaptiveTrendChart();
    });
  });
}

// Update All Views
function updateDashboard() {
  renderLiveGauges();
  renderCongestionHeatmap();
  renderDualTables();
  render7DayMetrics();
  renderAdaptiveTrendChart();
}

// Adaptive Trend Chart Renderer with Dynamic Bucket Sampling
function renderAdaptiveTrendChart() {
  const canvas = document.getElementById('speedTrendChart');
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  
  const allLogs = [...coreRouterLogs, ...homeMikroLogs];
  
  if (allLogs.length === 0) {
    if (chartInstance) chartInstance.destroy();
    return;
  }
  
  const now = new Date();
  let cutoffTime = new Date(now.getTime() - (7 * 24 * 60 * 60 * 1000));
  let bucketMinutes = 30;
  let titleText = '7-Day Speed Trend (30-Min Averages)';
  let subtitleText = 'Aggregated in 30-minute increments across 7 days for balanced rolling trend';

  if (currentChartRange === '24h') {
    cutoffTime = new Date(now.getTime() - (24 * 60 * 60 * 1000));
    bucketMinutes = 15;
    titleText = '24-Hour Speed Trend (15-Min Averages)';
    subtitleText = 'Aggregated in 15-minute increments for high-precision short-term analysis';
  } else if (currentChartRange === '7d') {
    cutoffTime = new Date(now.getTime() - (7 * 24 * 60 * 60 * 1000));
    bucketMinutes = 30;
    titleText = '7-Day Speed Trend (30-Min Averages)';
    subtitleText = 'Aggregated in 30-minute increments across 7 days (~336 max data points)';
  } else if (currentChartRange === '14d') {
    cutoffTime = new Date(now.getTime() - (14 * 24 * 60 * 60 * 1000));
    bucketMinutes = 60;
    titleText = '14-Day Speed Trend (1-Hour Averages)';
    subtitleText = 'Aggregated in 1-hour increments across 2 weeks (~336 max data points)';
  } else if (currentChartRange === '30d') {
    cutoffTime = new Date(now.getTime() - (30 * 24 * 60 * 60 * 1000));
    bucketMinutes = 240; // 4 hours
    titleText = '30-Day Speed Trend (4-Hour Averages)';
    subtitleText = 'Aggregated in 4-hour increments across 1 month (~180 max data points)';
  }

  // Update UI titles
  const titleElem = document.getElementById('chartTitle');
  const subElem = document.getElementById('chartSubtitle');
  if (titleElem) titleElem.innerText = titleText;
  if (subElem) subElem.innerText = subtitleText;

  const labelsMap = new Map();
  
  allLogs.filter(l => l.dateObj >= cutoffTime).forEach(l => {
    const m = l.manila;
    let roundedHour = m.hour;
    let roundedMin = 0;

    if (bucketMinutes < 60) {
      roundedMin = Math.floor(m.minute / bucketMinutes) * bucketMinutes;
    } else {
      const hoursPerBucket = bucketMinutes / 60;
      roundedHour = Math.floor(m.hour / hoursPerBucket) * hoursPerBucket;
    }

    const timeKey = bucketMinutes >= 1440 
      ? `${m.month+1}/${m.day}` 
      : `${m.month+1}/${m.day} ${String(roundedHour).padStart(2,'0')}:${String(roundedMin).padStart(2,'0')}`;
      
    const sortVal = new Date(Date.UTC(m.year, m.month, m.day, roundedHour, roundedMin, 0)).getTime();
    
    if (!labelsMap.has(timeKey)) {
      labelsMap.set(timeKey, { 
        timeKey: timeKey, 
        sortVal: sortVal, 
        mYear: m.year, 
        mMonth: m.month, 
        mDay: m.day, 
        mHour: roundedHour, 
        mMin: roundedMin,
        bucketMins: bucketMinutes
      });
    }
  });
  
  const sortedTimeSlots = Array.from(labelsMap.values()).sort((a, b) => a.sortVal - b.sortVal);
  const labels = sortedTimeSlots.map(s => s.timeKey);
  
  const coreAvgList = [];
  const homeAvgList = [];
  
  sortedTimeSlots.forEach(slot => {
    const logsCore = coreRouterLogs.filter(l => {
      if (l.manila.year !== slot.mYear || l.manila.month !== slot.mMonth || l.manila.day !== slot.mDay) return false;
      if (slot.bucketMins < 60) {
        return l.manila.hour === slot.mHour && Math.floor(l.manila.minute / slot.bucketMins) * slot.bucketMins === slot.mMin;
      } else {
        const hpb = slot.bucketMins / 60;
        return Math.floor(l.manila.hour / hpb) * hpb === slot.mHour;
      }
    });
    const avgCore = logsCore.length > 0 ? Math.round(logsCore.reduce((a, b) => a + b.speed_mbps, 0) / logsCore.length) : null;
    coreAvgList.push(avgCore);
    
    const logsHome = homeMikroLogs.filter(l => {
      if (l.manila.year !== slot.mYear || l.manila.month !== slot.mMonth || l.manila.day !== slot.mDay) return false;
      if (slot.bucketMins < 60) {
        return l.manila.hour === slot.mHour && Math.floor(l.manila.minute / slot.bucketMins) * slot.bucketMins === slot.mMin;
      } else {
        const hpb = slot.bucketMins / 60;
        return Math.floor(l.manila.hour / hpb) * hpb === slot.mHour;
      }
    });
    const avgHome = logsHome.length > 0 ? Math.round(logsHome.reduce((a, b) => a + b.speed_mbps, 0) / logsHome.length) : null;
    homeAvgList.push(avgHome);
  });
  
  if (chartInstance) {
    chartInstance.destroy();
  }
  
  chartInstance = new Chart(ctx, {
    type: 'line',
    data: {
      labels: labels,
      datasets: [
        {
          label: 'CoreRouter (ISP WAN)',
          data: coreAvgList,
          borderColor: '#38bdf8',
          backgroundColor: 'rgba(56, 189, 248, 0.15)',
          borderWidth: 3,
          pointRadius: labels.length > 150 ? 2 : 4,
          pointHoverRadius: 6,
          pointBackgroundColor: '#38bdf8',
          spanGaps: true,
          tension: 0.25,
          fill: false
        },
        {
          label: 'HomeMikro (Backbone Transit)',
          data: homeAvgList,
          borderColor: '#c084fc',
          backgroundColor: 'rgba(192, 132, 252, 0.15)',
          borderWidth: 3,
          pointRadius: labels.length > 150 ? 2 : 4,
          pointHoverRadius: 6,
          pointBackgroundColor: '#c084fc',
          spanGaps: true,
          tension: 0.25,
          fill: false
        }
      ]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: {
        duration: 350
      },
      interaction: {
        mode: 'index',
        intersect: false
      },
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
          borderColor: 'rgba(255,255,255,0.1)',
          borderWidth: 1,
          padding: 10,
          callbacks: {
            label: function(context) {
              return `${context.dataset.label}: ${context.parsed.y} Mbps`;
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
            maxTicksLimit: 14
          }
        },
        y: {
          min: 0,
          max: 600,
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
