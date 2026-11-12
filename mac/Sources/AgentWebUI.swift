// The Agents web UI (served by AgentWeb.swift; also the Mac's own Agents page). One file, no build step,
// no external resources: the page works on the home network without internet.
enum AgentWebUI {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="color-scheme" content="light dark">
<title>PhoneCast Agents</title>
<style>
:root{--bg:#f6f6f9;--surface:#fff;--surface2:#eef0f5;--text:#1b1b1f;--text2:#5e6068;--line:#e3e4ea;--accent:#2b5bb5;--onaccent:#fff;--tonal:#dce3f5;--ontonal:#1f2a40;
--green:#15a34a;--orange:#d97706;--red:#dc2626;--ask:#fff4df;--term:#17181c;--termfg:#d8d8dc;--radius:16px}
@media (prefers-color-scheme:dark){:root{--bg:#121316;--surface:#1f2024;--surface2:#26282d;--text:#e6e6ea;--text2:#a4a6ae;--line:#2e3036;--accent:#9dc1ff;--onaccent:#0b2a5c;--tonal:#33405a;--ontonal:#dce3f5;
--green:#4ade80;--orange:#fbbf24;--red:#f87171;--ask:#3a2e14}}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:var(--bg);color:var(--text);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;-webkit-text-size-adjust:100%}
button,input,textarea,select{font:inherit;color:inherit}
button{cursor:pointer;border:0;background:none}
#app{display:grid;grid-template-columns:minmax(300px,380px) 1fr;height:100vh;height:100dvh}
#side{border-right:1px solid var(--line);display:flex;flex-direction:column;min-height:0}
#main{display:flex;flex-direction:column;min-width:0;min-height:0}
@media (max-width:760px){#app{grid-template-columns:1fr}#app.chat #side{display:none}#app:not(.chat) #main{display:none}}
.head{display:flex;align-items:center;gap:8px;padding:18px 16px 6px}
.head h1{font-size:28px;margin:0;flex:1;font-weight:650;letter-spacing:-.01em}
.icon{width:40px;height:40px;border-radius:50%;display:grid;place-items:center;color:var(--text2);font-size:18px}
.icon:hover{background:var(--surface2)}
.icon.filled{background:var(--tonal);color:var(--ontonal)}
.icon.on{color:var(--accent)}
.search{margin:6px 16px;padding:10px 14px;border-radius:22px;border:0;background:var(--surface);outline:none}
.chips{display:flex;gap:8px;padding:6px 16px;overflow-x:auto;scrollbar-width:none}
.chip{padding:6px 13px;border-radius:18px;border:1px solid var(--line);white-space:nowrap;color:var(--text2);font-weight:500;font-size:14px}
.chip.on{background:var(--tonal);color:var(--ontonal);border-color:transparent}
.chip.warn{color:var(--orange)}
#list{overflow-y:auto;flex:1;padding-bottom:24px}
.sec{padding:14px 22px 4px;font-size:13px;font-weight:600;color:var(--text2)}
.row{display:flex;gap:12px;padding:10px 14px;margin:0 8px;border-radius:16px;cursor:pointer;align-items:flex-start}
.row:hover{background:var(--surface2)}
.row.sel{background:var(--tonal)}
.row.child{padding-left:44px}
.badge{position:relative;flex:none;width:36px;height:36px;border-radius:50%;display:grid;place-items:center;font-weight:600}
.badge.claude{background:#f3e1d7;color:#c4602d}
.badge.codex{background:#20232a;color:#fff;font-size:12px}
.badge.other{background:var(--tonal);color:var(--accent)}
@media (prefers-color-scheme:dark){.badge.claude{background:#5a3a2c;color:#f4b490}.badge.codex{background:#2e3440}}
.dot{position:absolute;right:-1px;bottom:-1px;width:12px;height:12px;border-radius:50%;border:2px solid var(--bg)}
.col{flex:1;min-width:0}
.t1{display:flex;gap:8px;align-items:baseline}
.title{font-weight:600;flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.time{font-size:12px;color:var(--text2);flex:none}
.sub{font-size:13px;color:var(--text2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sub.warn{color:var(--orange)}.sub.err{color:var(--red)}
.last{font-size:13.5px;color:var(--text2);display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;margin-top:2px}
.kids{font-size:13px;color:var(--accent);font-weight:500;margin-top:5px}
.card{background:var(--surface);border-radius:20px;padding:12px 16px;margin:8px 16px}
.card h3{margin:0 0 4px;font-size:13px;color:var(--text2)}
.limit{display:grid;grid-template-columns:62px 54px 1fr 78px;gap:8px;align-items:center;font-size:13px;margin:5px 0 0}
.bar{height:6px;border-radius:3px;background:var(--line);overflow:hidden}.bar i{display:block;height:100%}
.lim-when{font-size:11.5px;color:var(--text2);padding-left:124px}
.empty{padding:40px 24px;text-align:center;color:var(--text2)}
/* chat */
.ctop{display:flex;align-items:center;gap:4px;padding:10px 8px 6px 12px}
.ctitle{flex:1;min-width:0}
.ctitle b{display:block;font-size:17px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ctitle span{font-size:12.5px;color:var(--text2);display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.uline{display:flex;gap:8px;align-items:center;padding:0 16px 6px;font-size:12px;color:var(--text2)}
.uline .txt{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer}
.mode{background:var(--tonal);color:var(--ontonal);border-radius:12px;padding:3px 10px;font-weight:600;font-size:12px;white-space:nowrap}
.work{height:3px;background:linear-gradient(90deg,transparent,var(--accent),transparent);background-size:40% 100%;background-repeat:no-repeat;animation:w 1.4s linear infinite}
@keyframes w{from{background-position:-40% 0}to{background-position:140% 0}}
.worktxt{font-size:13px;color:var(--text2);padding:3px 16px}
#body{flex:1;overflow-y:auto;padding:8px 16px 16px;min-height:0}
.msg{margin:10px 0;max-width:820px}
.user{margin-left:auto;background:var(--tonal);color:var(--ontonal);border-radius:20px;padding:10px 14px;width:fit-content;max-width:85%;white-space:pre-wrap;word-break:break-word}
.asst{white-space:normal;word-break:break-word}
.asst p{margin:.35em 0}.asst h1,.asst h2,.asst h3,.asst h4{font-size:1.08em;margin:.6em 0 .2em}
.asst code{font-family:ui-monospace,Menlo,monospace;background:var(--surface2);padding:1px 4px;border-radius:5px;font-size:.92em}
pre{background:var(--surface2);border-radius:14px;padding:10px 12px;overflow-x:auto;font:12.5px/1.45 ui-monospace,Menlo,monospace;margin:6px 0}
.tool{font:12.5px ui-monospace,Menlo,monospace;color:var(--text2);margin:2px 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer}
.tool.open{white-space:pre-wrap}.tool.err{color:var(--red)}
.sys{text-align:center;font-size:12.5px;color:var(--text2);margin:8px 0}
.term{background:var(--term);color:var(--termfg);border-radius:14px;padding:10px;overflow-x:auto;font:11.5px/1.35 ui-monospace,Menlo,monospace;white-space:pre}
.ask{background:var(--ask);border-radius:20px;padding:14px 18px;margin:6px 12px}
.ask small{color:var(--orange);font-weight:600}.ask b{display:block;font-size:16px;margin:2px 0 4px}
.ask pre{background:transparent;padding:0;max-height:9em;overflow:auto}
.btn{display:block;width:100%;padding:11px 16px;border-radius:24px;margin-top:8px;font-weight:600}
.btn.primary{background:var(--accent);color:var(--onaccent)}.btn.tonal{background:var(--tonal);color:var(--ontonal)}.btn.quiet{color:var(--text2)}
.btn:disabled{opacity:.5}
.keys{display:flex;gap:8px;padding:4px 14px;overflow-x:auto;scrollbar-width:none}
.key{background:var(--tonal);color:var(--ontonal);border-radius:14px;padding:6px 14px;font-weight:600;white-space:nowrap}
.compose{display:flex;gap:6px;align-items:flex-end;padding:6px 10px 12px}
.compose textarea{flex:1;resize:none;border:0;border-radius:22px;background:var(--surface);padding:11px 16px;max-height:9em;outline:none;min-height:44px}
.send{width:46px;height:46px;border-radius:50%;background:var(--accent);color:var(--onaccent);font-size:18px;flex:none}
.hint{font-size:12px;color:var(--text2);padding:0 22px}
.thumbs,.suggest{display:flex;gap:8px;padding:4px 14px;overflow-x:auto}
.pill{background:var(--tonal);color:var(--ontonal);border-radius:14px;padding:6px 12px;font-size:13px;white-space:nowrap}
.frow{display:flex;gap:10px;align-items:center;padding:9px 6px;border-radius:10px;cursor:pointer}
.frow:hover{background:var(--surface2)}.frow .n{flex:1}.frow .s{font-size:12px;color:var(--text2)}
.dim{opacity:.5}
.crumbs a{color:var(--accent);cursor:pointer}
.diff .a{background:rgba(40,167,69,.18)}.diff .d{background:rgba(229,83,75,.18)}.diff .h{color:var(--accent)}.diff .m{color:var(--text2)}
dialog{border:0;border-radius:24px;background:var(--surface);color:var(--text);padding:20px 22px;max-width:min(92vw,460px);width:100%}
dialog::backdrop{background:rgba(0,0,0,.35)}
dialog h2{margin:0 0 10px;font-size:19px}
dialog label{display:block;font-size:13px;color:var(--text2);margin:12px 0 4px}
dialog input,dialog select,dialog textarea{width:100%;padding:9px 12px;border-radius:12px;border:1px solid var(--line);background:var(--bg)}
.seg{display:flex;border:1px solid var(--line);border-radius:20px;padding:3px;gap:2px}
.seg button{flex:1;border-radius:17px;padding:7px 4px;color:var(--text2);font-weight:600;font-size:14px}
.seg button.on{background:var(--tonal);color:var(--ontonal)}
.acts{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}
.acts button{padding:9px 16px;border-radius:20px;font-weight:600;color:var(--accent)}
.acts .go{background:var(--accent);color:var(--onaccent)}
.menu{position:fixed;z-index:9;background:var(--surface);border-radius:14px;box-shadow:0 8px 30px rgba(0,0,0,.25);padding:6px;min-width:220px;max-height:70vh;overflow:auto}
.menu button{display:block;width:100%;text-align:left;padding:9px 12px;border-radius:9px}
.menu button:hover{background:var(--surface2)}
#toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:var(--text);color:var(--bg);padding:10px 16px;border-radius:12px;font-size:14px;display:none;max-width:90vw;z-index:10}
#login{max-width:340px;margin:12vh auto;padding:24px;text-align:center}
#login input{font-size:28px;letter-spacing:.3em;text-align:center;width:100%;padding:10px;border-radius:14px;border:1px solid var(--line);background:var(--surface)}
.nochat{flex:1;display:grid;place-items:center;color:var(--text2)}
</style>
</head>
<body>
<div id="login" hidden>
  <h1 style="font-size:24px">PhoneCast Agents</h1>
  <p style="color:var(--text2)">Enter the code shown on the Mac<br>(PhoneCast → Agents → Open in a browser).</p>
  <input id="code" inputmode="numeric" maxlength="6" autocomplete="one-time-code" placeholder="••••••">
  <button class="btn primary" id="go">Sign in</button>
  <p id="lerr" style="color:var(--red)"></p>
</div>
<div id="app" hidden>
  <section id="side">
    <div class="head"><h1>Agents</h1><a class="icon" href="/phone" title="Phone: notifications and messages" style="text-decoration:none;display:inline-flex;align-items:center;justify-content:center">☎</a><button class="icon" id="settings" title="Settings">⋯</button><button class="icon filled" id="new" title="New chat">＋</button></div>
    <input class="search" id="q" placeholder="Search chats and folders">
    <div class="chips" id="chips"></div>
    <div id="list"></div>
  </section>
  <section id="main"><div class="nochat">Pick a chat</div></section>
</div>
<div id="toast"></div>
<script>
"use strict";
const $=s=>document.querySelector(s), el=(t,c,txt)=>{const e=document.createElement(t);if(c)e.className=c;if(txt!=null)e.textContent=txt;return e};
const esc=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
let S={list:[],plan:{},byId:{},open:localStorage.getItem("open"),filter:localStorage.getItem("filter")||"all",q:"",msgs:[],view:"msgs",diff:null,fpath:"",file:null,exp:new Set(),pins:new Set(JSON.parse(localStorage.getItem("pins")||"[]")),tap:false,att:[],sig:""};
function toast(t){const e=$("#toast");e.textContent=t;e.style.display="block";clearTimeout(e._t);e._t=setTimeout(()=>e.style.display="none",3500)}
async function api(m,p={}){
  const r=await fetch("/api",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({id:1,m,p})});
  if(r.status==401){showLogin();throw new Error("Please sign in")}
  const j=await r.json(); if(!j.ok) throw new Error(j.message||"Failed"); return j.data;
}
function showLogin(){$("#app").hidden=true;$("#login").hidden=false;$("#code").focus()}
$("#go").onclick=async()=>{const r=await fetch("/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({code:$("#code").value,name:navigator.userAgent.includes("iPad")?"iPad":"Browser"})});
  const j=await r.json(); if(j.ok){$("#login").hidden=true;$("#app").hidden=false;tick()} else $("#lerr").textContent=j.message};
$("#code").onkeydown=e=>{if(e.key==="Enter")$("#go").click()};

// ---------- helpers ----------
function ago(ms){if(!ms)return"";const s=(Date.now()-ms)/1000;if(s<60)return"now";if(s<3600)return Math.floor(s/60)+" min";if(s<86400)return Math.floor(s/3600)+" h";if(s<604800)return Math.floor(s/86400)+" d";return new Date(ms).toLocaleDateString(undefined,{day:"numeric",month:"short"})}
const needs=s=>s.status==="needs_input"||!!s.ask, active=s=>s.live||s.status==="working";
const canSend=s=>!s.sub&&(s.managed||s.canResume);
function fmtTok(n){n=+n||0;return n>=1e6?(n/1e6).toFixed(1)+"M":n>=1e3?Math.floor(n/1e3)+"k":String(n)}
function usageLine(u){if(!u)return"";const p=[];if(u.ctxPct!=null)p.push("context "+Math.round(u.ctxPct)+"%");const i=(u.in||0)+(u.cached||0);if(i+(u.out||0))p.push(fmtTok(i)+" ↑ "+fmtTok(u.out)+" ↓");if(u.cost!=null)p.push("$"+u.cost.toFixed(2));(u.limits||[]).forEach(l=>p.push(l.label+" "+Math.round(l.pct)+"%"));return p.join("  ·  ")}
function modelName(id){if(!id||id==="default")return"";const long=/\[1m\]/i.test(id)?" (1M)":"";const b=id.replace(/\[.*?\]/g,"");const m=b.match(/^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{6,})?$/);
  if(m)return m[1][0].toUpperCase()+m[1].slice(1)+" "+m[2]+(m[3]?"."+m[3]:"")+long;return b.split("-").map(p=>/^gpt$/i.test(p)?"GPT":p[0].toUpperCase()+p.slice(1)).join(" ").replace(/^GPT (\d)/,"GPT-$1")+long}
function modeName(m){return{"":"Ask before edits",default:"Ask before edits","accept edits":"Auto-accept edits","plan mode":"Plan mode","bypass permissions":"Bypass permissions"}[m??""]??m}
function subtitle(s){let what;if(s.ask)what="Asks: "+(s.ask.title||"");else what={working:s.stage||"Working…",needs_input:s.stage||"Waiting for you",error:s.stage||"Error",completed:"Done",idle:s.managed?"Ready":"Open in a terminal",offline:"Finished"}[s.status]||s.stage||"Running";
  let f=(s.cwd||"").split("/").pop();if(s.host)f+=" @ "+s.host.split("@").pop();return[s.sub?s.role:f,modelName(s.model),what].filter(Boolean).join(" · ")}
function badge(s){const b=el("div","badge "+(s.agent==="claude"?"claude":s.agent==="codex"?"codex":"other"),s.agent==="claude"?"✻":s.agent==="codex"?"›_":(s.agent||"?")[0].toUpperCase());
  const c={working:"var(--green)",needs_input:"var(--orange)",error:"var(--red)",idle:"var(--text2)",completed:"var(--text2)"}[s.ask?"needs_input":s.status];if(c){const d=el("i","dot");d.style.background=c;b.append(d)}return b}
function menu(anchor,items){document.querySelectorAll(".menu").forEach(m=>m.remove());const m=el("div","menu");items.forEach(([t,f])=>{const b=el("button",null,t);b.onclick=()=>{m.remove();f()};m.append(b)});
  document.body.append(m);const r=anchor.getBoundingClientRect();m.style.top=Math.min(r.bottom+4,innerHeight-m.offsetHeight-8)+"px";m.style.left=Math.max(8,Math.min(r.right-m.offsetWidth,innerWidth-m.offsetWidth-8))+"px";
  setTimeout(()=>addEventListener("click",function h(e){if(!m.contains(e.target)){m.remove();removeEventListener("click",h)}}),0)}
function dialog(title,build,okText,onOk){const d=el("dialog");d.innerHTML="<h2>"+esc(title)+"</h2>";const body=el("div");d.append(body);build(body);const a=el("div","acts");const c=el("button",null,"Cancel");c.onclick=()=>d.close();a.append(c);
  if(okText){const g=el("button","go",okText);g.onclick=async()=>{g.disabled=true;try{if(await onOk()!==false)d.close()}catch(e){toast(e.message)}g.disabled=false};a.append(g)}d.append(a);document.body.append(d);d.addEventListener("close",()=>d.remove());d.showModal();return d}
function field(parent,label,node){const l=el("label",null,label);parent.append(l,node);return node}

// ---------- list ----------
function renderList(){
  const tops=S.list.filter(s=>!s.sub);
  const counts={all:tops.length,you:tops.filter(needs).length,active:tops.filter(active).length,claude:tops.filter(s=>s.agent==="claude").length,codex:tops.filter(s=>s.agent==="codex").length};
  const ch=$("#chips");ch.innerHTML="";[["all","All"],["you","Needs you"],["active","Running"],["claude","Claude"],["codex","Codex"]].forEach(([k,n])=>{if(k==="codex"&&!counts.codex&&S.filter!==k)return;
    const b=el("button","chip"+(S.filter===k?" on":"")+(k==="you"&&counts.you?" warn":""),k==="all"?n:n+"  "+counts[k]);b.onclick=()=>{S.filter=k;localStorage.setItem("filter",k);renderList()};ch.append(b)});
  const L=$("#list"),top=L.scrollTop;L.innerHTML="";L.append(planCard());
  if(!S.installed){const c=el("div","card");c.innerHTML="<h3>Terminal control is off</h3><div style='font-size:14px;color:var(--text2)'>Turn on Agents → Terminal integration on the Mac so chats started in a terminal can be answered here.</div>";L.append(c)}
  const q=S.q.toLowerCase();const match=s=>!q||(s.title||"").toLowerCase().includes(q)||(s.cwd||"").toLowerCase().includes(q);
  const f=tops.filter(match).filter(s=>({you:needs(s),active:active(s),claude:s.agent==="claude",codex:s.agent==="codex"})[S.filter]??true);
  const sec={"Needs you":[],"Pinned":[],"Running":[],"Recent":[]};
  f.forEach(s=>sec[needs(s)?"Needs you":S.pins.has(s.id)?"Pinned":active(s)?"Running":"Recent"].push(s));
  let any=false;for(const[n,arr]of Object.entries(sec)){if(!arr.length)continue;any=true;L.append(el("div","sec",n));arr.forEach(s=>{L.append(row(s,false));if(S.exp.has(s.id))S.list.filter(k=>k.parent===s.id).forEach(k=>L.append(row(k,true)))})}
  if(!any)L.append(el("div","empty",S.list.length?"Nothing here.":"No chats yet. Start one with ＋."));L.scrollTop=top;
}
function row(s,child){const r=el("div","row"+(child?" child":"")+(s.id===S.open?" sel":""));r.append(badge(s));const c=el("div","col");
  const t=el("div","t1");t.append(el("span","title",s.title),el("span","time",ago(s.updatedAt)));c.append(t);
  c.append(el("div","sub"+(needs(s)?" warn":s.status==="error"?" err":""),subtitle(s)));if(s.last&&!child)c.append(el("div","last",s.last));
  const kids=S.list.filter(k=>k.parent===s.id);if(kids.length&&!child){const k=el("div","kids",(S.exp.has(s.id)?"▾ ":"▸ ")+kids.length+(kids.length==1?" subagent":" subagents")+(kids.some(x=>x.status==="working")?" · "+kids.filter(x=>x.status==="working").length+" working":""));
    k.onclick=e=>{e.stopPropagation();S.exp.has(s.id)?S.exp.delete(s.id):S.exp.add(s.id);renderList()};c.append(k)}
  r.append(c);r.onclick=()=>openChat(s.id);r.oncontextmenu=e=>{e.preventDefault();rowMenu(r,s)};return r}
function rowMenu(a,s){menu(a,[[S.pins.has(s.id)?"Unpin":"Pin to top",()=>{S.pins.has(s.id)?S.pins.delete(s.id):S.pins.add(s.id);localStorage.setItem("pins",JSON.stringify([...S.pins]));renderList()}],["Copy folder path",()=>navigator.clipboard?.writeText(s.cwd||"")]])}
function planCard(){const p=S.plan||{};const groups=[];const accs=p.claudeAccounts;
  if(accs&&accs.length){accs.forEach((a,i)=>{const ids=new Set(a.sessions||[]);const chats=S.list.filter(s=>!s.sub&&ids.has(s.nativeId)).sort((x,y)=>y.updatedAt-x.updatedAt).map(s=>s.title);
    groups.push([accs.length>1?"Claude account "+(i+1)+(a.current?" · logged in now":""):"Claude",accs.length>1&&chats.length?"used by "+chats.slice(0,2).join(", ")+(chats.length>2?" +"+(chats.length-2)+" more":""):null,a.limits||[]])})}
  else if(p.claude)groups.push(["Claude",null,p.claude]);if(p.codex)groups.push(["Codex",null,p.codex]);
  const c=el("div","card");if(!groups.length){c.hidden=true;return c}c.append(el("h3",null,"Usage left"));const now=Date.now()/1000;
  groups.forEach(([name,who,lims])=>{if(who){const h=el("div",null,name);h.style.cssText="font-weight:600;margin-top:6px;font-size:13.5px";c.append(h,Object.assign(el("div","sub",who),{style:"font-size:11.5px"}))}
    lims.forEach((w,i)=>{const used=Math.max(0,Math.min(100,w.pct)),passed=w.resets>0&&w.resets<now;const r=el("div","limit");r.append(el("b",null,i==0&&!who?name:""),el("span","sub",w.label));
      const bar=el("div","bar"),fill=el("i");fill.style.width=(passed?0:used)+"%";fill.style.background=passed?"var(--text2)":used>=90?"var(--red)":used>=70?"var(--orange)":"var(--green)";bar.append(fill);r.append(bar);
      const left=el("b",null,passed?"fresh":Math.round(100-used)+"% left");if(used>=90&&!passed)left.style.color="var(--red)";r.append(left);c.append(r);
      if(w.resets>0){const d=new Date(w.resets*1000);c.append(el("div","lim-when",(passed?"reset at ":"resets ")+(w.resets-now<86400?d.toLocaleTimeString(undefined,{hour:"2-digit",minute:"2-digit"}):d.toLocaleString(undefined,{weekday:"short",hour:"2-digit",minute:"2-digit"}))))}})});
  if(!p.claude&&!S.tap){const h=el("div","sub","Claude's limits appear after turning on “Cost & plan limits” (⋯ above).");h.style.marginTop="6px";c.append(h)}return c}
$("#q").oninput=e=>{S.q=e.target.value.trim();renderList()};

// ---------- chat ----------
function cur(){return S.byId[S.open]}
function openChat(id){S.open=id;localStorage.setItem("open",id||"");S.msgs=[];S.view="msgs";S.diff=null;S.fpath="";S.file=null;S.att=[];
  const s=cur();if(s&&(s.host||!["claude","codex"].includes(s.agent)))S.view="term";$("#app").classList.toggle("chat",!!id);buildChat();renderList();loadMsgs(true)}
function buildChat(){const M=$("#main");M.innerHTML="";const s=cur();if(!s){M.append(el("div","nochat",S.open?"This chat ended":"Pick a chat"));return}
  const top=el("div","ctop");const back=el("button","icon","←");back.title="Back";back.onclick=()=>{S.open=null;localStorage.removeItem("open");$("#app").classList.remove("chat");renderList()};top.append(back);
  const t=el("div","ctitle");t.id="ct";top.append(t);
  const ib=(txt,title,f,id)=>{const b=el("button","icon",txt);b.title=title;if(id)b.id=id;b.onclick=f;top.append(b);return b};
  ib("■","Stop",()=>api("stop",{sid:S.open}).catch(e=>toast(e.message)),"bstop");ib("⇅","Changes",()=>{S.view=S.view==="changes"?"msgs":"changes";S.diff=null;refreshChat(true)},"bchg");
  ib(">_","Terminal",()=>{S.view=S.view==="term"?"msgs":"term";refreshChat(true)},"bterm");ib("⋯","More",e=>chatMenu(e.currentTarget));M.append(top);
  const ul=el("div","uline");ul.id="ul";M.append(ul);const wk=el("div");wk.id="wk";M.append(wk);
  const body=el("div");body.id="body";M.append(body);const ask=el("div");ask.id="ask";M.append(ask);
  const keys=el("div","keys");keys.id="keys";[["↑","up"],["↓","down"],["←","left"],["→","right"],["Enter","enter"],["Esc","escape"],["Tab","tab"],["⌫","backspace"],["Ctrl-C","ctrl-c"]].forEach(([n,k])=>{const b=el("button","key",n);
    b.onclick=()=>{if(k==="ctrl-c"&&!confirm("Send Ctrl-C? Pressed twice at an empty prompt, it quits the agent."))return;api("key",{sid:S.open,key:k}).then(()=>S.view==="term"&&loadTerm()).catch(e=>toast(e.message))};keys.append(b)});M.append(keys);
  const th=el("div","thumbs");th.id="thumbs";M.append(th);const sg=el("div","suggest");sg.id="sugg";M.append(sg);const hint=el("div","hint");hint.id="hint";M.append(hint);
  const c=el("div","compose");const cmd=el("button","icon","/");cmd.title="Commands";cmd.onclick=e=>commands(e.currentTarget);const at=el("button","icon","📎");at.title="Attach";
  const fi=el("input");fi.type="file";fi.multiple=true;fi.hidden=true;fi.onchange=()=>attach(fi.files);at.onclick=()=>fi.click();
  const ta=el("textarea");ta.id="ta";ta.rows=1;ta.value=localStorage.getItem("draft."+S.open)||"";ta.oninput=()=>{localStorage.setItem("draft."+S.open,ta.value);ta.style.height="auto";ta.style.height=Math.min(ta.scrollHeight,200)+"px";suggest()};
  ta.onkeydown=e=>{if(e.key==="Enter"&&!e.shiftKey&&!e.isComposing){e.preventDefault();send()}};const sb=el("button","send","➤");sb.title="Send";sb.onclick=send;c.append(cmd,at,fi,ta,sb);M.append(c);
  M.ondragover=e=>e.preventDefault();M.ondrop=e=>{e.preventDefault();attach(e.dataTransfer.files)};ta.onpaste=e=>{if(e.clipboardData.files.length){e.preventDefault();attach(e.clipboardData.files)}};
  refreshChat(true)}
function refreshChat(force){const s=cur();if(!s){if(S.open)buildChat();return}if(!$("#ct"))return buildChat();
  $("#ct").innerHTML="<b>"+esc(s.title)+"</b><span>"+esc([({claude:"Claude Code",codex:"Codex"})[s.agent]||s.agent,modelName(s.model),s.host?"on "+s.host:null,(s.cwd||"").replace(/^\/Users\/[^/]+/,"~")].filter(Boolean).join(" · "))+"</span>";
  const w=s.status==="working";$("#bstop").hidden=!(s.managed&&(w||s.status==="needs_input"));$("#bterm").hidden=!s.managed;$("#bchg").hidden=s.sub||!s.cwd;
  $("#bterm").classList.toggle("on",S.view==="term");$("#bchg").classList.toggle("on",S.view==="changes");
  const ul=$("#ul");ul.innerHTML="";if(s.managed&&s.agent==="claude"){const m=el("button","mode",modeName(s.mode));m.title="Next permission mode";m.onclick=()=>api("mode",{sid:S.open}).catch(e=>toast(e.message));ul.append(m)}
  const ut=el("span","txt",usageLine(s.usage)+(s.over?"  ·  ⚠ "+s.over:""));if(s.over)ut.style.color="var(--red)";ut.onclick=usageDialog;ul.append(ut);
  $("#wk").innerHTML=w?"<div class='work'></div><div class='worktxt'>"+esc(s.stage||"Working…")+"</div>":"";
  $("#keys").hidden=!s.managed||["changes","files"].includes(S.view);
  renderAsk(s);const ta=$("#ta"),ok=canSend(s)||(S.view==="term"&&s.managed);ta.disabled=!ok;
  ta.placeholder=S.view==="term"?"Type into the terminal":s.sub?"Subagents can't be messaged":!ok?"Open in another terminal — read only":w?"Message — interrupts the current turn":!s.managed?"Message — continues this chat on the Mac":"Message";
  $("#hint").textContent=!canSend(s)&&!s.sub&&s.live?"Started outside PhoneCast's terminal integration. Close it on the Mac to continue here.":"";
  if(force)renderBody(true)}
function renderAsk(s){const a=$("#ask"),k=s.ask?JSON.stringify(s.ask):"";if(a.dataset.k===k&&!["changes","files"].includes(S.view))return;a.dataset.k=k;a.innerHTML="";if(!s.ask||["changes","files"].includes(S.view))return;
  const c=el("div","ask");c.append(el("small",null,"Needs you"),el("b",null,s.ask.title));if(s.ask.detail)c.append(el("pre",null,s.ask.detail));
  (s.ask.choices||[]).forEach((ch,i)=>{const neg=/^no|exit|cancel/i.test(ch.label);const b=el("button","btn "+(i==0?"primary":neg?"quiet":"tonal"),ch.label);
    b.onclick=async()=>{c.querySelectorAll("button").forEach(x=>x.disabled=true);try{await api("approve",{sid:S.open,ask:s.ask.id,choice:ch.id})}catch(e){toast(e.message);c.querySelectorAll("button").forEach(x=>x.disabled=false)}};c.append(b)});a.append(c)}
function md(t){const parts=t.split("```");return parts.map((p,i)=>{if(i%2){const code=p.includes("\n")?p.slice(p.indexOf("\n")+1):p;return"<pre>"+esc(code.replace(/\n$/,""))+"</pre>"}
  return p.trim()?"<p>"+esc(p.trim()).replace(/^#{1,4}\s+(.*)$/gm,"<b>$1</b>").replace(/\*\*(.+?)\*\*/g,"<b>$1</b>").replace(/`([^`]+)`/g,"<code>$1</code>").replace(/^\s*[-*]\s+/gm,"• ").replace(/\n/g,"<br>")+"</p>":""}).join("")}
function renderBody(force){const b=$("#body");if(!b)return;
  if(S.view==="term"){if(force){b.innerHTML="";loadTerm()}return}
  if(S.view==="changes"){if(force)renderChanges();return}
  if(S.view==="files"){if(force)renderFiles();return}
  const atBottom=b.scrollHeight-b.scrollTop-b.clientHeight<40;const have=[...b.children].map(x=>x.dataset.id);const ids=S.msgs.map(m=>m.id);
  const append=!force&&have.length&&have.every((h,i)=>h===ids[i]);if(!append){b.innerHTML="";if(!S.msgs.length)b.append(el("div","empty",S.loaded?"No messages yet":"Loading…"))}
  else b.querySelector(".empty")?.remove();
  S.msgs.slice(append?have.length:0).forEach(m=>{let e;
    if(m.r==="user")e=el("div","msg user",m.t);else if(m.r==="tool"){const first=m.t.split("\n")[0];e=el("div","tool"+(m.t.startsWith("Error")?" err":""),(m.t.startsWith("Error")?"✕  ":m.tool?"⚙  ":"↳  ")+first);e.onclick=()=>{e.classList.toggle("open");e.textContent=(e.classList.contains("open")?"⚙  "+m.t:"⚙  "+first)}}
    else if(m.r==="system")e=el("div","sys",m.t);else{e=el("div","msg asst");e.innerHTML=md(m.t)}e.dataset.id=m.id;b.append(e)});
  if(atBottom||!append)b.scrollTop=b.scrollHeight}
async function loadMsgs(reset){if(!S.open)return;const id=S.open;try{const d=await api("messages",{sid:id,limit:150});if(id!==S.open)return;const before=JSON.stringify(S.msgs.map(m=>m.id));S.msgs=d.add||[];S.loaded=true;
  if(reset||JSON.stringify(S.msgs.map(m=>m.id))!==before)renderBody(reset)}catch(e){}}
// ---------- terminal (ANSI → HTML) ----------
const PAL=["#1e1e1e","#e5534b","#57ab5a","#c69026","#539bf5","#b083f0","#39c5cf","#d0d0d0","#767676","#ff6b66","#6bc46d","#daaa3f","#6cb6ff","#dcbdfb","#56d4dd","#ffffff"];
function c256(n){if(n<16)return PAL[n];if(n<232){n-=16;const v=x=>x?55+x*40:0;return`rgb(${v(Math.floor(n/36))},${v(Math.floor(n/6)%6)},${v(n%6)})`}const g=8+(n-232)*10;return`rgb(${g},${g},${g})`}
function ansi(t){let out="",fg=null,bg=null,b=false,d=false,it=false,u=false,inv=false,open=false;const close=()=>{if(open){out+="</span>";open=false}};
  const style=()=>{let f=fg,k=bg;if(inv){[f,k]=[k||"#d8d8dc",f||"#17181c"]}const s=[];if(f)s.push("color:"+f);if(k)s.push("background:"+k);if(b)s.push("font-weight:700");if(d)s.push("opacity:.6");if(it)s.push("font-style:italic");if(u)s.push("text-decoration:underline");close();if(s.length){out+="<span style='"+s.join(";")+"'>";open=true}};
  const re=/\x1b\[([0-9;:]*)m|\x1b(?:\[[0-9;?]*[ -\/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])/g;let last=0,m;
  while((m=re.exec(t))){out+=esc(t.slice(last,m.index));last=re.lastIndex;if(m[1]===undefined)continue;const p=m[1].split(/[;:]/).map(x=>+x||0);
    for(let i=0;i<p.length;i++){const v=p[i];if(v===0){fg=bg=null;b=d=it=u=inv=false}else if(v===1)b=true;else if(v===2)d=true;else if(v===3)it=true;else if(v===4)u=true;else if(v===7)inv=true;else if(v===22)b=d=false;else if(v===23)it=false;else if(v===24)u=false;else if(v===27)inv=false;
      else if(v>=30&&v<=37)fg=PAL[v-30];else if(v===39)fg=null;else if(v>=40&&v<=47)bg=PAL[v-40];else if(v===49)bg=null;else if(v>=90&&v<=97)fg=PAL[v-82];else if(v>=100&&v<=107)bg=PAL[v-92];
      else if(v===38||v===48){let c=null;if(p[i+1]===5){c=c256(p[i+2]);i+=2}else if(p[i+1]===2){c=`rgb(${p[i+2]},${p[i+3]},${p[i+4]})`;i+=4}if(v===38)fg=c;else bg=c}}style()}
  out+=esc(t.slice(last));close();return out.replace(/(\s*\n)+$/,"")}
let termBusy=false;async function loadTerm(){if(S.view!=="term"||!S.open||termBusy)return;termBusy=true;const id=S.open;try{const d=await api("live",{sid:id,lines:160});if(S.view!=="term"||id!==S.open)return;
  const b=$("#body");let pre=b.querySelector(".term");const bottom=!pre||b.scrollHeight-b.scrollTop-b.clientHeight<40;if(!pre){b.innerHTML="";pre=el("div","term");b.append(pre)}pre.innerHTML=ansi(d.ansi||"");if(bottom)b.scrollTop=b.scrollHeight}
  catch(e){const b=$("#body");if(b&&!b.querySelector(".term"))b.textContent=e.message}finally{termBusy=false}}
// ---------- changes ----------
async function renderChanges(){const b=$("#body"),id=S.open;b.innerHTML="<div class='empty'>Loading…</div>";
  try{if(S.diff){const d=await api("diff",{sid:id,path:S.diff});b.innerHTML="";const back=el("button","btn quiet","← All changes");back.style.textAlign="left";back.onclick=()=>{S.diff=null;renderChanges()};
      const pre=el("pre","diff");pre.innerHTML=String(d).split("\n").slice(0,4000).map(l=>{const c=l.startsWith("+++")||l.startsWith("---")?"m":l.startsWith("+")?"a":l.startsWith("-")?"d":l.startsWith("@@")?"h":/^(diff|index) /.test(l)?"m":"";return"<div class='"+c+"'>"+(esc(l)||" ")+"</div>"}).join("");
      b.append(back,el("b",null,S.diff),pre);return}
    const d=await api("changes",{sid:id});b.innerHTML="";if(!d.repo){b.append(el("div","empty","This folder isn't a git repository."));return}
    const n=(d.files||[]).length;b.append(el("p",null,["Branch "+d.branch,d.ahead?d.ahead+" to push":"",d.behind?d.behind+" to pull":"",n?n+(n==1?" file changed":" files changed"):"no changes"].filter(Boolean).join("  ·  ")));
    let add=0,del=0;(d.files||[]).forEach(f=>{add+=f.add;del+=f.del;const r=el("div","frow");const k={new:"A",added:"A",deleted:"D",renamed:"R"}[f.kind]||"M";const kk=el("b",null,k);kk.style.color=k=="A"?"var(--green)":k=="D"?"var(--red)":"var(--orange)";
      const st=el("span","s");st.innerHTML=(f.add?"<span style='color:var(--green)'>+"+f.add+"</span> ":"")+(f.del?"<span style='color:var(--red)'>−"+f.del+"</span>":"");r.append(kk,el("span","n",f.path),st);r.onclick=()=>{S.diff=f.path;renderChanges()};b.append(r)});
    if(n)b.append(el("div","sub",add+" lines added, "+del+" removed"));
    const btn=(t,c,f)=>{const x=el("button","btn "+c,t);x.onclick=f;x.style.maxWidth="420px";b.append(x)};
    const git=async(op,p={})=>{toast("Working…");try{const r=await api("git",Object.assign({sid:id,op},p));toast(String(r||"Done"))}catch(e){toast(e.message)}renderChanges()};
    if(n)btn("Commit…","primary",()=>{let t;dialog("Commit all changes",x=>{t=field(x,"Commit message",el("textarea"));t.rows=3},"Commit",()=>git("commit",{message:t.value}))});
    if(n)btn("Let the agent commit","tonal",()=>api("send",{sid:id,text:"Please commit the current changes with a good commit message."}).then(()=>toast("Asked the agent")).catch(e=>toast(e.message)));
    if(d.ahead>0||(!d.upstream&&d.remote))btn("Push","tonal",()=>git("push"));if(d.behind>0)btn("Pull","tonal",()=>git("pull"));
    if(d.gh&&d.remote&&!["main","master"].includes(d.branch))btn("Create pull request","tonal",()=>{let t,dr;dialog("Create pull request",x=>{t=field(x,"Title (empty = from the commits)",el("input"));dr=el("input");dr.type="checkbox";dr.style.width="auto";const l=el("label");l.append(dr," Draft");x.append(l)},"Create",()=>git("pr",{title:t.value,draft:dr.checked}))});
  }catch(e){b.innerHTML="";b.append(el("div","empty",e.message))}}
// ---------- files ----------
async function renderFiles(){const b=$("#body"),id=S.open;b.innerHTML="";const cr=el("div","crumbs");const parts=["",...S.fpath.split("/").filter(Boolean)];
  parts.forEach((p,i)=>{const a=el("a",null,i==0?(cur()?.cwd||"/").split("/").pop():p);a.onclick=()=>{S.fpath=parts.slice(1,i+1).join("/");S.file=null;renderFiles()};cr.append(a,document.createTextNode(" / "))});if(S.file)cr.append(el("b",null,S.file.split("/").pop()));b.append(cr);
  try{if(S.file){const d=await api("file",{sid:id,path:S.file});b.append(el("pre",null,d.binary?"Binary file ("+Math.round(d.size/1024)+" KB)":d.text));const m=el("button","btn tonal","Mention in the message");m.style.maxWidth="420px";m.onclick=()=>mention(S.file);b.append(m);return}
    const d=await api("files",{sid:id,path:S.fpath});(d.items||[]).forEach(f=>{const r=el("div","frow"+(f.dim?" dim":""));const rel=(S.fpath?S.fpath+"/":"")+f.name;r.append(el("span",null,f.dir?"📁":"📄"),el("span","n",f.name),el("span","s",f.dir?"":f.size>1048576?(f.size/1048576).toFixed(1)+" MB":f.size>1024?Math.round(f.size/1024)+" KB":f.size+" B"));
      r.onclick=()=>{if(f.dir)S.fpath=rel;else S.file=rel;renderFiles()};r.oncontextmenu=e=>{e.preventDefault();mention(rel)};b.append(r)});b.append(el("div","sub","Right-click (long-press) a file to mention it."))}catch(e){b.append(el("div","empty",e.message))}}
function mention(p){if(S.view==="files"){S.view="msgs";refreshChat(true)}const ta=$("#ta");ta.value=(ta.value&&!ta.value.endsWith(" ")?ta.value+" ":ta.value)+"@"+p+" ";ta.focus()}
let sugT;function suggest(){clearTimeout(sugT);const ta=$("#ta"),sg=$("#sugg");const t=ta.value.slice(0,ta.selectionStart);const m=t.match(/(?:^|\s)@(\S*)$/);if(!m||!cur()?.cwd){sg.innerHTML="";return}
  sugT=setTimeout(async()=>{try{const d=await api("find",{sid:S.open,q:m[1]});sg.innerHTML="";(d.files||[]).slice(0,12).forEach(f=>{const b=el("button","pill",f.split("/").pop());b.title=f;
    b.onclick=()=>{const pos=ta.selectionStart,start=ta.value.lastIndexOf("@",pos-1);ta.value=ta.value.slice(0,start)+"@"+f+" "+ta.value.slice(pos);sg.innerHTML="";ta.focus()};sg.append(b)})}catch(e){}},180)}
// ---------- sending ----------
async function attach(files){for(const f of files){if(f.size>25*1048576){toast(f.name+" is over 25 MB");continue}const b64=await new Promise(r=>{const fr=new FileReader();fr.onload=()=>r(String(fr.result).split(",")[1]);fr.readAsDataURL(f)});
  S.att.push({name:f.name,b64,img:/^image\/(png|jpeg|webp)$/.test(f.type)})}renderThumbs()}
function renderThumbs(){const t=$("#thumbs");t.innerHTML="";S.att.forEach((a,i)=>{const p=el("button","pill",(a.img?"🖼 ":"📄 ")+a.name+"  ✕");p.onclick=()=>{S.att.splice(i,1);renderThumbs()};t.append(p)})}
async function send(){const ta=$("#ta"),text=ta.value.trim(),s=cur();if(!s||(!text&&!S.att.length))return;
  if(S.view==="term"&&!S.att.length){try{await api("type",{sid:S.open,text,enter:true});ta.value="";localStorage.removeItem("draft."+S.open);loadTerm()}catch(e){toast(e.message)}return}
  const p={sid:S.open,text,images:S.att.filter(a=>a.img).map(a=>a.b64),files:S.att.filter(a=>!a.img).map(a=>({name:a.name,b64:a.b64}))};ta.disabled=true;
  try{const r=await api("send",p);ta.value="";S.att=[];renderThumbs();localStorage.removeItem("draft."+S.open);if(r&&r.sid&&r.sid!==S.open)setTimeout(()=>openChat(r.sid),600);else loadMsgs()}catch(e){toast(e.message)}ta.disabled=false;ta.focus()}
function commands(a){const s=cur();if(!s)return;if(!s.managed){toast("Commands work in chats running in PhoneCast's terminal.");return}const cmd=(t,term)=>api("command",{sid:S.open,text:t}).then(()=>{if(term){S.view="term";setTimeout(()=>refreshChat(true),900)}}).catch(e=>toast(e.message));
  const it=[["Switch model…",()=>pickModel(s)]];
  if(s.agent==="claude")it.push(["Effort…",()=>menu(a,["low","medium","high","max"].map(l=>[l,()=>cmd("/effort "+l)]))],["Next permission mode (now: "+modeName(s.mode)+")",()=>api("mode",{sid:S.open})],["Compact the conversation",()=>cmd("/compact")],["Usage limits (/usage)",()=>cmd("/usage",1)],["Context (/context)",()=>cmd("/context",1)],["Clear the conversation…",()=>confirm("Start fresh? The conversation stays in the history.")&&cmd("/clear")]);
  else if(s.agent==="codex")it.push(["Compact the conversation",()=>cmd("/compact")],["Status (/status)",()=>cmd("/status",1)],["Approval mode (/approvals)",()=>cmd("/approvals")],["Show the diff (/diff)",()=>cmd("/diff",1)],["New conversation (/new)",()=>confirm("Start a new conversation in this terminal?")&&cmd("/new")]);
  it.push(["Other command…",()=>{const c=prompt("Command","/");if(c)cmd(c.trim(),1)}]);menu(a,it)}
async function pickModel(s){try{const d=await api("models");const a=(d.agents||[]).find(x=>x.id===s.agent);const ms=a?a.models:[];let sel;
  dialog("Switch model",x=>{sel=el("select");ms.forEach(m=>{const o=el("option",null,m.label+(m.desc?" — "+m.desc:""));o.value=m.id;sel.append(o)});field(x,"Model",sel)},"Switch",()=>api("command",{sid:S.open,text:s.agent==="claude"?"/model "+sel.value:"/model"}))}catch(e){toast(e.message)}}
function chatMenu(a){const s=cur();if(!s)return;const it=[];
  if(s.managed)it.push(["Open in Terminal on the Mac",()=>api("open",{sid:S.open}).catch(e=>toast(e.message))]);
  if(!s.managed&&s.canResume)it.push(["Reopen on the Mac",()=>api("resume",{sid:S.open}).then(d=>openChat(d.sid)).catch(e=>toast(e.message))]);
  it.push([S.pins.has(s.id)?"Unpin":"Pin to top",()=>{S.pins.has(s.id)?S.pins.delete(s.id):S.pins.add(s.id);localStorage.setItem("pins",JSON.stringify([...S.pins]));renderList()}]);
  if(s.cwd&&!s.sub)it.push(["Files",()=>{S.view="files";S.fpath="";S.file=null;refreshChat(true)}]);
  it.push(["Usage and budget",usageDialog],["Copy chat as Markdown",copyMd]);
  if(s.nativeId&&!s.sub&&["claude","codex"].includes(s.agent))it.push(["Fork this chat",()=>api("fork",{sid:S.open}).then(d=>setTimeout(()=>openChat(d.sid),800)).catch(e=>toast(e.message))]);
  if(s.managed&&s.agent==="claude")it.push(["Rename…",()=>{const n=prompt("Rename chat",s.title);if(n)api("command",{sid:S.open,text:"/rename "+n.trim()}).catch(e=>toast(e.message))}]);
  it.push(["Open dev server…",devServer]);
  if(s.managed)it.push(["Continue after usage limits…",async()=>{const d=await api("recovery",{sid:S.open});if(confirm((d.continue?"On":"Off")+" for this chat. Switch it "+(d.continue?"off":"on")+"?"))await api("recovery",{sid:S.open,chat:{continue:!d.continue}})}]);
  if(!s.sub)it.push(["New chat in this folder",()=>newChat(s.cwd,s.agent)]);if(s.parent)it.push(["Open parent chat",()=>openChat(s.parent)]);menu(a,it)}
function copyMd(){const s=cur();const t="# "+s.title+"\n\n"+S.msgs.filter(m=>m.r!=="tool").map(m=>m.r==="user"?"**You:** "+m.t:m.r==="system"?"_"+m.t+"_":m.t).join("\n\n");navigator.clipboard?.writeText(t).then(()=>toast("Copied")).catch(()=>{const w=open("","_blank");w.document.body.innerText=t})}
async function devServer(){try{const d=await api("previews",{sid:S.open});const ports=d.ports||[];let inp;dialog("Open a dev server here",x=>{ports.forEach(p=>{const b=el("button","btn tonal",p.url);b.onclick=()=>openPreview(p.port,p.path);x.append(b)});
  inp=field(x,ports.length?"Or another port":"Port the server runs on",el("input"));inp.inputMode="numeric";inp.placeholder="5173"},"Open",()=>{if(+inp.value)openPreview(+inp.value,"/")})}catch(e){toast(e.message)}}
async function openPreview(port,path){if(location.hostname==="127.0.0.1"||location.hostname==="localhost"){open("http://localhost:"+port+path,"_blank");return}
  try{const d=await api("preview",{port});open("http://"+location.hostname+":"+d.port+path,"_blank")}catch(e){toast(e.message)}}
function usageDialog(){const s=cur();if(!s)return;const u=s.usage||{},b=u.budget||{};let usd,tok,st;
  dialog(s.title,x=>{const rows=[];if(u.ctxPct!=null)rows.push(["Context used",Math.round(u.ctxPct)+"%"+(u.ctxSize?" of "+fmtTok(u.ctxSize):"")]);rows.push(["Input tokens",fmtTok(u.in)]);if(u.cached)rows.push(["Read from cache",fmtTok(u.cached)]);rows.push(["Output tokens",fmtTok(u.out)]);
    if(u.cost!=null)rows.push(["Cost (API prices)","$"+u.cost.toFixed(2)]);(u.limits||[]).forEach(l=>rows.push(["Plan limit "+l.label,Math.round(l.pct)+"%"]));
    rows.forEach(([k,v])=>{const r=el("div");r.style.cssText="display:flex;justify-content:space-between;padding:3px 0";r.append(el("span","sub",k),el("b",null,v));x.append(r)});
    x.append(Object.assign(el("h2",null,"Budget for this chat"),{style:"font-size:16px;margin-top:16px"}));usd=field(x,"Dollars",el("input"));usd.inputMode="decimal";usd.value=b.usd??"";
    tok=field(x,"or thousand tokens",el("input"));tok.inputMode="numeric";tok.value=b.tokens?b.tokens/1000:"";st=el("input");st.type="checkbox";st.checked=!!b.stop;st.style.width="auto";const l=el("label");l.append(st," Stop the chat when it's reached");x.append(l)},
    "Save budget",()=>api("budget",{sid:S.open,usd:+usd.value||0,tokens:(+tok.value||0)*1000,stop:st.checked}).then(()=>toast("Budget saved")))}
async function newChat(folder,agent){let ag=agent||localStorage.getItem("lastAgent")||"claude",host=localStorage.getItem("lastHost")||"",model,fo,pr,segBox,hostBox;
  dialog("New chat",x=>{segBox=el("div");x.append(segBox);hostBox=el("div");x.append(hostBox);model=field(x,"Model",el("select"));model.append(Object.assign(el("option",null,"Default model"),{value:""}));
    fo=field(x,"Folder",el("input"));fo.value=folder||localStorage.getItem("lastFolder")||"~";fo.setAttribute("list","folders");const dl=el("datalist");dl.id="folders";x.append(dl);pr=field(x,"First message (optional)",el("textarea"));pr.rows=3;
    const seg=(box,opts,get,set)=>{box.innerHTML="";const s=el("div","seg");opts.forEach(([n,v])=>{const b=el("button",get()===v?"on":"",n);b.onclick=()=>{set(v);seg(box,opts,get,set)};s.append(b)});box.append(s)};
    let models={};const fill=()=>{model.innerHTML="";model.append(Object.assign(el("option",null,"Default model"),{value:""}));(models[ag]||[]).filter(m=>m.id!=="default").forEach(m=>model.append(Object.assign(el("option",null,m.label),{value:m.id})))};
    seg(segBox,[["Claude","claude"],["Codex","codex"]],()=>ag,v=>{ag=v;fill()});
    api("agents").then(d=>seg(segBox,(d.agents||[]).map(a=>[({claude:"Claude",codex:"Codex",gemini:"Gemini",opencode:"OpenCode",kimi:"Kimi"})[a]||a,a]),()=>ag,v=>{ag=v;fill()})).catch(()=>{});
    api("models").then(d=>{(d.agents||[]).forEach(a=>models[a.id]=a.models||[]);fill()}).catch(()=>{});
    api("folders").then(d=>(d.folders||[]).forEach(f=>dl.append(Object.assign(el("option"),{value:f.replace(d.home,"~")})))).catch(()=>{});
    api("hosts").then(d=>{const hs=(d.hosts||[]).filter(h=>h.up).map(h=>h.host);if(!hs.length)return;if(!hs.includes(host))host="";const l=el("label",null,"Machine");hostBox.append(l);const b=el("div");hostBox.append(b);seg(b,[["This Mac",""],...hs.map(h=>[h.split("@").pop(),h])],()=>host,v=>host=v)}).catch(()=>{})},
  "Start",async()=>{localStorage.setItem("lastAgent",ag);localStorage.setItem("lastFolder",fo.value);localStorage.setItem("lastHost",host);const d=await api("start",{agent:ag,cwd:fo.value.trim()||"~",model:model.value,prompt:pr.value,host});setTimeout(()=>openChat(d.sid),700)})}
$("#new").onclick=()=>newChat();
$("#settings").onclick=e=>menu(e.currentTarget,[[(S.tap?"✓ ":"")+"Cost & plan limits (Claude statusline)",async()=>{if(!S.tap&&!confirm("PhoneCast wraps your Claude statusline (it keeps working as before) to read cost and plan limits. ~/.claude/settings.json is backed up first."))return;try{S.tap=await api("tap",{on:!S.tap})}catch(err){toast(err.message)}}],
  ["Continue chats after usage limits…",async()=>{const d=await api("recovery");const on=d.global&&d.global.continue;if(confirm("Continue after usage limits is "+(on?"on":"off")+" for all chats. Switch it "+(on?"off":"on")+"?"))await api("recovery",{global:{continue:!on}})}],
  ["Alert when an agent seems stuck…",async()=>{const v=prompt("Minutes without progress before an alert (0 = never)","10");if(v!=null)await api("recovery",{global:{stuckMin:+v>0?+v:100000}})}],
  ["Other machines…",async()=>{const d=await api("hosts");let f;dialog("Other machines",x=>{(d.hosts||[]).forEach(h=>x.append(el("div","sub",(h.up?"● ":"○ ")+h.host+"  "+(h.up?(h.tools||[]).join(", "):"not reachable"))));f=field(x,"SSH targets (user@host, comma separated)",el("input"));f.value=(d.hosts||[]).map(h=>h.host).join(", ")},"Save",()=>api("hosts",{set:f.value.split(/[,\s]+/).filter(Boolean)}).then(()=>toast("Saved")))}],
  ["Sign out this browser",()=>fetch("/logout",{method:"POST"}).then(showLogin)]]);
// ---------- polling ----------
async function tick(){try{const d=await api("list");const sig=JSON.stringify([d.list,d.plan]);S.installed=d.installed;S.tap=d.tap;
    if(sig!==S.sig){S.sig=sig;S.list=d.list||[];S.plan=d.plan||{};S.byId={};S.list.forEach(s=>S.byId[s.id]=s);renderList();if(S.open)refreshChat(false)}
    $("#login").hidden=true;$("#app").hidden=false;if(S.open&&!$("#ct"))buildChat()}catch(e){}}
setInterval(()=>{if(document.hidden)return;tick();if(S.open){if(S.view==="msgs")loadMsgs();else if(S.view==="term")loadTerm()}},1500);
tick().then(()=>{if(S.open&&S.byId[S.open])openChat(S.open)});
</script>
</body>
</html>
"""#
}
