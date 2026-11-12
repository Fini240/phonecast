import Foundation

/// "Phone in a browser": the phone's notifications and text messages on any device that can open the
/// Agents page (iPad, school laptop): http://<Mac>:27190/phone, same sign-in code. Like AirDroid Web,
/// but it goes through the Mac's link to the phone, so nothing leaves your network.
enum PhoneWeb {
    /// One API call from the page: {m, p}. Answers {ok, data | message}.
    static func handle(_ o: [String: Any], done: @escaping ([String: Any]) -> Void) {
        let m = o["m"] as? String ?? "", p = o["p"] as? [String: Any] ?? [:]
        let hub = Hub.shared
        func proxy(_ method: String, _ params: [String: Any] = [:]) {
            guard hub.connected else { done(["ok": false, "message": "The phone isn't connected to the Mac."]); return }
            hub.request(method, params) { r in
                switch r {
                case .success(let d): done(["ok": true, "data": d])
                case .failure(let e): done(["ok": false, "message": e.permission ? "Allow this in the PhoneCast app on the phone." : e.message])
                }
            }
        }
        switch m {
        case "status":
            DispatchQueue.main.async {
                done(["ok": true, "data": ["connected": hub.connected, "phone": hub.store.phoneName, "battery": hub.store.phoneStatus["battery"] ?? NSNull()]])
            }
        case "notifs":
            DispatchQueue.main.async {
                let list = hub.store.notifications.prefix(150).map { n -> [String: Any] in
                    ["key": n.key, "app": n.app, "title": n.title, "text": n.text, "date": n.date.timeIntervalSince1970 * 1000, "canReply": n.canReply]
                }
                done(["ok": true, "data": list])
            }
        case "notif.action":
            let key = p["key"] as? String ?? "", action = p["action"] as? String ?? ""
            guard ["reply", "dismiss", "open"].contains(action), !key.isEmpty else { done(["ok": false, "message": "bad action"]); return }
            DispatchQueue.main.async {
                hub.notifAction(key, action, p["text"] as? String ?? "")
                if action == "dismiss" { hub.store.notifications.removeAll { $0.key == key } }
                done(["ok": true])
            }
        case "threads": proxy("sms.threads", ["limit": 80])
        case "thread": proxy("sms.thread", ["thread": p["thread"] as? NSNumber ?? 0, "limit": 150])
        case "send":
            let to = p["to"] as? String ?? "", text = p["text"] as? String ?? ""
            guard !to.isEmpty, !text.isEmpty else { done(["ok": false, "message": "Number and text needed."]); return }
            proxy("sms.send", ["to": to, "text": text])
        case "ring": proxy("phone.ring", ["on": p["on"] as? Bool ?? true])
        default: done(["ok": false, "message": "unknown request"])
        }
    }

    static let html = #"""
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>PhoneCast · Phone</title>
<style>
:root{--bg:#f5f5f7;--card:#fff;--text:#1d1d1f;--text2:#6e6e73;--line:#e3e3e8;--accent:#0a84ff;--me:#0a84ff;--them:#e9e9ee}
@media (prefers-color-scheme:dark){:root{--bg:#161618;--card:#222225;--text:#f2f2f4;--text2:#9a9aa0;--line:#333338;--accent:#0a84ff;--me:#0a6fd8;--them:#333338}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
header{display:flex;flex-wrap:wrap;align-items:center;gap:10px 12px;padding:14px 16px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:2}
h1{font-size:18px;margin:0;flex:1}.sub{color:var(--text2);font-size:13px}
nav{display:flex;gap:6px}@media (max-width:560px){nav{width:100%}nav button,nav .btn{flex:1;text-align:center}}h1{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}nav button,.btn{border:1px solid var(--line);background:var(--card);color:var(--text);border-radius:8px;padding:6px 12px;font:inherit;cursor:pointer}
nav button.on{background:var(--accent);border-color:var(--accent);color:#fff}
main{max-width:860px;margin:0 auto;padding:12px 16px 40px}
.item{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px;margin:8px 0}
.row{display:flex;gap:8px;align-items:baseline}.grow{flex:1;min-width:0}.app{font-size:12px;color:var(--text2)}.t{font-weight:600}
.time{font-size:12px;color:var(--text2);white-space:nowrap}.txt{white-space:pre-wrap;word-break:break-word}
.acts{display:flex;gap:6px;margin-top:8px;flex-wrap:wrap}.acts .btn{padding:4px 10px;font-size:13px}
input,textarea{font:inherit;color:var(--text);background:var(--card);border:1px solid var(--line);border-radius:8px;padding:8px 10px;width:100%}
.thread{cursor:pointer}.badge{background:var(--accent);color:#fff;border-radius:9px;padding:0 7px;font-size:12px}
.bubbles{display:flex;flex-direction:column;gap:6px;margin:8px 0 90px}.b{max-width:78%;padding:7px 11px;border-radius:14px;white-space:pre-wrap;word-break:break-word}
.b.me{align-self:flex-end;background:var(--me);color:#fff}.b.them{align-self:flex-start;background:var(--them)}
.compose{position:fixed;left:0;right:0;bottom:0;background:var(--bg);border-top:1px solid var(--line);padding:10px 16px calc(10px + env(safe-area-inset-bottom))}
.compose div{max-width:860px;margin:0 auto;display:flex;gap:8px}.empty{color:var(--text2);text-align:center;padding:40px 0}
#login{max-width:340px;margin:80px auto;text-align:center}#login input{text-align:center;font-size:22px;letter-spacing:4px;margin:12px 0}
</style></head><body>
<div id="login" hidden><h1>PhoneCast</h1><p class="sub">Enter the 6-digit code shown on the Mac (PhoneCast → Agents).</p>
<input id="code" inputmode="numeric" maxlength="6" autocomplete="one-time-code"><button class="btn" id="go">Sign in</button><p id="lerr" class="sub"></p></div>
<div id="app" hidden>
<header><div class="grow" style="min-width:0"><h1 id="phone">Phone</h1><div class="sub" id="state"></div></div>
<nav><button id="tn" class="on">Notifications</button><button id="tm">Messages</button><a class="btn" href="/" style="text-decoration:none">Agents</a></nav></header>
<main id="main"></main></div>
<script>
const $=s=>document.querySelector(s);let tab="n",thread=null,timer=null;
async function api(m,p={}){const r=await fetch("/phoneapi",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({m,p})});
 if(r.status==401){showLogin();throw "signin"}return r.json()}
function esc(s){return String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]))}
function when(ms){const d=new Date(ms),n=new Date();return d.toDateString()==n.toDateString()?d.toLocaleTimeString([], {hour:"2-digit",minute:"2-digit"}):d.toLocaleDateString([], {day:"numeric",month:"short"})}
function showLogin(){$("#app").hidden=true;$("#login").hidden=false;clearInterval(timer)}
$("#go").onclick=async()=>{const r=await fetch("/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({code:$("#code").value,name:"Phone page"})});
 const j=await r.json();if(j.ok){$("#login").hidden=true;start()}else $("#lerr").textContent=j.message||"Wrong code"};
$("#tn").onclick=()=>{tab="n";thread=null;render()};$("#tm").onclick=()=>{tab="m";thread=null;render()};
async function status(){const s=await api("status");if(!s.ok)return;$("#phone").textContent=s.data.phone||"Phone";
 $("#state").textContent=s.data.connected?("Connected"+(s.data.battery!=null?" · "+s.data.battery+" %":"")):"Not connected to the Mac"}
async function render(){$("#tn").classList.toggle("on",tab=="n");$("#tm").classList.toggle("on",tab=="m");
 if(tab=="n")return notifs();if(thread)return openThread(thread);return threads()}
async function notifs(){const r=await api("notifs");const m=$("#main");if(!r.ok){m.innerHTML=`<p class="empty">${esc(r.message)}</p>`;return}
 if(!r.data.length){m.innerHTML='<p class="empty">No notifications.</p>';return}
 m.innerHTML=r.data.map((n,i)=>`<div class="item"><div class="row"><div class="grow"><div class="app">${esc(n.app)}</div><div class="t">${esc(n.title)}</div></div><div class="time">${when(n.date)}</div></div>
 <div class="txt">${esc(n.text)}</div><div class="acts">${n.canReply?`<button class="btn" data-r="${i}">Reply</button>`:""}<button class="btn" data-o="${i}">Open on phone</button><button class="btn" data-d="${i}">Dismiss</button></div></div>`).join("");
 m.querySelectorAll("[data-d]").forEach(b=>b.onclick=async()=>{await api("notif.action",{key:r.data[b.dataset.d].key,action:"dismiss"});notifs()});
 m.querySelectorAll("[data-o]").forEach(b=>b.onclick=()=>api("notif.action",{key:r.data[b.dataset.o].key,action:"open"}));
 m.querySelectorAll("[data-r]").forEach(b=>b.onclick=async()=>{const t=prompt("Reply to "+r.data[b.dataset.r].title);if(t){await api("notif.action",{key:r.data[b.dataset.r].key,action:"reply",text:t});b.textContent="Sent"}})}
async function threads(){const r=await api("threads");const m=$("#main");if(!r.ok){m.innerHTML=`<p class="empty">${esc(r.message)}</p>`;return}
 m.innerHTML=`<div class="item"><div class="row"><input id="nto" placeholder="New message to (number)"><button class="btn" id="nnew">Write</button></div></div>`+
 (r.data.length?r.data.map((t,i)=>`<div class="item thread" data-i="${i}"><div class="row"><div class="grow"><div class="t">${esc(t.name||t.address)} ${t.unread?`<span class="badge">${t.unread}</span>`:""}</div><div class="sub txt">${t.mine?"You: ":""}${esc(t.snippet)}</div></div><div class="time">${when(t.date)}</div></div></div>`).join(""):'<p class="empty">No messages.</p>');
 m.querySelectorAll(".thread").forEach(e=>e.onclick=()=>{thread=r.data[e.dataset.i];openThread(thread)});
 $("#nnew").onclick=()=>{const to=$("#nto").value.trim();if(to){thread={thread:0,address:to,name:to};openThread(thread)}}}
async function openThread(t){const m=$("#main");let msgs=[];
 if(t.thread){const r=await api("thread",{thread:t.thread});if(r.ok)msgs=r.data}
 const keep=document.activeElement&&document.activeElement.id=="msg"?$("#msg").value:null;
 m.innerHTML=`<div class="row"><button class="btn" id="back">‹ Back</button><div class="t grow">${esc(t.name||t.address)}</div></div><div class="bubbles">${
  msgs.slice().reverse().map(x=>`<div class="b ${x.mine?"me":"them"}">${esc(x.text||(x.image?"[picture]":""))}<div class="time" style="color:inherit;opacity:.7">${when(x.date)}</div></div>`).join("")}</div>
  <div class="compose"><div><textarea id="msg" rows="1" placeholder="Text message"></textarea><button class="btn" id="send">Send</button></div></div>`;
 if(keep!=null){$("#msg").value=keep;$("#msg").focus()}
 $("#back").onclick=()=>{thread=null;threads()};
 $("#send").onclick=async()=>{const txt=$("#msg").value.trim();if(!txt)return;$("#send").disabled=true;
  const r=await api("send",{to:t.address,text:txt});$("#send").disabled=false;if(!r.ok){alert(r.message);return}$("#msg").value="";setTimeout(()=>openThread(t),1500)};
 window.scrollTo(0,document.body.scrollHeight)}
function start(){$("#app").hidden=false;status();render();clearInterval(timer);
 timer=setInterval(()=>{status();if(document.activeElement?.id!="msg")render()},8000)}
api("status").then(start).catch(()=>{});
</script></body></html>
"""#
}
