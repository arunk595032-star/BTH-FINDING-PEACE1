#!/usr/bin/env python3
"""
BTH asset fetcher.

Downloads freely licensed assets (Poly Haven CC0, ambientCG CC0) into
tools/_asset_stage/ so that tools/install_assets.py can place them into the
Godot project with normalised names.

Run:  python3 tools/fetch_assets.py [--models-only] [--dry-run]
"""
import json
import os
import subprocess
import sys
import zipfile

STAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_asset_stage")

# --- Poly Haven (CC0) -------------------------------------------------------
# Real-world scale glTF models, 1K textures.
PH_MODELS = [
    # vegetation
    "fir_tree_01", "pine_tree_01", "pine_sapling_medium", "pine_sapling_small",
    "grass_medium_01", "fern_02", "weed_plant_02", "nettle_plant",
    "wild_rooibos_bush", "dead_tree_trunk",
    # rocks / terrain
    "coastal_cliff_01", "coast_land_rocks_02", "coast_land_rocks_03",
    "stone_01", "namaqualand_stones_01",
    # props
    "wooden_barrels_01", "wooden_crate_01", "stone_fire_pit", "barrel_03",
    "gothic_statue",
]

# 1K JPG texture sets (diffuse / normal / arm).
PH_TEXTURES = [
    "grass_ground", "forest_ground_04", "cliff_side", "gravel_ground_01",
    "medieval_wood", "bark_brown_02", "mossy_rock",
]

PH_HDRI = [("belfast_sunset_puresky", "2k")]

# --- ambientCG (CC0) --------------------------------------------------------
ACG_MATERIALS = [
    "Rock064",            # cliff / castle stone
    "Planks040",          # aged timber
    "RoofingTiles013A",   # village roofs
    "Bricks105",          # castle masonry
    "Plaster001",         # village walls
    "Ground037",          # soil / mud
]


def curl(url, dest, retries=4):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return True
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    for attempt in range(retries):
        rc = subprocess.call([
            "curl", "-fsSL", "--retry", "2", "--connect-timeout", "20",
            "-A", "BTH-asset-fetcher/1.0 (Godot project build)",
            "-o", tmp, url,
        ])
        if rc == 0 and os.path.getsize(tmp) > 0:
            os.rename(tmp, dest)
            return True
        if os.path.exists(tmp):
            os.remove(tmp)
    print("FAILED", url, file=sys.stderr)
    return False


def api(url):
    out = subprocess.run(["curl", "-fsSL", "-A", "BTH-asset-fetcher/1.0", url],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"API failure {url}: {out.stderr[:200]}")
    return json.loads(out.stdout)


def fetch_models(dry=False):
    total = 0
    manifest = {}
    for mid in PH_MODELS:
        data = api(f"https://api.polyhaven.com/files/{mid}")
        entry = data["gltf"]["1k"]["gltf"]
        base = os.path.join(STAGE, "polyhaven", "models", mid)
        files = [(entry["url"], os.path.basename(entry["url"]))]
        for rel, info in entry.get("include", {}).items():
            files.append((info["url"], rel))
        size = sum(info.get("size", 0) for info in entry.get("include", {}).values())
        size += entry.get("size", 0)
        total += size
        print(f"[model] {mid:26s} {size/1e6:6.2f} MB")
        manifest[mid] = {"bytes": size, "files": [f[1] for f in files]}
        if dry:
            continue
        for url, rel in files:
            curl(url, os.path.join(base, rel))
    print(f"[models] total {total/1e6:.1f} MB")
    return manifest


def fetch_textures(dry=False):
    total = 0
    for tid in PH_TEXTURES:
        data = api(f"https://api.polyhaven.com/files/{tid}")
        for channel, suffix in (("Diffuse", "diff"), ("nor_gl", "nor"), ("arm", "arm")):
            info = data[channel]["1k"]["jpg"]
            total += info.get("size", 0)
            dest = os.path.join(STAGE, "polyhaven", "textures", tid, f"{tid}_{suffix}.jpg")
            print(f"[tex] {tid:20s} {suffix:5s} {info.get('size',0)/1e6:5.2f} MB")
            if not dry:
                curl(info["url"], dest)
    print(f"[textures] total {total/1e6:.1f} MB")


def fetch_hdri(dry=False):
    for hid, res in PH_HDRI:
        data = api(f"https://api.polyhaven.com/files/{hid}")
        info = data["hdri"][res]["hdr"]
        print(f"[hdri] {hid} {res} {info.get('size',0)/1e6:.1f} MB")
        if not dry:
            curl(info["url"], os.path.join(STAGE, "polyhaven", "hdri", f"{hid}_{res}.hdr"))


def fetch_ambientcg(dry=False):
    for mid in ACG_MATERIALS:
        url = f"https://ambientcg.com/get?file={mid}_1K-JPG.zip"
        dest = os.path.join(STAGE, "ambientcg", f"{mid}_1K-JPG.zip")
        print(f"[acg] {mid}")
        if dry:
            continue
        if not curl(url, dest):
            print(f"  (skipped {mid})", file=sys.stderr)
            continue
        out = os.path.join(STAGE, "ambientcg", mid)
        os.makedirs(out, exist_ok=True)
        with zipfile.ZipFile(dest) as zf:
            for member in zf.namelist():
                name = os.path.basename(member)
                if not name or name.startswith("."):
                    continue
                if name.lower().endswith((".jpg", ".png", ".mtlx", ".json")):
                    with zf.open(member) as src, open(os.path.join(out, name), "wb") as dst:
                        dst.write(src.read())
        print("  extracted", len(os.listdir(out)), "files")


if __name__ == "__main__":
    os.makedirs(STAGE, exist_ok=True)
    dry = "--dry-run" in sys.argv
    only = "--models-only" in sys.argv
    m = fetch_models(dry)
    if m and not dry:
        with open(os.path.join(STAGE, "polyhaven_models.json"), "w") as fh:
            json.dump(m, fh, indent=1)
    if not only:
        fetch_textures(dry)
        fetch_hdri(dry)
        fetch_ambientcg(dry)
    print("ASSET_FETCH_DONE")
