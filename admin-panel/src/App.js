import { useState, useEffect, useRef } from "react";
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, PieChart, Pie, Cell, AreaChart, Area } from "recharts";

const API_BASE = "http://127.0.0.1:8000/api";

function getAuthToken() {
  return localStorage.getItem("admin_token");
}

async function apiFetch(path, options = {}) {
  const token = getAuthToken();
  const res = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(options.headers || {}),
    },
  });
  if (res.status === 401) {
    localStorage.removeItem("admin_token");
    window.location.reload();
  }
  return res;
}

const T = {
  teal: "#2ABFBF", tealDark: "#1FA3A3", tealLight: "#E8F8F8",
  navy: "#1A2B3C", navyLight: "#2C3E50", bg: "#F4F7FA",
  card: "#FFFFFF", text: "#1A2B3C", textMuted: "#7B8794",
  border: "#E8ECF0", green: "#4CAF50", orange: "#FF9800",
  red: "#EF5350", purple: "#7C4DFF", blue: "#42A5F5",
  gradient: "linear-gradient(135deg, #2ABFBF 0%, #1FA3A3 50%, #178F8F 100%)",
  shadow: "0 2px 12px rgba(26,43,60,0.06)",
  shadowHover: "0 4px 20px rgba(42,191,191,0.15)",
  radius: "16px", radiusSm: "12px",
};

const messageData = [
  { name: "Lun", messages: 245, encrypted: 230 },
  { name: "Mar", messages: 312, encrypted: 298 },
  { name: "Mer", messages: 278, encrypted: 265 },
  { name: "Gio", messages: 390, encrypted: 375 },
  { name: "Ven", messages: 420, encrypted: 410 },
  { name: "Sab", messages: 180, encrypted: 170 },
  { name: "Dom", messages: 150, encrypted: 142 },
];

const callData = [
  { name: "Audio", value: 65, color: T.teal },
  { name: "Video", value: 25, color: T.purple },
  { name: "Gruppo", value: 10, color: T.orange },
];

const SvgIcon = ({ children, size = 20 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">{children}</svg>
);

const IconDashboard = () => <SvgIcon><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></SvgIcon>;
const IconUsers = () => <SvgIcon><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></SvgIcon>;
const IconGroups = () => <SvgIcon><circle cx="12" cy="12" r="10"/><path d="M8 12h8"/><path d="M12 8v8"/></SvgIcon>;
const IconSecurity = () => <SvgIcon><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></SvgIcon>;
const IconReports = () => <SvgIcon><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/></SvgIcon>;
const IconSettings = () => <SvgIcon><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></SvgIcon>;
const IconBell = () => <SvgIcon><path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/></SvgIcon>;
const IconSearch = () => <SvgIcon size={18}><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></SvgIcon>;

const iconMap = { dashboard: <IconDashboard/>, users: <IconUsers/>, groups: <IconGroups/>, security: <IconSecurity/>, reports: <IconReports/>, settings: <IconSettings/> };
const labels = { dashboard: "Dashboard", users: "Utenti", groups: "Gruppi", security: "Security", reports: "Report", settings: "Impostazioni" };

function AnimatedNumber({ value, duration = 1200 }) {
  const [display, setDisplay] = useState(0);
  const startRef = useRef(null);
  useEffect(() => {
    startRef.current = null;
    const step = (ts) => {
      if (!startRef.current) startRef.current = ts;
      const p = Math.min((ts - startRef.current) / duration, 1);
      setDisplay(Math.floor(p * value));
      if (p < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }, [value, duration]);
  return <>{display.toLocaleString("it-IT")}</>;
}

function StatCard({ title, value, icon, trend, trendValue, color, delay = 0 }) {
  const [vis, setVis] = useState(false);
  useEffect(() => { const t = setTimeout(() => setVis(true), delay); return () => clearTimeout(t); }, [delay]);
  const isUp = trend === "up";
  return (
    <div style={{
      background: T.card, borderRadius: T.radius, padding: "24px", boxShadow: T.shadow,
      transition: "all 0.4s cubic-bezier(0.4,0,0.2,1)", opacity: vis ? 1 : 0,
      transform: vis ? "translateY(0)" : "translateY(20px)", cursor: "pointer",
      position: "relative", overflow: "hidden", border: `1px solid ${T.border}`,
    }}
    onMouseEnter={e => { e.currentTarget.style.boxShadow = T.shadowHover; e.currentTarget.style.transform = "translateY(-2px)"; }}
    onMouseLeave={e => { e.currentTarget.style.boxShadow = T.shadow; e.currentTarget.style.transform = "translateY(0)"; }}>
      <div style={{ position: "absolute", top: -20, right: -20, width: 100, height: 100, borderRadius: "50%", background: `${color}10` }} />
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 16 }}>
        <div style={{ width: 48, height: 48, borderRadius: 14, background: `${color}15`, display: "flex", alignItems: "center", justifyContent: "center", color }}>
          {icon}
        </div>
        {trendValue && (
          <div style={{ display: "flex", alignItems: "center", gap: 3, color: isUp ? T.green : T.red, fontSize: 13, fontWeight: 600, background: isUp ? "#E8F5E9" : "#FFEBEE", padding: "4px 10px", borderRadius: 20 }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round"><polyline points={isUp ? "18 15 12 9 6 15" : "6 9 12 15 18 9"}/></svg>
            {trendValue}
          </div>
        )}
      </div>
      <div style={{ fontSize: 32, fontWeight: 800, color: T.text, letterSpacing: "-0.5px", lineHeight: 1.1 }}><AnimatedNumber value={value} /></div>
      <div style={{ fontSize: 13, color: T.textMuted, marginTop: 6, fontWeight: 500, letterSpacing: "0.3px", textTransform: "uppercase" }}>{title}</div>
    </div>
  );
}

function ChartCard({ title, children, delay = 0 }) {
  const [vis, setVis] = useState(false);
  useEffect(() => { const t = setTimeout(() => setVis(true), delay); return () => clearTimeout(t); }, [delay]);
  return (
    <div style={{ background: T.card, borderRadius: T.radius, padding: 24, boxShadow: T.shadow, border: `1px solid ${T.border}`, opacity: vis ? 1 : 0, transform: vis ? "translateY(0)" : "translateY(20px)", transition: "all 0.5s cubic-bezier(0.4,0,0.2,1)" }}>
      <div style={{ fontSize: 16, fontWeight: 700, color: T.text, marginBottom: 20 }}>{title}</div>
      {children}
    </div>
  );
}

function InfoCard({ title, value, subtitle, icon, color, status, delay = 0 }) {
  const [vis, setVis] = useState(false);
  useEffect(() => { const t = setTimeout(() => setVis(true), delay); return () => clearTimeout(t); }, [delay]);
  return (
    <div style={{ background: T.card, borderRadius: T.radius, padding: 24, boxShadow: T.shadow, border: `1px solid ${T.border}`, opacity: vis ? 1 : 0, transform: vis ? "translateY(0)" : "translateY(20px)", transition: "all 0.4s cubic-bezier(0.4,0,0.2,1)", cursor: "pointer" }}
    onMouseEnter={e => { e.currentTarget.style.boxShadow = T.shadowHover; e.currentTarget.style.transform = "translateY(-2px)"; }}
    onMouseLeave={e => { e.currentTarget.style.boxShadow = T.shadow; e.currentTarget.style.transform = "translateY(0)"; }}>
      <div style={{ display: "flex", alignItems: "center", gap: 14, marginBottom: 16 }}>
        <div style={{ width: 44, height: 44, borderRadius: 12, background: `${color}15`, display: "flex", alignItems: "center", justifyContent: "center", color }}>{icon}</div>
        <div style={{ fontSize: 13, color: T.textMuted, fontWeight: 500, textTransform: "uppercase", letterSpacing: "0.3px" }}>{title}</div>
      </div>
      <div style={{ fontSize: 28, fontWeight: 800, color: T.text, letterSpacing: "-0.5px" }}>
        {typeof value === "number" ? <AnimatedNumber value={value} /> : value}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 8 }}>
        {status && <div style={{ width: 8, height: 8, borderRadius: "50%", background: status === "ok" ? T.green : status === "warn" ? T.orange : T.red, boxShadow: `0 0 8px ${status === "ok" ? T.green+"60" : status === "warn" ? T.orange+"60" : T.red+"60"}` }} />}
        <div style={{ fontSize: 13, color: T.textMuted, fontWeight: 500 }}>{subtitle}</div>
      </div>
    </div>
  );
}

function CustomTooltip({ active, payload, label }) {
  if (!active || !payload) return null;
  return (
    <div style={{ background: T.navy, borderRadius: 10, padding: "12px 16px", boxShadow: "0 8px 24px rgba(0,0,0,0.2)" }}>
      <div style={{ color: "#fff", fontSize: 13, fontWeight: 600, marginBottom: 6 }}>{label}</div>
      {payload.map((p, i) => (
        <div key={i} style={{ color: p.color, fontSize: 12, display: "flex", gap: 8, alignItems: "center" }}>
          <div style={{ width: 8, height: 8, borderRadius: "50%", background: p.color }} />
          {p.name}: <span style={{ fontWeight: 700, color: "#fff" }}>{p.value}</span>
        </div>
      ))}
    </div>
  );
}

function Sidebar({ active, onSelect, collapsed }) {
  return (
    <div style={{ width: collapsed ? 72 : 260, background: T.navy, height: "100vh", position: "fixed", left: 0, top: 0, display: "flex", flexDirection: "column", transition: "width 0.3s cubic-bezier(0.4,0,0.2,1)", zIndex: 100, overflow: "hidden" }}>
      <div style={{ padding: collapsed ? "24px 16px" : "24px 12px", display: "flex", alignItems: "center", justifyContent: "center", borderBottom: "1px solid rgba(255,255,255,0.08)", minHeight: 80, width: "100%", boxSizing: "border-box" }}>
        <img src="/Logo_Securechat_w.png" alt="SecureChat" style={{ width: "100%", padding: "0 16px", objectFit: "contain", boxSizing: "border-box" }} />
      </div>
      <div style={{ flex: 1, padding: "16px 12px", display: "flex", flexDirection: "column", gap: 4 }}>
        {Object.keys(labels).map(id => {
          const isActive = active === id;
          return (
            <button key={id} onClick={() => onSelect(id)} style={{ display: "flex", alignItems: "center", gap: 14, padding: collapsed ? "12px 0" : "12px 16px", justifyContent: collapsed ? "center" : "flex-start", borderRadius: 12, border: "none", cursor: "pointer", background: isActive ? "rgba(42,191,191,0.15)" : "transparent", color: isActive ? T.teal : "rgba(255,255,255,0.5)", fontSize: 14, fontWeight: isActive ? 600 : 500, transition: "all 0.2s ease", width: "100%", position: "relative", fontFamily: "inherit" }}
            onMouseEnter={e => { if (!isActive) { e.currentTarget.style.background = "rgba(255,255,255,0.05)"; e.currentTarget.style.color = "rgba(255,255,255,0.8)"; }}}
            onMouseLeave={e => { if (!isActive) { e.currentTarget.style.background = "transparent"; e.currentTarget.style.color = "rgba(255,255,255,0.5)"; }}}>
              {isActive && !collapsed && <div style={{ position: "absolute", left: -12, top: "50%", transform: "translateY(-50%)", width: 4, height: 28, background: T.teal, borderRadius: "0 4px 4px 0" }} />}
              <div style={{ flexShrink: 0, display: "flex", alignItems: "center" }}>{iconMap[id]}</div>
              {!collapsed && <span style={{ whiteSpace: "nowrap" }}>{labels[id]}</span>}
            </button>
          );
        })}
      </div>
      {!collapsed && (
        <div style={{ padding: "16px 20px", borderTop: "1px solid rgba(255,255,255,0.08)", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <div style={{ width: 36, height: 36, borderRadius: 10, background: T.gradient, display: "flex", alignItems: "center", justifyContent: "center", color: "#fff", fontSize: 14, fontWeight: 700 }}>RA</div>
            <div><div style={{ color: "#fff", fontSize: 13, fontWeight: 600 }}>Admin</div><div style={{ color: "rgba(255,255,255,0.4)", fontSize: 11 }}>Super Admin</div></div>
          </div>
          <button onClick={() => { localStorage.removeItem("admin_token"); localStorage.removeItem("admin_refresh"); window.location.reload(); }} style={{ background: "transparent", border: "none", cursor: "pointer", color: "rgba(255,255,255,0.3)", padding: 4, display: "flex", alignItems: "center", fontFamily: "inherit" }} title="Logout">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>
          </button>
        </div>
      )}
    </div>
  );
}

function TopHeader({ title, collapsed, onToggle }) {
  return (
    <div style={{ height: 72, background: "rgba(255,255,255,0.85)", backdropFilter: "blur(20px)", WebkitBackdropFilter: "blur(20px)", borderBottom: `1px solid ${T.border}`, display: "flex", alignItems: "center", justifyContent: "space-between", padding: "0 32px", position: "sticky", top: 0, zIndex: 50 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
        <button onClick={onToggle} style={{ width: 36, height: 36, borderRadius: 10, border: `1px solid ${T.border}`, background: "#fff", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", color: T.textMuted, transition: "all 0.2s", fontFamily: "inherit" }}
        onMouseEnter={e => { e.currentTarget.style.borderColor = T.teal; e.currentTarget.style.color = T.teal; }}
        onMouseLeave={e => { e.currentTarget.style.borderColor = T.border; e.currentTarget.style.color = T.textMuted; }}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="15" y2="12"/><line x1="3" y1="18" x2="18" y2="18"/></svg>
        </button>
        <div>
          <div style={{ fontSize: 20, fontWeight: 800, color: T.text, letterSpacing: "-0.3px" }}>{title}</div>
          <div style={{ fontSize: 12, color: T.textMuted, fontWeight: 500 }}>{new Date().toLocaleDateString("it-IT", { weekday: "long", day: "numeric", month: "long", year: "numeric" })}</div>
        </div>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, background: T.bg, borderRadius: 12, padding: "8px 16px" }}>
          <div style={{ color: T.textMuted }}><IconSearch /></div>
          <input placeholder="Cerca..." style={{ border: "none", outline: "none", background: "transparent", fontSize: 13, color: T.text, width: 180, fontFamily: "inherit" }} />
        </div>
        <button style={{ width: 40, height: 40, borderRadius: 12, border: `1px solid ${T.border}`, background: "#fff", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", color: T.textMuted, position: "relative", fontFamily: "inherit" }}>
          <IconBell />
          <div style={{ position: "absolute", top: 6, right: 6, width: 8, height: 8, borderRadius: "50%", background: T.red, border: "2px solid #fff" }} />
        </button>
        <div style={{ width: 40, height: 40, borderRadius: 12, background: T.gradient, display: "flex", alignItems: "center", justifyContent: "center", color: "#fff", fontSize: 14, fontWeight: 700, cursor: "pointer" }}>RA</div>
      </div>
    </div>
  );
}

const mockUsers = [
  { id: 1, firstName: "Alice", lastName: "Test", email: "alice@securechat.test", group: "Engineering", createdAt: "2025-12-15", device: "iPhone 16 Pro", status: "active" },
  { id: 2, firstName: "Bob", lastName: "Test", email: "bob@securechat.test", group: "Marketing", createdAt: "2025-12-20", device: "Samsung Galaxy S24", status: "active" },
  { id: 3, firstName: "Jon", lastName: "Test", email: "jon@securechat.test", group: "Engineering", createdAt: "2026-01-05", device: "iPhone 15", status: "active" },
  { id: 4, firstName: "Maria", lastName: "Rossi", email: "maria@securechat.test", group: "HR", createdAt: "2026-01-10", device: "Pixel 8 Pro", status: "pending" },
  { id: 5, firstName: "Luca", lastName: "Bianchi", email: "luca@securechat.test", group: "Sales", createdAt: "2026-01-15", device: "iPhone 16", status: "active" },
  { id: 6, firstName: "Sara", lastName: "Verdi", email: "sara@securechat.test", group: "Engineering", createdAt: "2026-01-18", device: "Samsung Galaxy S25", status: "blocked" },
  { id: 7, firstName: "Marco", lastName: "Neri", email: "marco@securechat.test", group: "Marketing", createdAt: "2026-01-22", device: "iPhone 15 Pro Max", status: "active" },
  { id: 8, firstName: "Giulia", lastName: "Romano", email: "giulia@securechat.test", group: "Design", createdAt: "2026-02-01", device: "Pixel 9", status: "pending" },
  { id: 9, firstName: "Andrea", lastName: "Colombo", email: "andrea@securechat.test", group: "Engineering", createdAt: "2026-02-05", device: "iPhone 16 Pro", status: "active" },
  { id: 10, firstName: "Elena", lastName: "Ferrari", email: "elena@securechat.test", group: "HR", createdAt: "2026-02-10", device: "Samsung Galaxy S24 Ultra", status: "active" },
  { id: 11, firstName: "Paolo", lastName: "Ricci", email: "paolo@securechat.test", group: "Sales", createdAt: "2026-02-12", device: "OnePlus 12", status: "blocked" },
  { id: 12, firstName: "Chiara", lastName: "Moretti", email: "chiara@securechat.test", group: "Design", createdAt: "2026-02-15", device: "iPhone 16 Pro Max", status: "active" },
];

const statusConfig = {
  active: { label: "Attivo", color: "#4CAF50", bg: "#E8F5E9" },
  approved: { label: "Attivo", color: "#4CAF50", bg: "#E8F5E9" },
  pending: { label: "Da autorizzare", color: "#FF9800", bg: "#FFF3E0" },
  blocked: { label: "Bloccato", color: "#EF5350", bg: "#FFEBEE" },
};

const mockGroups = [
  { id: "GRP-001", name: "Engineering", description: "Team sviluppo software e infrastruttura", status: "active", members: [
    { id: 1, firstName: "Alice", lastName: "Test", email: "alice@securechat.test", device: "iPhone 16 Pro", avatar: null },
    { id: 3, firstName: "Jon", lastName: "Test", email: "jon@securechat.test", device: "iPhone 15", avatar: null },
    { id: 6, firstName: "Sara", lastName: "Verdi", email: "sara@securechat.test", device: "Samsung Galaxy S25", avatar: null },
    { id: 9, firstName: "Andrea", lastName: "Colombo", email: "andrea@securechat.test", device: "iPhone 16 Pro", avatar: null },
  ]},
  { id: "GRP-002", name: "Marketing", description: "Comunicazione e strategie di marketing", status: "active", members: [
    { id: 2, firstName: "Bob", lastName: "Test", email: "bob@securechat.test", device: "Samsung Galaxy S24", avatar: null },
    { id: 7, firstName: "Marco", lastName: "Neri", email: "marco@securechat.test", device: "iPhone 15 Pro Max", avatar: null },
  ]},
  { id: "GRP-003", name: "HR", description: "Risorse umane e gestione personale", status: "active", members: [
    { id: 4, firstName: "Maria", lastName: "Rossi", email: "maria@securechat.test", device: "Pixel 8 Pro", avatar: null },
    { id: 10, firstName: "Elena", lastName: "Ferrari", email: "elena@securechat.test", device: "Samsung Galaxy S24 Ultra", avatar: null },
  ]},
  { id: "GRP-004", name: "Sales", description: "Vendite e relazioni con i clienti", status: "active", members: [
    { id: 5, firstName: "Luca", lastName: "Bianchi", email: "luca@securechat.test", device: "iPhone 16", avatar: null },
    { id: 11, firstName: "Paolo", lastName: "Ricci", email: "paolo@securechat.test", device: "OnePlus 12", avatar: null },
  ]},
  { id: "GRP-005", name: "Design", description: "UX/UI Design e ricerca utente", status: "inactive", members: [
    { id: 8, firstName: "Giulia", lastName: "Romano", email: "giulia@securechat.test", device: "Pixel 9", avatar: null },
    { id: 12, firstName: "Chiara", lastName: "Moretti", email: "chiara@securechat.test", device: "iPhone 16 Pro Max", avatar: null },
  ]},
  { id: "GRP-006", name: "Legal", description: "Ufficio legale e compliance", status: "active", members: [
    { id: 1, firstName: "Alice", lastName: "Test", email: "alice@securechat.test", device: "iPhone 16 Pro", avatar: null },
  ]},
  { id: "GRP-007", name: "Finance", description: "Contabilità e pianificazione finanziaria", status: "inactive", members: []},
  { id: "GRP-008", name: "Support", description: "Assistenza clienti e supporto tecnico", status: "active", members: [
    { id: 2, firstName: "Bob", lastName: "Test", email: "bob@securechat.test", device: "Samsung Galaxy S24", avatar: null },
    { id: 4, firstName: "Maria", lastName: "Rossi", email: "maria@securechat.test", device: "Pixel 8 Pro", avatar: null },
    { id: 9, firstName: "Andrea", lastName: "Colombo", email: "andrea@securechat.test", device: "iPhone 16 Pro", avatar: null },
  ]},
];

const groupStatusConfig = {
  active: { label: "Attivo", color: "#4CAF50", bg: "#E8F5E9" },
  inactive: { label: "Spento", color: "#9E9E9E", bg: "#F5F5F5" },
};

function DashboardPage() {
  const [stats, setStats] = useState({ users: 0, groups: 0, chats: 0, calls: 0 });
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function loadStats() {
      try {
        const res = await apiFetch("/admin/stats/");
        const data = await res.json();
        setStats({
          users: data.total_users || 0,
          groups: data.total_groups || 0,
          chats: data.total_chats || 0,
          calls: data.total_calls || 0,
          messages: data.total_messages || 0,
          onlineUsers: data.online_users || 0,
        });
      } catch (e) {
        console.error("Error loading dashboard stats:", e);
      }
      setLoading(false);
    }
    loadStats();
  }, []);

  return (
    <div style={{ padding: "28px 32px" }}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 20, marginBottom: 24 }}>
        <StatCard title="Totale Utenti" value={stats.users} icon={<SvgIcon size={24}><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/></SvgIcon>} trend="up" trendValue="+12%" color={T.teal} delay={100} />
        <StatCard title="Totale Gruppi" value={stats.groups} icon={<IconUsers />} trend="up" trendValue="+5%" color={T.purple} delay={200} />
        <StatCard title="Totale Chat" value={stats.chats} icon={<SvgIcon size={24}><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></SvgIcon>} trend="up" trendValue="+28%" color={T.blue} delay={300} />
        <StatCard title="Totale Messaggi" value={stats.messages} icon={<SvgIcon size={24}><path d="M20 2H4c-1.1 0-1.99.9-1.99 2L2 22l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-2 12H6v-2h12v2zm0-3H6V9h12v2zm0-3H6V6h12v2z"/></SvgIcon>} trend="up" trendValue="+15%" color={T.orange} delay={400} />
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 20, marginBottom: 24 }}>
        <ChartCard title="Messaggi nel Tempo" delay={500}>
          <div style={{ height: 280 }}>
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={messageData} margin={{ top: 5, right: 20, left: 0, bottom: 5 }}>
                <defs>
                  <linearGradient id="tealGrad" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor={T.teal} stopOpacity={0.3}/><stop offset="95%" stopColor={T.teal} stopOpacity={0}/></linearGradient>
                  <linearGradient id="purpleGrad" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor={T.purple} stopOpacity={0.2}/><stop offset="95%" stopColor={T.purple} stopOpacity={0}/></linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke={T.border} vertical={false} />
                <XAxis dataKey="name" stroke={T.textMuted} fontSize={12} tickLine={false} axisLine={false} />
                <YAxis stroke={T.textMuted} fontSize={12} tickLine={false} axisLine={false} />
                <Tooltip content={<CustomTooltip />} />
                <Area type="monotone" dataKey="messages" stroke={T.teal} strokeWidth={2.5} fill="url(#tealGrad)" name="Totali" dot={false} activeDot={{ r: 6, fill: T.teal, stroke: "#fff", strokeWidth: 2 }} />
                <Area type="monotone" dataKey="encrypted" stroke={T.purple} strokeWidth={2} fill="url(#purpleGrad)" name="Cifrati" dot={false} activeDot={{ r: 5, fill: T.purple, stroke: "#fff", strokeWidth: 2 }} />
              </AreaChart>
            </ResponsiveContainer>
          </div>
          <div style={{ display: "flex", gap: 20, marginTop: 8, justifyContent: "center" }}>
            <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, color: T.textMuted }}><div style={{ width: 10, height: 10, borderRadius: "50%", background: T.teal }} /> Totali</div>
            <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, color: T.textMuted }}><div style={{ width: 10, height: 10, borderRadius: "50%", background: T.purple }} /> Cifrati E2E</div>
          </div>
        </ChartCard>
        <ChartCard title="Chiamate per Tipo" delay={600}>
          <div style={{ height: 280, display: "flex", alignItems: "center", justifyContent: "center" }}>
            <ResponsiveContainer width="100%" height="100%">
              <PieChart>
                <Pie data={callData} cx="50%" cy="50%" innerRadius={70} outerRadius={110} paddingAngle={4} dataKey="value" stroke="none">
                  {callData.map((entry, i) => <Cell key={i} fill={entry.color} />)}
                </Pie>
                <Tooltip formatter={(v) => [`${v}%`, ""]} contentStyle={{ background: T.navy, border: "none", borderRadius: 10, color: "#fff", fontSize: 13 }} itemStyle={{ color: "#fff" }} />
              </PieChart>
            </ResponsiveContainer>
          </div>
          <div style={{ display: "flex", gap: 16, justifyContent: "center", marginTop: 4 }}>
            {callData.map((d, i) => <div key={i} style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 13 }}><div style={{ width: 10, height: 10, borderRadius: "50%", background: d.color }} /><span style={{ color: T.textMuted, fontWeight: 500 }}>{d.name}</span><span style={{ color: T.text, fontWeight: 700 }}>{d.value}%</span></div>)}
          </div>
        </ChartCard>
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 20 }}>
        <InfoCard title="Alert" value={3} subtitle="2 critici · 1 warning" icon={<SvgIcon size={22}><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></SvgIcon>} color={T.red} status="warn" delay={700} />
        <InfoCard title="Dispositivi Connessi" value={847} subtitle="iOS 62% · Android 38%" icon={<SvgIcon size={22}><rect x="5" y="2" width="14" height="20" rx="2" ry="2"/><line x1="12" y1="18" x2="12.01" y2="18"/></SvgIcon>} color={T.blue} status="ok" delay={800} />
        <InfoCard title="Stato Notifiche" value="Attivo" subtitle="FCM operativo · 99.8% delivery" icon={<IconBell />} color={T.green} status="ok" delay={900} />
        <InfoCard title="Stato Cifratura" value="E2E" subtitle="Signal Protocol · AES-256" icon={<SvgIcon size={22}><rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></SvgIcon>} color={T.teal} status="ok" delay={1000} />
      </div>
    </div>
  );
}

function ConfirmModal({ title, message, warning, confirmLabel, confirmColor, onConfirm, onCancel }) {
  return (
    <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.5)", backdropFilter: "blur(4px)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 2000 }} onClick={onCancel}>
      <div style={{ background: T.card, borderRadius: 20, padding: 0, width: 440, boxShadow: "0 20px 60px rgba(0,0,0,0.2)", animation: "modalIn 0.2s ease" }} onClick={e => e.stopPropagation()}>
        <div style={{ padding: "28px 28px 0" }}>
          <div style={{ width: 56, height: 56, borderRadius: 16, background: `${confirmColor || T.red}12`, display: "flex", alignItems: "center", justifyContent: "center", marginBottom: 16 }}>
            <svg width="28" height="28" viewBox="0 0 24 24" fill={confirmColor || T.red}><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z"/></svg>
          </div>
          <div style={{ fontSize: 18, fontWeight: 800, color: T.text, marginBottom: 8 }}>{title}</div>
          <div style={{ fontSize: 14, color: T.textMuted, lineHeight: 1.5, marginBottom: warning ? 12 : 0 }}>{message}</div>
          {warning && (
            <div style={{ background: "#FFF3E0", border: "1px solid #FFE0B2", borderRadius: 10, padding: "10px 14px", fontSize: 13, color: "#E65100", fontWeight: 500, marginBottom: 0 }}>
              ⚠️ {warning}
            </div>
          )}
        </div>
        <div style={{ padding: "20px 28px 24px", display: "flex", justifyContent: "flex-end", gap: 10 }}>
          <button onClick={onCancel} style={{ padding: "10px 20px", borderRadius: 10, border: `1px solid ${T.border}`, background: "transparent", color: T.textMuted, fontSize: 14, fontWeight: 600, cursor: "pointer", fontFamily: "inherit" }}>Annulla</button>
          <button onClick={onConfirm} style={{ padding: "10px 24px", borderRadius: 10, border: "none", background: confirmColor || T.red, color: "#fff", fontSize: 14, fontWeight: 700, cursor: "pointer", fontFamily: "inherit", boxShadow: `0 4px 12px ${confirmColor || T.red}40` }}>{confirmLabel || "Conferma"}</button>
        </div>
      </div>
    </div>
  );
}

function InfoModal({ title, lines, onClose }) {
  return (
    <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.5)", backdropFilter: "blur(4px)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 2000 }} onClick={onClose}>
      <div style={{ background: T.card, borderRadius: 20, padding: 0, width: 440, boxShadow: "0 20px 60px rgba(0,0,0,0.2)", animation: "modalIn 0.2s ease" }} onClick={e => e.stopPropagation()}>
        <div style={{ padding: "28px 28px 0" }}>
          <div style={{ width: 56, height: 56, borderRadius: 16, background: `${T.teal}12`, display: "flex", alignItems: "center", justifyContent: "center", marginBottom: 16 }}>
            <svg width="28" height="28" viewBox="0 0 24 24" fill={T.teal}><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>
          </div>
          <div style={{ fontSize: 18, fontWeight: 800, color: T.text, marginBottom: 12 }}>{title}</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8, marginBottom: 4 }}>
            {lines.map((line, i) => (
              <div key={i} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "8px 0", borderBottom: i < lines.length - 1 ? `1px solid ${T.border}` : "none" }}>
                <span style={{ fontSize: 13, color: T.textMuted, fontWeight: 500 }}>{line.label}</span>
                <span style={{ fontSize: 13, color: line.copyable ? T.teal : T.text, fontWeight: 600, cursor: line.copyable ? "pointer" : "default", userSelect: "text" }}
                  onClick={() => { if (line.copyable) { navigator.clipboard.writeText(line.value); } }}
                  title={line.copyable ? "Clicca per copiare" : ""}>
                  {line.value}
                  {line.copyable && <svg width="12" height="12" viewBox="0 0 24 24" fill={T.teal} style={{ marginLeft: 6, verticalAlign: "middle" }}><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>}
                </span>
              </div>
            ))}
          </div>
        </div>
        <div style={{ padding: "16px 28px 24px", display: "flex", justifyContent: "flex-end" }}>
          <button onClick={onClose} style={{ padding: "10px 28px", borderRadius: 10, border: "none", background: T.gradient, color: "#fff", fontSize: 14, fontWeight: 600, cursor: "pointer", fontFamily: "inherit", boxShadow: "0 4px 12px rgba(42,191,191,0.3)" }}>Ok</button>
        </div>
      </div>
    </div>
  );
}

function UsersPage() {
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [openMenuId, setOpenMenuId] = useState(null);
  const [selectedUser, setSelectedUser] = useState(null);
  const [editingUser, setEditingUser] = useState(null);
  const [editForm, setEditForm] = useState({});
  const [availableGroups, setAvailableGroups] = useState([]);
  const [selectedGroupIds, setSelectedGroupIds] = useState([]);
  const [confirmAction, setConfirmAction] = useState(null);
  const [infoModal, setInfoModal] = useState(null);
  const menuRef = useRef(null);

  useEffect(() => {
    async function loadUsers() {
      try {
        const res = await apiFetch("/admin/users/");
        const data = await res.json();
        const usersList = Array.isArray(data) ? data : data.results || [];
        const mapped = usersList.map(u => ({
          id: u.id,
          firstName: u.first_name || u.username,
          lastName: u.last_name || "",
          email: u.email,
          group: u.groups && u.groups.length > 0 ? u.groups.map(g => g.name).join(", ") : "Nessun gruppo",
          createdAt: u.date_joined || "2026-01-01",
          device: "-",
          status: u.approval_status || (u.is_active === false ? "blocked" : "active"),
          avatar: u.avatar,
          isOnline: u.is_online,
          groups: u.groups || [],
        }));
        setUsers(mapped);
      } catch (e) {
        console.error("Error loading users:", e);
      }
      // Carica gruppi disponibili
      try {
        const grpRes = await apiFetch("/admin/groups/");
        const grpData = await grpRes.json();
        setAvailableGroups(Array.isArray(grpData) ? grpData : []);
      } catch (e) { console.error(e); }
      setLoading(false);
    }
    loadUsers();
  }, []);

  useEffect(() => {
    const handler = (e) => {
      if (menuRef.current && !menuRef.current.contains(e.target)) setOpenMenuId(null);
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, []);

  const filteredUsers = users.filter(u => {
    const matchSearch = `${u.firstName} ${u.lastName} ${u.email} ${u.group}`.toLowerCase().includes(searchQuery.toLowerCase());
    const matchStatus = statusFilter === "all" || u.status === statusFilter || (statusFilter === "active" && u.status === "approved");
    return matchSearch && matchStatus;
  });

  const handleAction = async (action, user) => {
    setOpenMenuId(null);
    switch (action) {
      case "edit":
        setEditForm({ ...user });
        setSelectedGroupIds(user.groups ? user.groups.map(g => g.id) : []);
        setEditingUser(user);
        break;
      case "delete":
        setConfirmAction({
          title: "Elimina Utente Definitivamente",
          message: `Stai per eliminare definitivamente l'utente ${user.firstName} ${user.lastName} (${user.email}). Verranno eliminati tutti i messaggi, le chiavi di cifratura, le partecipazioni ai gruppi e tutti i dati associati.`,
          warning: "Questa azione è IRREVERSIBILE. Tutti i dati dell'utente saranno cancellati permanentemente dal database.",
          confirmLabel: "Elimina Definitivamente",
          confirmColor: T.red,
          onConfirm: async () => {
            try {
              await apiFetch(`/admin/users/${user.id}/`, { method: "DELETE" });
              setUsers(prev => prev.filter(u => u.id !== user.id));
            } catch (e) { console.error(e); }
            setConfirmAction(null);
          },
        });
        break;
      case "toggle_block": {
        const isBlocking = user.status !== "blocked";
        setConfirmAction({
          title: isBlocking ? "Blocca Utente" : "Sblocca Utente",
          message: isBlocking
            ? `Stai per bloccare l'utente ${user.firstName} ${user.lastName}. L'utente non potrà più accedere all'app fino a quando non verrà sbloccato.`
            : `Stai per sbloccare l'utente ${user.firstName} ${user.lastName}. L'utente potrà nuovamente accedere all'app.`,
          warning: isBlocking ? "L'utente verrà disconnesso immediatamente e tutti i suoi token di accesso saranno invalidati." : null,
          confirmLabel: isBlocking ? "Blocca Utente" : "Sblocca Utente",
          confirmColor: isBlocking ? T.red : T.green,
          onConfirm: async () => {
            try {
              const newStatus = isBlocking ? "blocked" : "approved";
              await apiFetch(`/admin/users/${user.id}/`, {
                method: "PATCH",
                body: JSON.stringify({ approval_status: newStatus }),
              });
              setUsers(prev => prev.map(u => u.id === user.id ? { ...u, status: newStatus } : u));
              if (selectedUser && selectedUser.id === user.id) {
                setSelectedUser(prev => ({ ...prev, status: newStatus }));
              }
            } catch (e) { console.error(e); }
            setConfirmAction(null);
          },
        });
        break;
      }
      case "reset_password":
        try {
          const res = await apiFetch(`/admin/users/${user.id}/reset-password/`, { method: "POST" });
          const data = await res.json();
          setInfoModal({
            title: "Password Resettata",
            lines: [
              { label: "Utente", value: `${user.firstName} ${user.lastName}` },
              { label: "Email", value: user.email },
              { label: "Nuova Password", value: data.temp_password, copyable: true },
            ],
          });
        } catch (e) { console.error(e); }
        break;
      case "resend_password":
        try {
          const res = await apiFetch(`/admin/users/${user.id}/reset-password/`, { method: "POST" });
          const data = await res.json();
          setInfoModal({
            title: "Password Reinviata",
            lines: [
              { label: "Utente", value: `${user.firstName} ${user.lastName}` },
              { label: "Email", value: user.email },
              { label: "Nuova Password", value: data.temp_password, copyable: true },
              { label: "Stato", value: "✅ Email inviata con nuova password temporanea" },
            ],
          });
        } catch (e) {
          setInfoModal({ title: "Errore", lines: [{ label: "Dettaglio", value: "Impossibile reinviare la password" }] });
        }
        break;
      default: break;
    }
  };

  const handleSaveEdit = async () => {
    try {
      if (editingUser.id === "new") {
        const res = await apiFetch("/admin/users/create/", {
          method: "POST",
          body: JSON.stringify({
            first_name: editForm.firstName,
            last_name: editForm.lastName,
            email: editForm.email,
            approval_status: editForm.status || "approved",
          }),
        });
        const data = await res.json();
        if (res.ok) {
          // Sincronizza gruppi
          if (selectedGroupIds.length > 0) {
            await apiFetch(`/admin/users/${data.id}/sync-groups/`, {
              method: "POST",
              body: JSON.stringify({ group_ids: selectedGroupIds }),
            });
          }
          setInfoModal({
            title: "Utente Creato con Successo",
            lines: [
              { label: "Email", value: data.email, copyable: true },
              { label: "Password Temporanea", value: data.temp_password, copyable: true },
              { label: "Stato Email", value: data.email_sent ? "✅ Email inviata" : "⚠️ Email non inviata" },
            ],
          });
          // Ricarica utenti
          const usersRes = await apiFetch("/admin/users/");
          const usersData = await usersRes.json();
          const usersList = Array.isArray(usersData) ? usersData : [];
          setUsers(usersList.map(u => ({
            id: u.id, firstName: u.first_name || u.username, lastName: u.last_name || "",
            email: u.email, group: u.groups?.length > 0 ? u.groups.map(g => g.name).join(", ") : "Nessun gruppo",
            createdAt: u.date_joined || "2026-01-01", device: "-",
            status: u.approval_status || "active", avatar: u.avatar, isOnline: u.is_online, groups: u.groups || [],
          })));
        } else {
          setInfoModal({ title: "Errore", lines: [{ label: "Dettaglio", value: data.error || "Errore nella creazione" }] });
          return;
        }
      } else {
        // Aggiorna dati utente
        await apiFetch(`/admin/users/${editForm.id}/`, {
          method: "PATCH",
          body: JSON.stringify({
            first_name: editForm.firstName,
            last_name: editForm.lastName,
            email: editForm.email,
            approval_status: editForm.status,
          }),
        });
        // Sincronizza gruppi (rimuove dai vecchi, aggiunge ai nuovi)
        await apiFetch(`/admin/users/${editForm.id}/sync-groups/`, {
          method: "POST",
          body: JSON.stringify({ group_ids: selectedGroupIds }),
        });
        // Ricarica utenti
        const usersRes = await apiFetch("/admin/users/");
        const usersData = await usersRes.json();
        const usersList = Array.isArray(usersData) ? usersData : [];
        setUsers(usersList.map(u => ({
          id: u.id, firstName: u.first_name || u.username, lastName: u.last_name || "",
          email: u.email, group: u.groups?.length > 0 ? u.groups.map(g => g.name).join(", ") : "Nessun gruppo",
          createdAt: u.date_joined || "2026-01-01", device: "-",
          status: u.approval_status || "active", avatar: u.avatar, isOnline: u.is_online, groups: u.groups || [],
        })));
        // Aggiorna selectedUser
        if (selectedUser) {
          const fresh = usersList.find(u => u.id === selectedUser.id);
          if (fresh) {
            setSelectedUser({
              id: fresh.id, firstName: fresh.first_name || fresh.username, lastName: fresh.last_name || "",
              email: fresh.email, group: fresh.groups?.length > 0 ? fresh.groups.map(g => g.name).join(", ") : "Nessun gruppo",
              createdAt: fresh.date_joined || "2026-01-01", device: "-",
              status: fresh.approval_status || "active", avatar: fresh.avatar, isOnline: fresh.is_online, groups: fresh.groups || [],
            });
          }
        }
      }
      setEditingUser(null);
      setEditForm({});
      setSelectedGroupIds([]);
    } catch (e) { console.error(e); }
  };

  const totalActive = users.filter(u => u.status === "active" || u.status === "approved").length;
  const totalPending = users.filter(u => u.status === "pending").length;
  const totalBlocked = users.filter(u => u.status === "blocked").length;

  return (
    <div style={{ padding: "28px 32px" }}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 16, marginBottom: 24 }}>
        {[
          { label: "Totale Utenti", value: users.length, color: T.teal },
          { label: "Attivi", value: totalActive, color: T.green },
          { label: "Da autorizzare", value: totalPending, color: T.orange },
          { label: "Bloccati", value: totalBlocked, color: T.red },
        ].map((s, i) => (
          <div key={i} style={{ background: T.card, borderRadius: T.radiusSm, padding: "16px 20px", border: `1px solid ${T.border}`, boxShadow: T.shadow, display: "flex", alignItems: "center", gap: 14 }}>
            <div style={{ width: 10, height: 10, borderRadius: "50%", background: s.color, boxShadow: `0 0 8px ${s.color}40` }} />
            <div>
              <div style={{ fontSize: 22, fontWeight: 800, color: T.text }}>{s.value}</div>
              <div style={{ fontSize: 12, color: T.textMuted, fontWeight: 500, textTransform: "uppercase" }}>{s.label}</div>
            </div>
          </div>
        ))}
      </div>

      <div style={{ background: T.card, borderRadius: T.radius, border: `1px solid ${T.border}`, boxShadow: T.shadow, marginBottom: 0 }}>
        <div style={{ padding: "16px 24px", display: "flex", alignItems: "center", justifyContent: "space-between", borderBottom: `1px solid ${T.border}` }}>
          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, background: T.bg, borderRadius: 10, padding: "8px 14px", border: `1px solid ${T.border}` }}>
              <IconSearch />
              <input value={searchQuery} onChange={e => setSearchQuery(e.target.value)} placeholder="Cerca utente..." style={{ border: "none", outline: "none", background: "transparent", fontSize: 13, color: T.text, width: 200, fontFamily: "inherit" }} />
            </div>
            <div style={{ display: "flex", gap: 4 }}>
              {[{ key: "all", label: "Tutti" }, { key: "active", label: "Attivi" }, { key: "pending", label: "In attesa" }, { key: "blocked", label: "Bloccati" }].map(f => (
                <button key={f.key} onClick={() => setStatusFilter(f.key)} style={{ padding: "6px 14px", borderRadius: 8, border: `1px solid ${statusFilter === f.key ? T.teal : T.border}`, background: statusFilter === f.key ? `${T.teal}10` : "transparent", color: statusFilter === f.key ? T.teal : T.textMuted, fontSize: 13, fontWeight: 500, cursor: "pointer", fontFamily: "inherit", transition: "all 0.2s" }}>{f.label}</button>
              ))}
            </div>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <div style={{ fontSize: 13, color: T.textMuted }}>{filteredUsers.length} utenti trovati</div>
            <button onClick={() => { setEditForm({ firstName: "", lastName: "", email: "", status: "approved" }); setSelectedGroupIds([]); setEditingUser({ id: "new" }); }} style={{ padding: "8px 16px", borderRadius: 10, border: "none", background: T.gradient, color: "#fff", fontSize: 13, fontWeight: 600, cursor: "pointer", fontFamily: "inherit" }}>+ Nuovo Utente</button>
          </div>
        </div>

        <div style={{ overflowX: "auto", overflowY: "visible", position: "relative" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead>
              <tr style={{ borderBottom: `1px solid ${T.border}` }}>
                {["ID", "Nome", "Cognome", "Email", "Gruppo", "Data Creazione", "Device", "Stato", ""].map((h, i) => (
                  <th key={i} style={{ padding: "12px 16px", textAlign: "left", fontSize: 11, fontWeight: 600, color: T.textMuted, textTransform: "uppercase", letterSpacing: "0.5px", whiteSpace: "nowrap" }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filteredUsers.map(user => {
                const st = statusConfig[user.status];
                return (
                  <tr key={user.id} onClick={() => setSelectedUser(user)} style={{ borderBottom: `1px solid ${T.border}`, cursor: "pointer", transition: "background 0.15s" }}
                    onMouseEnter={e => e.currentTarget.style.background = T.bg}
                    onMouseLeave={e => e.currentTarget.style.background = "transparent"}>
                    <td style={{ padding: "14px 16px", fontSize: 13, color: T.textMuted, fontWeight: 500 }}>#{user.id}</td>
                    <td style={{ padding: "14px 16px", fontSize: 13, fontWeight: 600, color: T.text }}>{user.firstName}</td>
                    <td style={{ padding: "14px 16px", fontSize: 13, fontWeight: 600, color: T.text }}>{user.lastName}</td>
                    <td style={{ padding: "14px 16px", fontSize: 13, color: T.textMuted }}>{user.email}</td>
                    <td style={{ padding: "14px 16px" }}>
                      <span style={{ padding: "4px 10px", borderRadius: 6, background: `${T.teal}10`, color: T.teal, fontSize: 12, fontWeight: 600 }}>{user.group}</span>
                    </td>
                    <td style={{ padding: "14px 16px", fontSize: 13, color: T.textMuted }}>{new Date(user.createdAt).toLocaleDateString("it-IT")}</td>
                    <td style={{ padding: "14px 16px", fontSize: 13, color: T.textMuted }}>{user.device}</td>
                    <td style={{ padding: "14px 16px" }}>
                      <span style={{ padding: "4px 12px", borderRadius: 20, background: st.bg, color: st.color, fontSize: 12, fontWeight: 600, display: "inline-flex", alignItems: "center", gap: 5 }}>
                        <span style={{ width: 6, height: 6, borderRadius: "50%", background: st.color }} />
                        {st.label}
                      </span>
                    </td>
                    <td style={{ padding: "14px 8px", position: "relative" }} onClick={e => e.stopPropagation()}>
                      <button onClick={() => setOpenMenuId(openMenuId === user.id ? null : user.id)} style={{ width: 32, height: 32, borderRadius: 8, border: `1px solid ${T.border}`, background: openMenuId === user.id ? T.bg : "transparent", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", color: T.textMuted, fontFamily: "inherit", transition: "all 0.2s" }}>
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="5" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="12" cy="19" r="2"/></svg>
                      </button>
                      {openMenuId === user.id && (
                        <div ref={menuRef} style={{ position: "fixed", right: 60, zIndex: 9999, background: T.card, borderRadius: 12, boxShadow: "0 8px 30px rgba(0,0,0,0.12)", border: `1px solid ${T.border}`, padding: "6px", minWidth: 180, animation: "fadeIn 0.15s ease" }}>
                          {[
                            { label: "Modifica", icon: <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>, action: "edit" },
                            { label: "Reset Password", icon: <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M12.65 10C11.83 7.67 9.61 6 7 6c-3.31 0-6 2.69-6 6s2.69 6 6 6c2.61 0 4.83-1.67 5.65-4H17v4h4v-4h2v-4H12.65zM7 14c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2z"/></svg>, action: "reset_password" },
                            { label: "Reinvia Password", icon: <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M20 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 4l-8 5-8-5V6l8 5 8-5v2z"/></svg>, action: "resend_password" },
                            { label: user.status === "blocked" ? "Sblocca" : "Blocca", icon: <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d={user.status === "blocked" ? "M12 17c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm6-9h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6h1.9c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm0 12H6V10h12v10z" : "M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z"}/></svg>, action: "toggle_block" },
                            { label: "Elimina", icon: <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>, action: "delete", danger: true },
                          ].map((item, i) => (
                            <button key={i} onClick={() => handleAction(item.action, user)} style={{ width: "100%", padding: "10px 14px", display: "flex", alignItems: "center", gap: 10, border: "none", background: "transparent", cursor: "pointer", borderRadius: 8, fontSize: 13, fontWeight: 500, color: item.danger ? T.red : T.text, fontFamily: "inherit", transition: "background 0.15s" }}
                              onMouseEnter={e => e.currentTarget.style.background = item.danger ? "#FFEBEE" : T.bg}
                              onMouseLeave={e => e.currentTarget.style.background = "transparent"}>
                              <span style={{ display: "flex", alignItems: "center" }}>{item.icon}</span>
                              {item.label}
                            </button>
                          ))}
                        </div>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {selectedUser && !editingUser && (
        <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.4)", backdropFilter: "blur(4px)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1000 }} onClick={() => setSelectedUser(null)}>
          <div style={{ background: T.card, borderRadius: 20, padding: 0, width: 520, maxHeight: "85vh", overflow: "auto", boxShadow: "0 20px 60px rgba(0,0,0,0.15)", animation: "modalIn 0.25s ease" }} onClick={e => e.stopPropagation()}>
            <div style={{ padding: "24px 28px", borderBottom: `1px solid ${T.border}`, display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <div style={{ fontSize: 18, fontWeight: 800, color: T.text }}>Dettaglio Utente</div>
              <div style={{ display: "flex", gap: 8 }}>
                <button onClick={() => { setEditForm({ ...selectedUser }); setEditingUser(selectedUser); }} style={{ padding: "8px 16px", borderRadius: 10, border: "none", background: T.teal, color: "#fff", fontSize: 13, fontWeight: 600, cursor: "pointer", fontFamily: "inherit" }}>Modifica</button>
                <button onClick={() => setSelectedUser(null)} style={{ width: 36, height: 36, borderRadius: 10, border: `1px solid ${T.border}`, background: "transparent", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", color: T.textMuted, fontFamily: "inherit", fontSize: 18 }}>✕</button>
              </div>
            </div>
            <div style={{ padding: "24px 28px" }}>
              <div style={{ display: "flex", alignItems: "center", gap: 16, marginBottom: 24 }}>
                <div style={{ width: 60, height: 60, borderRadius: 16, background: T.gradient, display: "flex", alignItems: "center", justifyContent: "center", color: "#fff", fontSize: 22, fontWeight: 700 }}>{selectedUser.firstName[0]}{selectedUser.lastName[0]}</div>
                <div>
                  <div style={{ fontSize: 20, fontWeight: 800, color: T.text }}>{selectedUser.firstName} {selectedUser.lastName}</div>
                  <div style={{ fontSize: 13, color: T.textMuted }}>{selectedUser.email}</div>
                </div>
              </div>
              {[
                { label: "ID Utente", value: `#${selectedUser.id}` },
                { label: "Nome", value: selectedUser.firstName },
                { label: "Cognome", value: selectedUser.lastName },
                { label: "Email", value: selectedUser.email },
                { label: "Gruppo", value: selectedUser.group },
                { label: "Data Creazione", value: new Date(selectedUser.createdAt).toLocaleDateString("it-IT") },
                { label: "Device", value: selectedUser.device },
                { label: "Stato", value: statusConfig[selectedUser.status].label, color: statusConfig[selectedUser.status].color },
              ].map((field, i) => (
                <div key={i} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "12px 0", borderBottom: i < 7 ? `1px solid ${T.border}` : "none" }}>
                  <span style={{ fontSize: 13, color: T.textMuted, fontWeight: 500 }}>{field.label}</span>
                  <span style={{ fontSize: 13, color: field.color || T.text, fontWeight: 600 }}>{field.value}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}

      {editingUser && (
        <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.4)", backdropFilter: "blur(4px)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1000 }} onClick={() => setEditingUser(null)}>
          <div style={{ background: T.card, borderRadius: 20, padding: 0, width: 520, maxHeight: "85vh", overflow: "auto", boxShadow: "0 20px 60px rgba(0,0,0,0.15)" }} onClick={e => e.stopPropagation()}>
            <div style={{ padding: "24px 28px", borderBottom: `1px solid ${T.border}`, display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <div style={{ fontSize: 18, fontWeight: 800, color: T.text }}>{editingUser.id === "new" ? "Nuovo Utente" : "Modifica Utente"}</div>
              <button onClick={() => setEditingUser(null)} style={{ width: 36, height: 36, borderRadius: 10, border: `1px solid ${T.border}`, background: "transparent", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", color: T.textMuted, fontFamily: "inherit", fontSize: 18 }}>✕</button>
            </div>
            <div style={{ padding: "24px 28px", display: "flex", flexDirection: "column", gap: 16 }}>
              {[
                { key: "firstName", label: "Nome" },
                { key: "lastName", label: "Cognome" },
                { key: "email", label: "Email" },
              ].map(field => (
                <div key={field.key}>
                  <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.textMuted, marginBottom: 6, textTransform: "uppercase", letterSpacing: "0.5px" }}>{field.label}</label>
                  <input value={editForm[field.key] || ""} onChange={e => setEditForm(prev => ({ ...prev, [field.key]: e.target.value }))} style={{ width: "100%", padding: "10px 14px", borderRadius: 10, border: `1px solid ${T.border}`, fontSize: 14, color: T.text, fontFamily: "inherit", outline: "none", transition: "border 0.2s", boxSizing: "border-box" }}
                    onFocus={e => e.target.style.borderColor = T.teal}
                    onBlur={e => e.target.style.borderColor = T.border} />
                </div>
              ))}
              <div>
                <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.textMuted, marginBottom: 6, textTransform: "uppercase", letterSpacing: "0.5px" }}>Gruppi</label>
                <div style={{ border: `1px solid ${T.border}`, borderRadius: 10, padding: 8, maxHeight: 160, overflowY: "auto" }}>
                  {availableGroups.length === 0 ? (
                    <div style={{ padding: "8px 6px", fontSize: 13, color: T.textMuted }}>Nessun gruppo disponibile. Crea prima un gruppo.</div>
                  ) : (
                    availableGroups.map(g => {
                      const isSelected = selectedGroupIds.includes(g.id);
                      return (
                        <div key={g.id} onClick={() => setSelectedGroupIds(prev => isSelected ? prev.filter(id => id !== g.id) : [...prev, g.id])}
                          style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 6px", borderRadius: 8, cursor: "pointer", transition: "background 0.15s" }}
                          onMouseEnter={e => e.currentTarget.style.background = T.bg}
                          onMouseLeave={e => e.currentTarget.style.background = "transparent"}>
                          <div style={{ width: 20, height: 20, borderRadius: 5, border: `2px solid ${isSelected ? T.teal : T.border}`, background: isSelected ? T.teal : "transparent", display: "flex", alignItems: "center", justifyContent: "center", transition: "all 0.2s", flexShrink: 0 }}>
                            {isSelected && <svg width="12" height="12" viewBox="0 0 24 24" fill="white"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>}
                          </div>
                          <div style={{ flex: 1 }}>
                            <div style={{ fontSize: 13, fontWeight: 600, color: T.text }}>{g.name}</div>
                            {g.description && <div style={{ fontSize: 11, color: T.textMuted }}>{g.description}</div>}
                          </div>
                          <div style={{ fontSize: 11, color: T.textMuted }}>{g.member_count || 0} membri</div>
                        </div>
                      );
                    })
                  )}
                </div>
                {selectedGroupIds.length > 0 && (
                  <div style={{ marginTop: 6, fontSize: 12, color: T.teal, fontWeight: 500 }}>{selectedGroupIds.length} gruppo/i selezionato/i</div>
                )}
              </div>
              <div>
                <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.textMuted, marginBottom: 6, textTransform: "uppercase", letterSpacing: "0.5px" }}>Stato</label>
                <select value={editForm.status === "active" ? "approved" : (editForm.status || "")} onChange={e => setEditForm(prev => ({ ...prev, status: e.target.value }))} style={{ width: "100%", padding: "10px 14px", borderRadius: 10, border: `1px solid ${T.border}`, fontSize: 14, color: T.text, fontFamily: "inherit", outline: "none", background: T.card, cursor: "pointer", boxSizing: "border-box" }}>
                  <option value="approved">Attivo</option>
                  <option value="pending">Da autorizzare</option>
                  <option value="blocked">Bloccato</option>
                </select>
              </div>
            </div>
            <div style={{ padding: "16px 28px 24px", display: "flex", justifyContent: "flex-end", gap: 10, borderTop: `1px solid ${T.border}` }}>
              <button onClick={() => setEditingUser(null)} style={{ padding: "10px 20px", borderRadius: 10, border: `1px solid ${T.border}`, background: "transparent", color: T.textMuted, fontSize: 14, fontWeight: 600, cursor: "pointer", fontFamily: "inherit" }}>Annulla</button>
              <button onClick={handleSaveEdit} style={{ padding: "10px 24px", borderRadius: 10, border: "none", background: T.gradient, color: "#fff", fontSize: 14, fontWeight: 600, cursor: "pointer", fontFamily: "inherit", boxShadow: "0 4px 12px rgba(42,191,191,0.3)" }}>Salva Modifiche</button>
            </div>
          </div>
        </div>
      )}

      {confirmAction && (
        <ConfirmModal
          title={confirmAction.title}
          message={confirmAction.message}
          warning={confirmAction.warning}
          confirmLabel={confirmAction.confirmLabel}
          confirmColor={confirmAction.confirmColor}
          onConfirm={confirmAction.onConfirm}
          onCancel={() => setConfirmAction(null)}
        />
      )}

      {infoModal && (
        <InfoModal
          title={infoModal.title}
          lines={infoModal.lines}
          onClose={() => setInfoModal(null)}
        />
      )}

      <style>{`
        @keyframes fadeIn { from { opacity: 0; transform: translateY(-8px); } to { opacity: 1; transform: translateY(0); } }
        @keyframes modalIn { from { opacity: 0; transform: scale(0.95); } to { opacity: 1; transform: scale(1); } }
      `}</style>
    </div>
  );
}

function GroupsPage() {
  const [groups, setGroups] = useState([]);
  const [allUsers, setAllUsers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [openMenuId, setOpenMenuId] = useState(null);
  const [selectedGroup, setSelectedGroup] = useState(null);
  const [editingGroup, setEditingGroup] = useState(null);
  const [editForm, setEditForm] = useState({});
  const [membersModal, setMembersModal] = useState(null); // { group, type: 'users' | 'devices' }
  const [assignModal, setAssignModal] = useState(null);
  const [selectedUserIds, setSelectedUserIds] = useState([]);
  const [assignSearch, setAssignSearch] = useState("");
  const [confirmAction, setConfirmAction] = useState(null);
  const [infoModal, setInfoModal] = useState(null);
  const menuRef = useRef(null);

  useEffect(() => {
    loadGroups();
    loadAllUsers();
  }, []);

  async function loadGroups() {
    try {
      const res = await apiFetch("/admin/groups/");
      const data = await res.json();
      const mapped = (Array.isArray(data) ? data : []).map(g => ({
        id: g.id,
        name: g.name,
        description: g.description,
        status: g.is_active ? "active" : "inactive",
        members: (g.members || []).map(m => ({
          id: m.id,
          firstName: m.first_name || "",
          lastName: m.last_name || "",
          email: m.email,
          avatar: m.avatar,
          device: "-",
        })),
        createdAt: g.created_at,
      }));
      setGroups(mapped);
    } catch (e) { console.error(e); }
    setLoading(false);
  }

  async function loadAllUsers() {
    try {
      const res = await apiFetch("/admin/users/");
      const data = await res.json();
      setAllUsers(Array.isArray(data) ? data : []);
    } catch (e) { console.error(e); }
  }

  useEffect(() => {
    const handler = (e) => {
      if (menuRef.current && !menuRef.current.contains(e.target)) {
        setOpenMenuId(null);
      }
    };
    document.addEventListener("click", handler);
    return () => document.removeEventListener("click", handler);
  }, []);

  const filteredGroups = groups.filter(g => {
    const matchSearch = `${g.name} ${g.id} ${g.description}`.toLowerCase().includes(searchQuery.toLowerCase());
    const matchStatus = statusFilter === "all" || g.status === statusFilter;
    return matchSearch && matchStatus;
  });

  const handleAction = async (action, group) => {
    setOpenMenuId(null);
    switch (action) {
      case "edit":
        setEditForm({ ...group });
        setEditingGroup(group);
        break;
      case "delete":
        setConfirmAction({
          title: "Elimina Gruppo Definitivamente",
          message: `Stai per eliminare il gruppo "${group.name}". Tutte le associazioni utente-gruppo verranno rimosse.`,
          warning: "Questa azione è IRREVERSIBILE. Gli utenti che appartenevano solo a questo gruppo non potranno più chattare fino a quando non verranno assegnati ad un altro gruppo.",
          confirmLabel: "Elimina Gruppo",
          confirmColor: T.red,
          onConfirm: async () => {
            try {
              await apiFetch(`/admin/groups/${group.id}/`, { method: "DELETE" });
              setGroups(prev => prev.filter(g => g.id !== group.id));
            } catch (e) { console.error(e); }
            setConfirmAction(null);
          },
        });
        break;
      case "toggle_block":
        try {
          const newActive = group.status === "inactive";
          await apiFetch(`/admin/groups/${group.id}/`, {
            method: "PATCH",
            body: JSON.stringify({ is_active: newActive }),
          });
          setGroups(prev => prev.map(g => g.id === group.id ? { ...g, status: newActive ? "active" : "inactive" } : g));
        } catch (e) { console.error(e); }
        break;
      case "assign":
        setSelectedUserIds(group.members.map(m => m.id));
        setAssignModal(group);
        break;
      default: break;
    }
  };

  const handleSaveEdit = async () => {
    try {
      if (editingGroup.id === "new") {
        const res = await apiFetch("/admin/groups/", {
          method: "POST",
          body: JSON.stringify({ name: editForm.name, description: editForm.description }),
        });
        const data = await res.json();
        if (res.ok) {
          await loadGroups();
        } else {
          setInfoModal({ title: "Errore", lines: [{ label: "Dettaglio", value: data.error || "Errore nella creazione" }] });
          return;
        }
      } else {
        await apiFetch(`/admin/groups/${editForm.id}/`, {
          method: "PATCH",
          body: JSON.stringify({ name: editForm.name, description: editForm.description, is_active: editForm.status === "active" }),
        });
        await loadGroups();
      }
      setEditingGroup(null);
      setEditForm({});
    } catch (e) { console.error(e); }
  };

  const getUniqueDevices = (members) => {
    const devices = {};
    members.forEach(m => { if (m.device) devices[m.device] = (devices[m.device] || 0) + 1; });
    return Object.keys(devices).length;
  };

  const totalActive = groups.filter(g => g.status === "active").length;
  const totalInactive = groups.filter(g => g.status === "inactive").length;
  const totalMembers = groups.reduce((sum, g) => sum + g.members.length, 0);

  return (
    <div style={{ padding: "28px 32px" }}>
      {/* Header Stats */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 16, marginBottom: 24 }}>
        {[
          { label: "Totale Gruppi", value: groups.length, color: T.teal },
          { label: "Attivi", value: totalActive, color: T.green },
          { label: "Spenti", value: totalInactive, color: T.textMuted },
          { label: "Tot. Membri", value: totalMembers, color: T.purple },
        ].map((s, i) => (
          <div key={i} style={{ background: T.card, borderRadius: T.radiusSm, padding: "16px 20px", border: `1px solid ${T.border}`, boxShadow: T.shadow, display: "flex", alignItems: "center", gap: 14 }}>
            <div style={{ width: 10, height: 10, borderRadius: "50%", background: s.color, boxShadow: `0 0 8px ${s.color}40` }} />
            <div>
              <div style={{ fontSize: 22, fontWeight: 800, color: T.text }}>{s.value}</div>
              <div style={{ fontSize: 12, color: T.textMuted, fontWeight: 500, textTransform: "uppercase" }}>{s.label}</div>
            </div>
          </div>
        ))}
      </div>

      {/* Table Card */}
      <div style={{ background: T.card, borderRadius: T.radius, border: `1px solid ${T.border}`, boxShadow: T.shadow }}>
        <div style={{ padding: "16px 24px", display: "flex", alignItems: "center", justifyContent: "space-between", borderBottom: `1px solid ${T.border}` }}>
          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, background: T.bg, borderRadius: 10, padding: "8px 14px", border: `1px solid ${T.border}` }}>
              <IconSearch />
              <input value={searchQuery} onChange={e => setSearchQuery(e.target.value)} placeholder="Cerca gruppo..." style={{ border: "none", outline: "none", background: "transparent", fontSize: 13, color: T.text, width: 200, fontFamily: "inherit" }} />
            </div>
            <div style={{ display: "flex", gap: 4 }}>
              {[{ key: "all", label: "Tutti" }, { key: "active", label: "Attivi" }, { key: "inactive", label: "Spenti" }].map(f => (
                <button key={f.key} onClick={() => setStatusFilter(f.key)} style={{ padding: "6px 14px", borderRadius: 8, border: `1px solid ${statusFilter === f.key ? T.teal : T.border}`, background: statusFilter === f.key ? `${T.teal}10` : "transparent", color: statusFilter === f.key ? T.teal : T.textMuted, fontSize: 13, fontWeight: 500, cursor: "pointer", fontFamily: "inherit", transition: "all 0.2s" }}>{f.label}</button>
              ))}
            </div>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <div style={{ fontSize: 13, color: T.textMuted }}>{filteredGroups.length} gruppi trovati</div>
            <button onClick={() => { setEditForm({ name: "", description: "", status: "active" }); setEditingGroup({ id: "new" }); }} style={{ padding: "8px 16px", borderRadius: 10, border: "none", background: T.gradient, color: "#fff", fontSize: 13, fontWeight: 600, cursor: "pointer", fontFamily: "inherit" }}>+ Nuovo Gruppo</button>
          </div>
        </div>

        <div style={{ overflowX: "auto", overflowY: "visible", position: "relative" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead>
              <tr style={{ borderBottom: `1px solid ${T.border}` }}>
                {["Codice", "Nome Gruppo", "Descrizione", "Stato", "N. Utenti", "N. Devices", ""].map((h, i) => (
                  <th key={i} style={{ padding: "12px 16px", textAlign: "left", fontSize: 11, fontWeight: 600, color: T.textMuted, textTransform: "uppercase", letterSpacing: "0.5px", whiteSpace: "nowrap" }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filteredGroups.map(group => {
                const st = groupStatusConfig[group.status];
                const deviceCount = getUniqueDevices(group.members);
                return (
                  <tr key={group.id} onClick={() => setSelectedGroup(group)} style={{ borderBottom: `1px solid ${T.border}`, cursor: "pointer", transition: "background 0.15s" }}
                    onMouseEnter={e => e.currentTarget.style.background = T.bg}
                    onMouseLeave={e => e.currentTarget.style.background = "transparent"}>
                    <td style={{ padding: "14px 16px", fontSize: 13, color: T.teal, fontWeight: 600, fontFamily: "monospace" }}>{group.id}</td>
                    <td style={{ padding: "14px 16px", fontSize: 13, fontWeight: 700, color: T.text }}>{group.name}</td>
                    <td style={{ padding: "14px 16px", fontSize: 13, color: T.textMuted, maxWidth: 250, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{group.description}</td>
                    <td style={{ padding: "14px 16px" }}>
                      <span style={{ padding: "4px 12px", borderRadius: 20, background: st.bg, color: st.color, fontSize: 12, fontWeight: 600, display: "inline-flex", alignItems: "center", gap: 5 }}>
                        <span style={{ width: 6, height: 6, borderRadius: "50%", background: st.color }} />
                        {st.label}
                      </span>
                    </td>
                    <td style={{ padding: "14px 16px" }} onClick={e => { e.stopPropagation(); setMembersModal({ group, type: "users" }); }}>
                      <span style={{ padding: "4px 12px", borderRadius: 8, background: `${T.purple}10`, color: T.purple, fontSize: 13, fontWeight: 700, cursor: "pointer", transition: "all 0.2s", display: "inline-block" }}
                        onMouseEnter={e => { e.currentTarget.style.background = `${T.purple}25`; e.currentTarget.style.transform = "scale(1.05)"; }}
                        onMouseLeave={e => { e.currentTarget.style.background = `${T.purple}10`; e.currentTarget.style.transform = "scale(1)"; }}>
                        {group.members.length} <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" style={{marginLeft:4,verticalAlign:"middle"}}><path d="M16 11c1.66 0 2.99-1.34 2.99-3S17.66 5 16 5c-1.66 0-3 1.34-3 3s1.34 3 3 3zm-8 0c1.66 0 2.99-1.34 2.99-3S9.66 5 8 5C6.34 5 5 6.34 5 8s1.34 3 3 3zm0 2c-2.33 0-7 1.17-7 3.5V19h14v-2.5c0-2.33-4.67-3.5-7-3.5zm8 0c-.29 0-.62.02-.97.05 1.16.84 1.97 1.97 1.97 3.45V19h6v-2.5c0-2.33-4.67-3.5-7-3.5z"/></svg>
                      </span>
                    </td>
                    <td style={{ padding: "14px 16px" }} onClick={e => { e.stopPropagation(); setMembersModal({ group, type: "devices" }); }}>
                      <span style={{ padding: "4px 12px", borderRadius: 8, background: `${T.blue}10`, color: T.blue, fontSize: 13, fontWeight: 700, cursor: "pointer", transition: "all 0.2s", display: "inline-block" }}
                        onMouseEnter={e => { e.currentTarget.style.background = `${T.blue}25`; e.currentTarget.style.transform = "scale(1.05)"; }}
                        onMouseLeave={e => { e.currentTarget.style.background = `${T.blue}10`; e.currentTarget.style.transform = "scale(1)"; }}>
                        {deviceCount} <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" style={{marginLeft:4,verticalAlign:"middle"}}><path d="M17 1.01L7 1c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-1.99-2-1.99zM17 19H7V5h10v14z"/></svg>
                      </span>
                    </td>
                    <td style={{ padding: "14px 8px", position: "relative" }} onClick={e => e.stopPropagation()}>
                      <button onClick={(e) => { e.stopPropagation(); setOpenMenuId(openMenuId === group.id ? null : group.id); }} style={{ width: 32, height: 32, borderRadius: 8, border: `1px solid ${T.border}`, background: openMenuId === group.id ? T.bg : "transparent", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", color: T.textMuted, fontFamily: "inherit", transition: "all 0.2s" }}>
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="5" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="12" cy="19" r="2"/></svg>
                      </button>
                      {openMenuId === group.id && (
                        <div ref={menuRef} style={{ position: "fixed", right: 60, zIndex: 9999, background: T.card, borderRadius: 12, boxShadow: "0 8px 30px rgba(0,0,0,0.12)", border: `1px solid ${T.border}`, padding: 6, minWidth: 200, animation: "fadeIn 0.15s ease" }}>
                          <button onClick={() => handleAction("assign", group)} style={{ width: "100%", padding: "10px 14px", display: "flex", alignItems: "center", gap: 10, border: "none", background: "transparent", cursor: "pointer", borderRadius: 8, fontSize: 13, fontWeight: 500, color: T.text, fontFamily: "inherit", transition: "background 0.15s" }}
                            onMouseEnter={e => e.currentTarget.style.background = T.bg}
                            onMouseLeave={e => e.currentTarget.style.background = "transparent"}>
                            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M15 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm-9-2V7H4v3H1v2h3v3h2v-3h3v-2H6zm9 4c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>
                            Assegna Utenti
                          </button>
                          <button onClick={() => handleAction("edit", group)} style={{ width: "100%", padding: "10px 14px", display: "flex", alignItems: "center", gap: 10, border: "none", background: "transparent", cursor: "pointer", borderRadius: 8, fontSize: 13, fontWeight: 500, color: T.text, fontFamily: "inherit", transition: "background 0.15s" }}
                            onMouseEnter={e => e.currentTarget.style.background = T.bg}
                            onMouseLeave={e => e.currentTarget.style.background = "transparent"}>
                            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>
                            Modifica
                          </button>
                          <button onClick={() => handleAction("toggle_block", group)} style={{ width: "100%", padding: "10px 14px", display: "flex", alignItems: "center", gap: 10, border: "none", background: "transparent", cursor: "pointer", borderRadius: 8, fontSize: 13, fontWeight: 500, color: T.text, fontFamily: "inherit", transition: "background 0.15s" }}
                            onMouseEnter={e => e.currentTarget.style.background = T.bg}
                            onMouseLeave={e => e.currentTarget.style.background = "transparent"}>
                            <svg width="16" height="16" viewBox="0 0 24 24" fill={group.status === "inactive" ? "#4CAF50" : "#9E9E9E"}><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>
                            {group.status === "inactive" ? "Attiva" : "Disattiva"}
                          </button>
                          <div style={{ height: 1, background: T.border, margin: "4px 0" }} />
                          <button onClick={() => handleAction("delete", group)} style={{ width: "100%", padding: "10px 14px", display: "flex", alignItems: "center", gap: 10, border: "none", background: "transparent", cursor: "pointer", borderRadius: 8, fontSize: 13, fontWeight: 500, color: T.red, fontFamily: "inherit", transition: "background 0.15s" }}
                            onMouseEnter={e => e.currentTarget.style.background = "#FFEBEE"}
                            onMouseLeave={e => e.currentTarget.style.background = "transparent"}>
                            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                            Elimina
                          </button>
                        </div>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {/* View Group Modal */}
      {selectedGroup && !editingGroup && (
        <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.4)", backdropFilter: "blur(4px)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1000 }} onClick={() => setSelectedGroup(null)}>
          <div style={{ background: T.card, borderRadius: 20, width: 520, maxHeight: "85vh", overflow: "auto", boxShadow: "0 20px 60px rgba(0,0,0,0.15)" }} onClick={e => e.stopPropagation()}>
            <div style={{ padding: "24px 28px", borderBottom: `1px solid ${T.border}`, display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <div style={{ fontSize: 18, fontWeight: 800, color: T.text }}>Dettaglio Gruppo</div>
              <div style={{ display: "flex", gap: 8 }}>
                <button onClick={() => { setEditForm({ ...selectedGroup }); setEditingGroup(selectedGroup); }} style={{ padding: "8px 16px", borderRadius: 10, border: "none", background: T.teal, color: "#fff", fontSize: 13, fontWeight: 600, cursor: "pointer", fontFamily: "inherit" }}>Modifica</button>
                <button onClick={() => setSelectedGroup(null)} style={{ width: 36, height: 36, borderRadius: 10, border: `1px solid ${T.border}`, background: "transparent", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", color: T.textMuted, fontFamily: "inherit", fontSize: 18 }}>✕</button>
              </div>
            </div>
            <div style={{ padding: "24px 28px" }}>
              <div style={{ display: "flex", alignItems: "center", gap: 16, marginBottom: 24 }}>
                <div style={{ width: 60, height: 60, borderRadius: 16, background: T.gradient, display: "flex", alignItems: "center", justifyContent: "center", color: "#fff", fontSize: 20, fontWeight: 700 }}>{selectedGroup.name.substring(0, 2).toUpperCase()}</div>
                <div>
                  <div style={{ fontSize: 20, fontWeight: 800, color: T.text }}>{selectedGroup.name}</div>
                  <div style={{ fontSize: 13, color: T.textMuted }}>{selectedGroup.id}</div>
                </div>
              </div>
              {[
                { label: "Codice Gruppo", value: selectedGroup.id },
                { label: "Nome", value: selectedGroup.name },
                { label: "Descrizione", value: selectedGroup.description },
                { label: "Stato", value: groupStatusConfig[selectedGroup.status].label, color: groupStatusConfig[selectedGroup.status].color },
                { label: "N. Utenti", value: selectedGroup.members.length },
                { label: "N. Devices", value: getUniqueDevices(selectedGroup.members) },
              ].map((field, i) => (
                <div key={i} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "12px 0", borderBottom: i < 5 ? `1px solid ${T.border}` : "none" }}>
                  <span style={{ fontSize: 13, color: T.textMuted, fontWeight: 500 }}>{field.label}</span>
                  <span style={{ fontSize: 13, color: field.color || T.text, fontWeight: 600 }}>{field.value}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}

      {/* Edit Group Modal */}
      {editingGroup && (
        <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.4)", backdropFilter: "blur(4px)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1000 }} onClick={() => setEditingGroup(null)}>
          <div style={{ background: T.card, borderRadius: 20, width: 520, maxHeight: "85vh", overflow: "auto", boxShadow: "0 20px 60px rgba(0,0,0,0.15)" }} onClick={e => e.stopPropagation()}>
            <div style={{ padding: "24px 28px", borderBottom: `1px solid ${T.border}`, display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <div style={{ fontSize: 18, fontWeight: 800, color: T.text }}>{editingGroup.id === "new" ? "Nuovo Gruppo" : "Modifica Gruppo"}</div>
              <button onClick={() => setEditingGroup(null)} style={{ width: 36, height: 36, borderRadius: 10, border: `1px solid ${T.border}`, background: "transparent", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", color: T.textMuted, fontFamily: "inherit", fontSize: 18 }}>✕</button>
            </div>
            <div style={{ padding: "24px 28px", display: "flex", flexDirection: "column", gap: 16 }}>
              {[
                { key: "name", label: "Nome Gruppo" },
                { key: "description", label: "Descrizione", multiline: true },
              ].map(field => (
                <div key={field.key}>
                  <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.textMuted, marginBottom: 6, textTransform: "uppercase", letterSpacing: "0.5px" }}>{field.label}</label>
                  {field.multiline ? (
                    <textarea value={editForm[field.key] || ""} onChange={e => setEditForm(prev => ({ ...prev, [field.key]: e.target.value }))} rows={3} style={{ width: "100%", padding: "10px 14px", borderRadius: 10, border: `1px solid ${T.border}`, fontSize: 14, color: T.text, fontFamily: "inherit", outline: "none", resize: "vertical", boxSizing: "border-box" }}
                      onFocus={e => e.target.style.borderColor = T.teal} onBlur={e => e.target.style.borderColor = T.border} />
                  ) : (
                    <input value={editForm[field.key] || ""} onChange={e => setEditForm(prev => ({ ...prev, [field.key]: e.target.value }))} style={{ width: "100%", padding: "10px 14px", borderRadius: 10, border: `1px solid ${T.border}`, fontSize: 14, color: T.text, fontFamily: "inherit", outline: "none", boxSizing: "border-box" }}
                      onFocus={e => e.target.style.borderColor = T.teal} onBlur={e => e.target.style.borderColor = T.border} />
                  )}
                </div>
              ))}
              <div>
                <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.textMuted, marginBottom: 6, textTransform: "uppercase", letterSpacing: "0.5px" }}>Stato</label>
                <select value={editForm.status || ""} onChange={e => setEditForm(prev => ({ ...prev, status: e.target.value }))} style={{ width: "100%", padding: "10px 14px", borderRadius: 10, border: `1px solid ${T.border}`, fontSize: 14, color: T.text, fontFamily: "inherit", outline: "none", background: T.card, cursor: "pointer", boxSizing: "border-box" }}>
                  <option value="active">Attivo</option>
                  <option value="inactive">Spento</option>
                </select>
              </div>
            </div>
            <div style={{ padding: "16px 28px 24px", display: "flex", justifyContent: "flex-end", gap: 10, borderTop: `1px solid ${T.border}` }}>
              <button onClick={() => setEditingGroup(null)} style={{ padding: "10px 20px", borderRadius: 10, border: `1px solid ${T.border}`, background: "transparent", color: T.textMuted, fontSize: 14, fontWeight: 600, cursor: "pointer", fontFamily: "inherit" }}>Annulla</button>
              <button onClick={handleSaveEdit} style={{ padding: "10px 24px", borderRadius: 10, border: "none", background: T.gradient, color: "#fff", fontSize: 14, fontWeight: 600, cursor: "pointer", fontFamily: "inherit", boxShadow: "0 4px 12px rgba(42,191,191,0.3)" }}>Salva Modifiche</button>
            </div>
          </div>
        </div>
      )}

      {/* Members/Devices Modal */}
      {membersModal && (
        <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.4)", backdropFilter: "blur(4px)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1000 }} onClick={() => setMembersModal(null)}>
          <div style={{ background: T.card, borderRadius: 20, width: 560, maxHeight: "80vh", overflow: "hidden", boxShadow: "0 20px 60px rgba(0,0,0,0.15)", display: "flex", flexDirection: "column" }} onClick={e => e.stopPropagation()}>
            <div style={{ padding: "24px 28px", borderBottom: `1px solid ${T.border}`, display: "flex", alignItems: "center", justifyContent: "space-between", flexShrink: 0 }}>
              <div>
                <div style={{ fontSize: 18, fontWeight: 800, color: T.text }}>
                  {membersModal.type === "users" ? "Utenti del Gruppo" : "Dispositivi del Gruppo"}
                </div>
                <div style={{ fontSize: 13, color: T.textMuted, marginTop: 2 }}>{membersModal.group.name} — {membersModal.group.members.length} membri</div>
              </div>
              <button onClick={() => setMembersModal(null)} style={{ width: 36, height: 36, borderRadius: 10, border: `1px solid ${T.border}`, background: "transparent", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", color: T.textMuted, fontFamily: "inherit", fontSize: 18 }}>✕</button>
            </div>
            <div style={{ overflow: "auto", flex: 1 }}>
              {membersModal.group.members.length === 0 ? (
                <div style={{ padding: 40, textAlign: "center", color: T.textMuted, fontSize: 14 }}>Nessun membro nel gruppo</div>
              ) : (
                membersModal.group.members.map((member, i) => (
                  <div key={member.id} style={{ display: "flex", alignItems: "center", gap: 14, padding: "14px 28px", borderBottom: i < membersModal.group.members.length - 1 ? `1px solid ${T.border}` : "none", transition: "background 0.15s" }}
                    onMouseEnter={e => e.currentTarget.style.background = T.bg}
                    onMouseLeave={e => e.currentTarget.style.background = "transparent"}>
                    <div style={{ width: 44, height: 44, borderRadius: 12, background: T.gradient, display: "flex", alignItems: "center", justifyContent: "center", color: "#fff", fontSize: 16, fontWeight: 700, flexShrink: 0 }}>
                      {member.firstName[0]}{member.lastName[0]}
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontSize: 14, fontWeight: 600, color: T.text }}>{member.firstName} {member.lastName}</div>
                      <div style={{ fontSize: 12, color: T.textMuted, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{member.email}</div>
                    </div>
                    {membersModal.type === "devices" ? (
                      <div style={{ padding: "5px 12px", borderRadius: 8, background: `${T.blue}10`, color: T.blue, fontSize: 12, fontWeight: 600, whiteSpace: "nowrap", flexShrink: 0 }}>
                        <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style={{marginRight:4,verticalAlign:"middle"}}><path d="M17 1.01L7 1c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-1.99-2-1.99zM17 19H7V5h10v14z"/></svg> {member.device}
                      </div>
                    ) : (
                      <div style={{ fontSize: 12, color: T.textMuted, whiteSpace: "nowrap", flexShrink: 0 }}>{member.device}</div>
                    )}
                  </div>
                ))
              )}
            </div>
          </div>
        </div>
      )}

      {/* Assign Users Modal */}
      {assignModal && (
        <div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.4)", backdropFilter: "blur(4px)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1000 }} onClick={() => { setAssignModal(null); setAssignSearch(""); }}>
          <div style={{ background: T.card, borderRadius: 20, width: 560, maxHeight: "80vh", overflow: "hidden", boxShadow: "0 20px 60px rgba(0,0,0,0.15)", display: "flex", flexDirection: "column" }} onClick={e => e.stopPropagation()}>
            <div style={{ padding: "24px 28px", borderBottom: `1px solid ${T.border}`, flexShrink: 0 }}>
              <div style={{ fontSize: 18, fontWeight: 800, color: T.text }}>Assegna Utenti a "{assignModal.name}"</div>
              <div style={{ fontSize: 13, color: T.textMuted, marginTop: 4 }}>Seleziona gli utenti da assegnare al gruppo</div>
            </div>
            <div style={{ padding: "12px 28px 8px", borderBottom: `1px solid ${T.border}` }}>
              <div style={{ display: "flex", alignItems: "center", gap: 8, background: T.bg, borderRadius: 10, padding: "8px 14px", border: `1px solid ${T.border}` }}>
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke={T.textMuted} strokeWidth="2"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
                <input value={assignSearch} onChange={e => setAssignSearch(e.target.value)} placeholder="Cerca utente per nome o email..." style={{ border: "none", outline: "none", background: "transparent", fontSize: 13, color: T.text, width: "100%", fontFamily: "inherit" }} />
              </div>
            </div>
            <div style={{ overflow: "auto", flex: 1, padding: "8px 0" }}>
              {allUsers.filter(u => !u.is_staff && (assignSearch === "" || `${u.first_name} ${u.last_name} ${u.email}`.toLowerCase().includes(assignSearch.toLowerCase()))).map(u => {
                const isSelected = selectedUserIds.includes(u.id);
                return (
                  <div key={u.id} onClick={() => {
                    setSelectedUserIds(prev => isSelected ? prev.filter(id => id !== u.id) : [...prev, u.id]);
                  }} style={{ display: "flex", alignItems: "center", gap: 14, padding: "12px 28px", cursor: "pointer", transition: "background 0.15s", background: isSelected ? `${T.teal}08` : "transparent" }}
                    onMouseEnter={e => { if (!isSelected) e.currentTarget.style.background = T.bg; }}
                    onMouseLeave={e => { if (!isSelected) e.currentTarget.style.background = "transparent"; }}>
                    <div style={{ width: 22, height: 22, borderRadius: 6, border: `2px solid ${isSelected ? T.teal : T.border}`, background: isSelected ? T.teal : "transparent", display: "flex", alignItems: "center", justifyContent: "center", transition: "all 0.2s", flexShrink: 0 }}>
                      {isSelected && <svg width="14" height="14" viewBox="0 0 24 24" fill="white"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>}
                    </div>
                    <div style={{ width: 36, height: 36, borderRadius: 10, background: T.gradient, display: "flex", alignItems: "center", justifyContent: "center", color: "#fff", fontSize: 13, fontWeight: 700, flexShrink: 0 }}>
                      {(u.first_name || u.username)[0]?.toUpperCase()}{(u.last_name || "")[0]?.toUpperCase() || ""}
                    </div>
                    <div style={{ flex: 1 }}>
                      <div style={{ fontSize: 14, fontWeight: 600, color: T.text }}>{u.first_name || u.username} {u.last_name || ""}</div>
                      <div style={{ fontSize: 12, color: T.textMuted }}>{u.email}</div>
                    </div>
                    <div style={{ padding: "3px 8px", borderRadius: 4, fontSize: 11, fontWeight: 600, background: u.approval_status === "approved" ? "#E8F5E9" : u.approval_status === "pending" ? "#FFF3E0" : "#FFEBEE", color: u.approval_status === "approved" ? "#4CAF50" : u.approval_status === "pending" ? "#FF9800" : "#EF5350" }}>
                      {u.approval_status === "approved" ? "Attivo" : u.approval_status === "pending" ? "Pending" : "Bloccato"}
                    </div>
                  </div>
                );
              })}
            </div>
            <div style={{ padding: "16px 28px", borderTop: `1px solid ${T.border}`, display: "flex", alignItems: "center", justifyContent: "space-between", flexShrink: 0 }}>
              <div style={{ fontSize: 13, color: T.textMuted }}>{selectedUserIds.length} utenti selezionati</div>
              <div style={{ display: "flex", gap: 10 }}>
                <button onClick={() => { setAssignModal(null); setAssignSearch(""); }} style={{ padding: "10px 20px", borderRadius: 10, border: `1px solid ${T.border}`, background: "transparent", color: T.textMuted, fontSize: 14, fontWeight: 600, cursor: "pointer", fontFamily: "inherit" }}>Annulla</button>
                <button onClick={async () => {
                  try {
                    await apiFetch(`/admin/groups/${assignModal.id}/assign/`, {
                      method: "POST",
                      body: JSON.stringify({ user_ids: selectedUserIds }),
                    });
                    await loadGroups();
                    setAssignModal(null);
                    setAssignSearch("");
                  } catch (e) { console.error(e); }
                }} style={{ padding: "10px 24px", borderRadius: 10, border: "none", background: T.gradient, color: "#fff", fontSize: 14, fontWeight: 600, cursor: "pointer", fontFamily: "inherit", boxShadow: "0 4px 12px rgba(42,191,191,0.3)" }}>Conferma Assegnazione</button>
              </div>
            </div>
          </div>
        </div>
      )}

      {confirmAction && (
        <ConfirmModal
          title={confirmAction.title}
          message={confirmAction.message}
          warning={confirmAction.warning}
          confirmLabel={confirmAction.confirmLabel}
          confirmColor={confirmAction.confirmColor}
          onConfirm={confirmAction.onConfirm}
          onCancel={() => setConfirmAction(null)}
        />
      )}

      {infoModal && (
        <InfoModal
          title={infoModal.title}
          lines={infoModal.lines}
          onClose={() => setInfoModal(null)}
        />
      )}

      <style>{`
        @keyframes fadeIn { from { opacity: 0; transform: translateY(-8px); } to { opacity: 1; transform: translateY(0); } }
      `}</style>
    </div>
  );
}

function PlaceholderPage({ title }) {
  return (
    <div style={{ padding: 32, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", minHeight: "60vh" }}>
      <div style={{ width: 80, height: 80, borderRadius: 24, background: `${T.teal}15`, display: "flex", alignItems: "center", justifyContent: "center", color: T.teal, marginBottom: 20 }}><IconSecurity /></div>
      <div style={{ fontSize: 24, fontWeight: 800, color: T.text, marginBottom: 8 }}>{title}</div>
      <div style={{ fontSize: 14, color: T.textMuted }}>Sezione in fase di sviluppo</div>
    </div>
  );
}

function LoginPage({ onLogin }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const handleLogin = async () => {
    setLoading(true);
    setError("");
    try {
      const res = await fetch(`${API_BASE}/auth/login/`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: email.toLowerCase().trim(), password }),
      });
      const data = await res.json();
      console.log("Login response:", res.status, data);
      if (res.ok && data.access) {
        localStorage.setItem("admin_token", data.access);
        localStorage.setItem("admin_refresh", data.refresh);
        onLogin();
      } else {
        const errMsg = data.non_field_errors?.[0] || data.error || data.detail || data.email?.[0] || data.password?.[0] || JSON.stringify(data);
        setError(errMsg);
      }
    } catch (e) {
      setError("Errore di connessione al server");
    }
    setLoading(false);
  };

  return (
    <div style={{ minHeight: "100vh", background: T.bg, display: "flex", alignItems: "center", justifyContent: "center", fontFamily: "'DM Sans', -apple-system, sans-serif" }}>
      <link href="https://fonts.googleapis.com/css2?family=DM+Sans:ital,opsz,wght@0,9..40,100..1000;1,9..40,100..1000&display=swap" rel="stylesheet" />
      <div style={{ background: T.card, borderRadius: 20, padding: 40, width: 400, boxShadow: "0 20px 60px rgba(0,0,0,0.1)" }}>
        <div style={{ textAlign: "center", marginBottom: 32 }}>
          <img src="/Logo_SecureChat.png" alt="SecureChat" style={{ height: 60, display: "block", margin: "0 auto 16px" }} />
          <div style={{ fontSize: 13, color: T.textMuted }}>Admin Panel</div>
        </div>
        {error && <div style={{ background: "#FFEBEE", color: T.red, padding: "10px 14px", borderRadius: 10, fontSize: 13, marginBottom: 16, fontWeight: 500 }}>{error}</div>}
        <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
          <div>
            <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.textMuted, marginBottom: 6, textTransform: "uppercase", letterSpacing: "0.5px" }}>Email</label>
            <input value={email} onChange={e => setEmail(e.target.value)} placeholder="admin@securechat.test" onKeyDown={e => e.key === "Enter" && handleLogin()} style={{ width: "100%", padding: "12px 14px", borderRadius: 10, border: `1px solid ${T.border}`, fontSize: 14, color: T.text, fontFamily: "inherit", outline: "none", boxSizing: "border-box" }} onFocus={e => e.target.style.borderColor = T.teal} onBlur={e => e.target.style.borderColor = T.border} />
          </div>
          <div>
            <label style={{ display: "block", fontSize: 12, fontWeight: 600, color: T.textMuted, marginBottom: 6, textTransform: "uppercase", letterSpacing: "0.5px" }}>Password</label>
            <input type="password" value={password} onChange={e => setPassword(e.target.value)} placeholder="••••••••" onKeyDown={e => e.key === "Enter" && handleLogin()} style={{ width: "100%", padding: "12px 14px", borderRadius: 10, border: `1px solid ${T.border}`, fontSize: 14, color: T.text, fontFamily: "inherit", outline: "none", boxSizing: "border-box" }} onFocus={e => e.target.style.borderColor = T.teal} onBlur={e => e.target.style.borderColor = T.border} />
          </div>
          <button onClick={handleLogin} disabled={loading} style={{ padding: "12px", borderRadius: 10, border: "none", background: T.gradient, color: "#fff", fontSize: 15, fontWeight: 700, cursor: loading ? "wait" : "pointer", fontFamily: "inherit", marginTop: 8, opacity: loading ? 0.7 : 1 }}>{loading ? "Accesso..." : "Accedi"}</button>
        </div>
      </div>
    </div>
  );
}

export default function AdminDashboard() {
  const [page, setPage] = useState("dashboard");
  const [collapsed, setCollapsed] = useState(false);
  const [authenticated, setAuthenticated] = useState(!!localStorage.getItem("admin_token"));

  if (!authenticated) {
    return <LoginPage onLogin={() => setAuthenticated(true)} />;
  }

  const titles = { dashboard: "Dashboard", users: "Gestione Utenti", groups: "Gestione Gruppi", security: "Security Center", reports: "Report & Analytics", settings: "Impostazioni" };
  return (
    <div style={{ fontFamily: "'DM Sans', -apple-system, BlinkMacSystemFont, sans-serif", background: T.bg, minHeight: "100vh", color: T.text }}>
      <link href="https://fonts.googleapis.com/css2?family=DM+Sans:ital,opsz,wght@0,9..40,100..1000;1,9..40,100..1000&display=swap" rel="stylesheet" />
      <Sidebar active={page} onSelect={setPage} collapsed={collapsed} />
      <div style={{ marginLeft: collapsed ? 72 : 260, transition: "margin-left 0.3s cubic-bezier(0.4,0,0.2,1)", minHeight: "100vh" }}>
        <TopHeader title={titles[page]} collapsed={collapsed} onToggle={() => setCollapsed(!collapsed)} />
        {page === "dashboard" ? <DashboardPage /> : page === "users" ? <UsersPage /> : page === "groups" ? <GroupsPage /> : <PlaceholderPage title={titles[page]} />}
      </div>
    </div>
  );
}
