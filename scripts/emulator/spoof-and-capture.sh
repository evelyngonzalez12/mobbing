#!/usr/bin/env bash
# Bing organic mobile traffic for gardengar.com
# Keyword: "slugs vs birds vs mice"
# Target result: "What Is Eating My Strawberries at Night? (Slugs vs Birds vs Mice)"
# - Spoofs ONLY device identity (Galaxy S24 Ultra)
# - Real touch tap from Bing search → organic traffic
# - Multi-page engagement in the same process
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACTS="${ROOT}/artifacts"
mkdir -p "$ARTIFACTS"

CHROME_PKG="com.android.chrome"
TARGET_URL="https://www.bing.com"
SEARCH_URL="https://www.bing.com/search?q=slugs+vs+birds+vs+mice"
RESULT_HOST="gardengar.com"
# Keywords used to identify the correct result
RESULT_TEXT="strawberries"
RESULT_TITLE_KEYWORDS="slugs|birds|mice|strawberries|eating"
HAVE_ROOT=0

log() { printf '[capture] %s\n' "$*"; }

adb_sh() {
  adb shell "$@" | tr -d '\r'
}

wait_for_boot() {
  adb wait-for-device
  local i=0
  while (( i < 180 )); do
    local completed
    completed="$(adb_sh getprop sys.boot_completed 2>/dev/null || true)"
    if [[ "$completed" == "1" ]]; then
      sleep 6
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  log "timed out waiting for boot"
  return 1
}

uid_is_root() {
  local uid
  uid="$(adb_sh id -u 2>/dev/null || true)"
  [[ "$uid" == "0" ]]
}

ensure_root() {
  local i out
  for i in 1 2 3 4 5 6; do
    if uid_is_root; then
      log "adb shell is root (uid=0)"
      return 0
    fi
    out="$(adb root 2>&1 || true)"
    log "adb root (${i}): ${out}"
    sleep 3
    adb wait-for-device
  done
  if uid_is_root; then
    log "adb shell is root (uid=0)"
    return 0
  fi
  log "no root — identity spoofing limited"
  return 1
}

samsung_prop_file() {
  cat <<'PROP'
ro.product.brand=samsung
ro.product.manufacturer=samsung
ro.product.model=SM-S928B
ro.product.name=e3sxxx
ro.product.device=e3s
ro.product.marketname=Galaxy S24 Ultra
ro.build.fingerprint=samsung/e3sxxx/e3s:14/UP1A.231005.007/S928BXXS3AXKF:user/release-keys
ro.build.type=user
ro.build.tags=release-keys
ro.build.version.release=14
ro.build.version.sdk=34
ro.sf.lcd_density=420
PROP
}

write_samsung_identity() {
  local tmp
  tmp="$(mktemp)"
  samsung_prop_file > "$tmp"
  adb push "$tmp" /data/local.prop
  adb_sh chmod 644 /data/local.prop
  rm -f "$tmp"
  log "pushed /data/local.prop (device only – no geo)"
  adb_sh ls -l /data/local.prop || true
}

dump_identity() {
  {
    echo "=== shell ==="
    adb_sh id || true
    echo "ro.debuggable=$(adb_sh getprop ro.debuggable)"
    echo "ro.build.type=$(adb_sh getprop ro.build.type)"
    echo
    echo "=== identity ==="
    for key in \
      ro.product.brand ro.product.manufacturer ro.product.model \
      ro.product.name ro.product.device ro.product.marketname \
      ro.build.fingerprint ro.build.version.release ro.build.version.sdk \
      ro.build.characteristics ro.hardware ro.kernel.qemu \
      persist.sys.locale persist.sys.timezone; do
      printf '%s=%s\n' "$key" "$(adb_sh getprop "$key")"
    done
    echo
    echo "=== display ==="
    adb_sh wm size || true
    adb_sh wm density || true
  } | tee "$ARTIFACTS/identity.txt"
}

skip_chrome_welcome() {
  local cmdline='chrome --disable-fre --no-first-run --no-default-browser-check --disable-search-engine-choice-screen --disable-features=TranslateUI,ChromeWhatsNew,PrivacySandboxSettings4,InterestFeedContentSuggestions'
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$cmdline" > "$tmp"
  adb shell am set-debug-app --persistent "$CHROME_PKG" >/dev/null || true
  adb push "$tmp" /data/local/tmp/chrome-command-line >/dev/null
  adb_sh chmod 644 /data/local/tmp/chrome-command-line || true
  if [[ "$HAVE_ROOT" == "1" ]]; then
    adb push "$tmp" /data/local/chrome-command-line >/dev/null || true
    adb_sh chmod 644 /data/local/chrome-command-line || true
  fi
  rm -f "$tmp"
  adb shell pm grant "$CHROME_PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  adb shell am force-stop "$CHROME_PKG" >/dev/null 2>&1 || true
  log "Chrome first-run flags written"
}

dismiss_chrome_sheets() {
  python3 - <<'PY'
import re, subprocess, time
EXACT = {
    "use without an account", "no thanks", "no, thanks", "don't allow",
    "not now", "skip", "got it", "accept & continue", "accept and continue",
    "no thanks, i'll stay signed out", "reject all", "accept all",
    "i agree", "dismiss",
}
def dump():
    subprocess.run(["adb","shell","uiautomator","dump","/sdcard/uidump.xml"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    p = subprocess.run(["adb","exec-out","cat","/sdcard/uidump.xml"],
                       capture_output=True, check=False)
    return p.stdout.decode("utf-8","replace")
def nodes(xml):
    for m in re.finditer(r"<node\s+([^>]+)/?>", xml):
        a = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
        mm = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", a.get("bounds",""))
        if not mm: continue
        x1,y1,x2,y2 = map(int, mm.groups())
        yield (a.get("text","").strip().lower(),
               a.get("content-desc","").strip().lower(),
               (x1+x2)//2, (y1+y2)//2)
tapped = 0
for _ in range(6):
    found = False
    for text, desc, x, y in nodes(dump()):
        if text in EXACT or desc in EXACT:
            subprocess.run(["adb","shell","input","tap",str(x),str(y)], check=False)
            tapped += 1; found = True; time.sleep(1.2)
            break
    if not found: break
print(f"dismissed {tapped} sheets", flush=True)
PY
}

resolve_chrome() {
  local pkg
  for pkg in com.android.chrome com.chrome.beta com.chrome.dev org.chromium.chrome; do
    if adb_sh pm path "$pkg" 2>/dev/null | grep -q "package:"; then
      CHROME_PKG="$pkg"
      log "using browser package ${CHROME_PKG}"
      return 0
    fi
  done
  log "Chrome is not installed"
  return 1
}

open_url() {
  adb shell am force-stop "$CHROME_PKG" >/dev/null 2>&1 || true
  sleep 1.5
  adb shell am start \
    -p "$CHROME_PKG" \
    -a android.intent.action.VIEW \
    -c android.intent.category.BROWSABLE \
    -d "$1" \
    -f 0x10000000 >/dev/null
  log "opened $1"
  sleep 5
}

wait_for_devtools() {
  local max_attempts="${1:-30}"
  local i=0
  adb forward --remove tcp:9222 >/dev/null 2>&1 || true
  adb forward tcp:9222 localabstract:chrome_devtools_remote >/dev/null 2>&1 || true
  while (( i < max_attempts )); do
    if curl -s --max-time 3 http://127.0.0.1:9222/json >/dev/null 2>&1; then
      local count
      count=$(curl -s --max-time 3 http://127.0.0.1:9222/json 2>/dev/null | \
        python3 -c "import sys,json; print(len([t for t in json.load(sys.stdin) if t.get('type')=='page']))" 2>/dev/null || echo 0)
      if [[ "$count" -gt 0 ]]; then
        log "DevTools ready (${count} page tab(s))"
        return 0
      fi
    fi
    sleep 1.5
    i=$((i + 1))
    if (( i % 6 == 0 )); then
      adb forward --remove tcp:9222 >/dev/null 2>&1 || true
      adb forward tcp:9222 localabstract:chrome_devtools_remote >/dev/null 2>&1 || true
    fi
  done
  log "DevTools not ready after ${max_attempts} attempts"
  return 1
}

screenshot() {
  local name="$1"
  adb exec-out screencap -p > "${ARTIFACTS}/${name}"
  log "wrote ${ARTIFACTS}/${name} ($(wc -c < "${ARTIFACTS}/${name}") bytes)"
}

settle_device() {
  adb shell svc power stayon true >/dev/null || true
  adb shell settings put global stay_on_while_plugged_in 3 >/dev/null || true
  adb shell settings put secure lockscreen.disabled 1 >/dev/null || true
  adb shell locksettings set-disabled true >/dev/null 2>&1 || true
  adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
  adb_sh wm size 1080x2340 || true
  adb_sh wm density 420 || true
}

# ---------------------------------------------------------------------------
do_organic_and_engage() {
  python3 -m pip install -q websocket-client --break-system-packages >/dev/null 2>&1 \
    || python3 -m pip install -q websocket-client >/dev/null 2>&1 || true

  adb forward --remove tcp:9222 >/dev/null 2>&1 || true
  adb forward tcp:9222 localabstract:chrome_devtools_remote >/dev/null 2>&1 || true

  RESULT_HOST="$RESULT_HOST" RESULT_TEXT="$RESULT_TEXT" ARTIFACTS="$ARTIFACTS" python3 - <<'PY'
import json, os, sys, time, random, urllib.request, subprocess, re
import websocket

HOST = os.environ["RESULT_HOST"].strip().lower()
TARGET = os.environ["RESULT_TEXT"].strip().lower()
ARTIFACTS = os.environ["ARTIFACTS"]

NUM_PAGES = random.randint(4, 5)
MIN_DWELL = 35
MAX_DWELL = 80

def get_tabs():
    with urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=8) as r:
        return json.loads(r.read().decode())

def find_bing_tab():
    try:
        pages = [t for t in get_tabs() if t.get("type") == "page"]
        pages.sort(key=lambda t: 0 if "bing." in t.get("url", "").lower() else 1)
        return pages[0] if pages else None
    except Exception:
        return None

def find_target_tab():
    try:
        for t in get_tabs():
            if t.get("type") != "page":
                continue
            url = t.get("url", "").lower()
            if HOST in url and "bing." not in url and "google." not in url and "chrome-error" not in url:
                return t
    except Exception:
        pass
    return None

tab = None
for _ in range(40):
    tab = find_bing_tab()
    if tab:
        break
    time.sleep(1.2)

if not tab:
    print("DevTools tab not reachable", flush=True)
    sys.exit(2)

print("attached to:", tab.get("url"), flush=True)

ws = websocket.create_connection(
    tab["webSocketDebuggerUrl"],
    timeout=120,
    suppress_origin=True,
    ping_interval=12,
    ping_timeout=8
)

_id = 0
def cdp(method, **params):
    global _id, ws, tab
    for attempt in range(4):
        try:
            _id += 1
            ws.send(json.dumps({"id": _id, "method": method, "params": params}))
            deadline = time.time() + 25
            while time.time() < deadline:
                msg = json.loads(ws.recv())
                if msg.get("id") == _id:
                    return msg.get("result", {})
        except Exception as e:
            print(f"CDP error ({attempt+1}): {e}", flush=True)
            try:
                ws.close()
            except: pass
            time.sleep(2)
            new_tab = find_target_tab() or find_bing_tab()
            if not new_tab:
                raise
            tab = new_tab
            print(f"reconnected to: {tab.get('url')}", flush=True)
            ws = websocket.create_connection(
                tab["webSocketDebuggerUrl"],
                timeout=120, suppress_origin=True,
                ping_interval=12, ping_timeout=8
            )
    raise RuntimeError("CDP failed after retries")

def js(expr):
    r = cdp("Runtime.evaluate", expression=expr, returnByValue=True)
    return r.get("result", {}).get("value")

cdp("Page.enable")
cdp("Runtime.enable")
cdp("Network.enable")

# ---------- BING ORGANIC CLICK ----------
print("=== BING ORGANIC CLICK PHASE ===", flush=True)

# Find the specific article on Bing SERP
FIND_JS = """(() => {
  const HOST = %s;
  const KEYWORDS = ['strawberry', 'strawberries', 'slug', 'slugs', 'bird', 'birds', 'mice', 'mouse', 'eating', 'night'];
  const vis = e => {
    const r = e.getBoundingClientRect(), st = getComputedStyle(e);
    return r.width > 6 && r.height > 6 && st.visibility !== 'hidden' && st.display !== 'none';
  };

  // Bing uses h2 / h3 for result titles, often inside <a>
  const candidates = [];
  const links = [...document.querySelectorAll('a[href]')];

  for (const a of links) {
    if (!vis(a)) continue;
    const href = (a.href || '').toLowerCase();
    const text = ((a.innerText || a.textContent || '') + ' ' + (a.getAttribute('aria-label') || '')).toLowerCase();

    // Must point to our domain or contain the domain in URL
    const isOurDomain = href.includes(HOST) || href.includes('gardengar');
    if (!isOurDomain && !text.includes('gardengar')) continue;

    // Score by relevance to the target article
    let score = 0;
    if (a.querySelector('h2, h3, [role=heading]')) score += 10;
    if (text.includes('strawberry') || text.includes('strawberries')) score += 8;
    if (text.includes('slug') || text.includes('slugs')) score += 6;
    if (text.includes('bird') || text.includes('birds')) score += 4;
    if (text.includes('mice') || text.includes('mouse')) score += 4;
    if (text.includes('eating') || text.includes('night')) score += 3;
    if (href.includes(HOST) && !href.includes('bing.com')) score += 5;

    if (score >= 8) {
      const titleEl = a.querySelector('h2, h3, [role=heading]') || a;
      const r = titleEl.getBoundingClientRect();
      candidates.push({
        tag: titleEl.tagName,
        text: (titleEl.innerText || a.innerText || '').trim().slice(0, 120),
        href: a.href,
        x: r.left + r.width / 2,
        y: r.top + r.height / 2,
        score: score
      });
    }
  }

  candidates.sort((x, y) => y.score - x.score);
  const best = candidates.length ? candidates[0] : null;

  return JSON.stringify({
    found: best,
    count: candidates.length,
    scrollY: window.scrollY,
    innerH: window.innerHeight,
    innerW: window.innerWidth,
    maxY: Math.max(0, document.documentElement.scrollHeight - window.innerHeight)
  });
})()""" % json.dumps(HOST)

def smooth_scroll(dist, x, y):
    cdp("Input.synthesizeScrollGesture", x=x, y=y, yDistance=-dist, speed=480, gestureSourceType="touch")
    time.sleep(1.1)

def is_target(url):
    u = (url or "").lower()
    return HOST in u and "bing." not in u and "google." not in u and "chrome-error" not in u

success = False
for attempt in range(40):
    info = json.loads(js(FIND_JS) or "{}")
    found = info.get("found")
    H = info.get("innerH", 800)
    W = info.get("innerW", 400)

    if found and 60 < found["y"] < H - 60:
        print(f"found <{found['tag']}> '{found['text']}' score={found.get('score')}", flush=True)
        cdp("Input.synthesizeTapGesture", x=found["x"], y=found["y"])
        print("real Bing organic tap performed – waiting...", flush=True)

        for w in range(20):
            time.sleep(1.4)
            try:
                now = (js("location.href") or "").lower()
                print(f"  [{w+1}] {now[:100]}", flush=True)
                if is_target(now):
                    print("SUCCESS: Bing organic landing confirmed", flush=True)
                    success = True
                    break
            except Exception:
                pass

            t = find_target_tab()
            if t:
                print(f"SUCCESS: target in another tab → {t.get('url')}", flush=True)
                try: ws.close()
                except: pass
                tab = t
                ws = websocket.create_connection(tab["webSocketDebuggerUrl"], timeout=120, suppress_origin=True, ping_interval=12, ping_timeout=8)
                cdp("Page.enable")
                cdp("Runtime.enable")
                success = True
                break
        if success:
            break
    else:
        if found:
            print("found but off-screen, scrolling...", flush=True)
            smooth_scroll(int(found["y"] - H/2), int(W/2), int(H*0.55))
        else:
            print(f"target not found yet (attempt {attempt})", flush=True)
            if info.get("scrollY", 0) >= info.get("maxY", 0) - 20 and attempt > 5:
                break
            smooth_scroll(int(H*0.38), int(W/2), int(H*0.60))

if not success:
    print("FAILED: could not complete real Bing organic click", flush=True)
    sys.exit(1)

# Screenshots
subprocess.run(["adb", "exec-out", "screencap", "-p"],
               stdout=open(os.path.join(ARTIFACTS, "03-organic-landed.png"), "wb"), check=False)
time.sleep(2)
subprocess.run(["adb", "exec-out", "screencap", "-p"],
               stdout=open(os.path.join(ARTIFACTS, "04-organic-settled.png"), "wb"), check=False)

# ---------- ENGAGEMENT ----------
print("\n=== ENGAGEMENT PHASE ===", flush=True)
print(f"will visit {NUM_PAGES} pages", flush=True)

def page_dims():
    return json.loads(js("""(() => JSON.stringify({
        H: window.innerHeight, W: window.innerWidth,
        scrollY: window.scrollY,
        maxY: Math.max(0, document.documentElement.scrollHeight - window.innerHeight)
    }))()""") or "{}")

def smooth_scroll_random(sec):
    end = time.time() + sec
    count = 0
    while True:
        remaining = end - time.time()
        if remaining <= 0.4:
            break
        d = page_dims()
        H, W = d.get("H", 800), d.get("W", 400)
        maxY, curY = d.get("maxY", 0), d.get("scrollY", 0)
        if curY >= maxY - 30 and maxY > 0:
            direction = 1
        elif curY < 40:
            direction = -1
        else:
            direction = -1 if random.random() < 0.75 else 1
        dist = random.randint(int(H*0.22), int(H*0.48))
        speed = random.randint(280, 580)
        x = int(W * random.uniform(0.30, 0.70))
        y = int(H * random.uniform(0.40, 0.70))
        try:
            cdp("Input.synthesizeScrollGesture", x=x, y=y, yDistance=direction*dist, speed=speed, gestureSourceType="touch")
            count += 1
        except Exception as e:
            print(f"  scroll error: {e}", flush=True)
        pause = random.uniform(1.6, 3.8)
        remaining = end - time.time()
        if remaining <= 0:
            break
        time.sleep(min(pause, remaining))
    print(f"  {count} scrolls", flush=True)

def find_good_internal_links():
    raw = js("""(() => {
        const host = location.hostname.replace(/^www\\./,'').replace(/^m\\./,'');
        const bad = ['/about','/contact','/privacy','/terms','/licensing','/cookie','/login'];
        const vis = e => {
            const r = e.getBoundingClientRect(), st = getComputedStyle(e);
            return r.width > 12 && r.height > 12 && st.visibility !== 'hidden' && st.display !== 'none';
        };
        const links = [...document.querySelectorAll('a[href]')].filter(a => {
            try {
                const u = new URL(a.href, location.href);
                if (u.hostname.replace(/^www\\./,'').replace(/^m\\./,'') !== host) return false;
                const p = u.pathname.toLowerCase();
                if (bad.some(b => p.includes(b))) return false;
                if (u.hash && u.pathname === location.pathname) return false;
                return vis(a);
            } catch(e){return false;}
        });
        const score = a => {
            let s = 0;
            const t = (a.innerText || '').trim().toLowerCase();
            const href = a.href.toLowerCase();
            if (/\\/20[0-9]{2}\\//.test(href) || /\\/blog\\//.test(href)) s += 8;
            if (a.querySelector('h1,h2,h3,h4')) s += 5;
            if (t.length > 25 && t.length < 120) s += 3;
            if (/\\/category\\//.test(href)) s += 4;
            return s;
        };
        links.sort((x,y) => score(y) - score(x));
        return JSON.stringify(links.slice(0, 18).map(a => {
            const t = a.querySelector('h1,h2,h3,h4') || a;
            const r = t.getBoundingClientRect();
            return {text: (t.innerText||'').trim().slice(0,80), href: a.href,
                    x: r.left+r.width/2, y: r.top+r.height/2, score: score(a)};
        }));
    })()""")
    try: return json.loads(raw or "[]")
    except: return []

visited = set()
current = js("location.href") or ""
print("starting engagement on:", current, flush=True)

for page_num in range(1, NUM_PAGES + 1):
    print(f"\n===== PAGE {page_num}/{NUM_PAGES} =====", flush=True)
    dwell = random.randint(MIN_DWELL, MAX_DWELL)
    print(f"  dwelling ~{dwell}s...", flush=True)
    smooth_scroll_random(dwell)

    try:
        name = f"0{4 + page_num}-page{page_num}.png"
        subprocess.run(["adb", "exec-out", "screencap", "-p"],
                       stdout=open(os.path.join(ARTIFACTS, name), "wb"), check=False)
        print(f"  screenshot {name}", flush=True)
    except Exception as e:
        print(f"  screenshot failed: {e}", flush=True)

    if page_num >= NUM_PAGES:
        break

    links = find_good_internal_links()
    candidates = [L for L in links if L["href"] not in visited and L.get("score", 0) >= 3]
    if not candidates:
        candidates = [L for L in links if L["href"] not in visited]
    if not candidates:
        print("  no more good internal links", flush=True)
        break

    top = sorted(candidates, key=lambda x: x.get("score", 0), reverse=True)[:6]
    choice = random.choice(top)
    visited.add(choice["href"])
    print(f"  tapping '{choice['text'][:55]}' → {choice['href']}", flush=True)

    old_url = (js("location.href") or "").rstrip("/")
    cdp("Input.synthesizeTapGesture", x=choice["x"], y=choice["y"])
    time.sleep(4.5)
    new_url = (js("location.href") or "").rstrip("/")
    if new_url == old_url and choice["href"] not in new_url:
        print("  tap missed – soft navigate", flush=True)
        cdp("Page.navigate", url=choice["href"])
        time.sleep(3.5)
    print("  now:", js("location.href"), flush=True)

print("\n===== FINAL DWELL =====", flush=True)
smooth_scroll_random(random.randint(18, 35))
subprocess.run(["adb", "exec-out", "screencap", "-p"],
               stdout=open(os.path.join(ARTIFACTS, "09-final.png"), "wb"), check=False)

print("visited:", list(visited), flush=True)
ws.close()
print("ALL DONE – Bing organic + engagement completed", flush=True)
PY
}

# ===================== MAIN =====================
log "waiting for first boot"
wait_for_boot

if ensure_root; then
  HAVE_ROOT=1
fi

settle_device
dump_identity

if [[ "$HAVE_ROOT" == "1" ]]; then
  write_samsung_identity
  log "rebooting so identity props load"
  adb reboot
  wait_for_boot
  if ensure_root; then HAVE_ROOT=1; else HAVE_ROOT=0; fi
  settle_device
  dump_identity
else
  log "skipping /data/local.prop (no root)"
fi

resolve_chrome
skip_chrome_welcome

# 1) Bing home
open_url "$TARGET_URL"
sleep 6
dismiss_chrome_sheets
screenshot "01-bing-home.png"

# 2) Search
log "opening Bing search: slugs vs birds vs mice"
open_url "$SEARCH_URL"
sleep 9
dismiss_chrome_sheets
screenshot "02-search-results.png"

if ! wait_for_devtools 25; then
  log "DevTools not ready – one more restart"
  open_url "$SEARCH_URL"
  sleep 10
  wait_for_devtools 20 || true
fi

log "starting Bing organic click + engagement"
if do_organic_and_engage; then
  screenshot "10-engagement-done.png"
  log "SUCCESS – Bing organic traffic completed"
else
  log "FAILED"
  screenshot "03-organic-failed.png"
  exit 1
fi

log "done"
ls -la "$ARTIFACTS"
