#!/bin/bash
set -e

echo "📦 Installing system dependencies..."
sudo apt update -qq
sudo apt install -y -qq p7zip-full aria2 python3 python3-requests python3-pip curl

pip3 install --no-cache-dir --break-system-packages magnet2torrent requests

echo "🧲 Processing Torrent & Direct Links..."
mkdir -p downloads torrents

python3 - << 'EOF'
import asyncio
import os
import requests
from urllib.parse import urlparse
from magnet2torrent import Magnet2Torrent

link_url = "https://pink-script-snap.lovable.app/api/public/page/0e01cfaf-128c-477f-bff1-9dee23822d97.txt"

async def main():
    try:
        ks = requests.get(link_url, timeout=10).text
        if "STOP.ALL.TORRENTS" in ks:
            print("🛑 Global kill switch active.")
            return
            
        direct_links = []
        for i, link in enumerate(ks.splitlines()):
            link = link.strip()
            if link and not link.startswith('#') and not link.endswith(' NO'):
                if link.startswith('magnet:'):
                    print(f"📥 Converting magnet: {link[:60]}...", flush=True)
                    try:
                        m2t = Magnet2Torrent(link)
                        filename, torrent_data = await asyncio.wait_for(m2t.retrieve_torrent(), timeout=30)
                        torrent_path = os.path.join("torrents", f"{filename}.torrent")
                        with open(torrent_path, "wb") as f:
                            f.write(torrent_data)
                        print(f"✅ Saved torrent: {torrent_path}")
                    except Exception as e:
                        print(f"⚠️ Magnet conversion failed ({e}). Queuing fallback!", flush=True)
                        direct_links.append(link)
                elif link.startswith('http'):
                    if link.endswith('.torrent'):
                        try:
                            tor_data = requests.get(link, timeout=15).content
                            parsed = urlparse(link)
                            filename = os.path.basename(parsed.path) or f"download_{i}.torrent"
                            with open(os.path.join('torrents', filename), 'wb') as tf:
                                tf.write(tor_data)
                            print(f"✅ Downloaded .torrent file: {filename}")
                        except Exception as e:
                            print(f"❌ Failed downloading torrent file ({e}): {link}")
                    else:
                        direct_links.append(link)
                        print(f"🔗 Queued direct HTTP download: {link}")
                        
        if direct_links:
            with open('direct_links.txt', 'w') as f:
                f.write('\n'.join(direct_links))
                
    except Exception as e:
        print(f"Error processing links: {e}")

asyncio.run(main())
EOF

echo "🚀 Starting aria2c downloads..."
python3 -u - << 'EOF'
import os, glob, asyncio, re, time, requests

def get_best_trackers():
    fallback_trackers = [
        "udp://tracker.openbittorrent.com:80/announce",
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce"
    ]
    try:
        url = "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt"
        res = requests.get(url, timeout=5)
        if res.status_code == 200:
            fetched = [line.strip() for line in res.text.splitlines() if line.strip()]
            if fetched:
                return ",".join(fetched)
    except Exception:
        pass
    return ",".join(fallback_trackers)

LIVE_TRACKERS = get_best_trackers()

async def download_target(target, sem, stuck_timeout=90, max_retries=3):
    async with sem:
        for attempt in range(1, max_retries + 1):
            cmd = [
                "aria2c", "--console-log-level=notice", "--summary-interval=2",
                "--dir=downloads", "--seed-time=0", "--file-allocation=none",
                "--enable-dht=true", "--enable-peer-exchange=true", "--follow-torrent=mem",
                "-s16", "-x16", "--min-split-size=1M", "--max-connection-per-server=16",
                "--bt-max-peers=128", f"--bt-tracker={LIVE_TRACKERS}", target
            ]
            proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
            start_time = time.time()
            
            while proc.returncode is None:
                try:
                    line = await asyncio.wait_for(proc.stdout.readline(), timeout=2.0)
                    if not line: break
                except asyncio.TimeoutError:
                    if (time.time() - start_time) > stuck_timeout:
                        proc.kill()
                        await proc.wait()
                        break
            await proc.wait()
            if proc.returncode == 0:
                return target
        return None

async def main():
    targets = glob.glob("torrents/*.torrent")
    if os.path.exists("direct_links.txt"):
        with open("direct_links.txt", "r") as f:
            targets.extend([l.strip() for l in f if l.strip()])
            
    if not targets:
        return

    os.makedirs("downloads", exist_ok=True)
    sem = asyncio.Semaphore(16)
    tasks = [download_target(t, sem) for t in targets]
    await asyncio.gather(*tasks)

asyncio.run(main())
EOF

echo "📦 Compressing files..."
python3 - << 'EOF'
import os, shutil, subprocess, re
from collections import defaultdict

folder = "downloads"
video_ext = ('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v')
media_ext = video_ext + ('.srt', '.ass', '.vtt', '.sub')
max_bytes = 10000 * 1024 * 1024

def get_dir_size(p):
    return sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fn in os.walk(p) for f in fn)

if os.path.exists(folder):
    for item in os.listdir(folder):
        item_path = os.path.join(folder, item)
        if os.path.isdir(item_path):
            folder_size = get_dir_size(item_path)
            orig = os.getcwd()
            os.chdir(folder)
            zip_name = f"{item}.zip"
            cmd = ["7z", "a", "-mx0", "-mmt=on", zip_name, item]
            if folder_size > max_bytes:
                cmd.insert(2, "-v5900m")
            subprocess.run(cmd, check=True)
            os.chdir(orig)
            shutil.rmtree(item_path)
EOF

echo "📤 Uploading files to Filemirage..."
python3 - << 'EOF'
import os, subprocess, requests
from concurrent.futures import ThreadPoolExecutor

TOKEN = os.getenv("FILEMIRAGE_API_TOKEN", "9QQH-DGES-CWQZ-FXNV")
FOLDER = "downloads"

try:
    srv = requests.get("https://filemirage.com/api/servers", timeout=10).json()['data']['server']
except Exception as e:
    print(f"Failed fetching upload server: {e}")
    exit(1)

def upload_file(path):
    fn = os.path.basename(path)
    print(f"⬆️ Uploading: {fn}")
    cmd = ["curl", "-X", "POST", f"{srv}/upload.php", "-H", f"Authorization: Bearer {TOKEN}", "-F", f"file=@{path}", "--max-time", "3600"]
    subprocess.run(cmd, check=True)

if os.path.exists(FOLDER):
    files = [os.path.join(r, f) for r, _, fs in os.walk(FOLDER) for f in fs if not f.endswith(('.aria2', '.part'))]
    if files:
        with ThreadPoolExecutor(max_workers=4) as ex:
            ex.map(upload_file, files)
EOF
