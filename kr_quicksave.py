from __future__ import annotations

import json
import math
import os
import re
import shutil
import tempfile
import zipfile
from datetime import datetime
from io import BytesIO
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk


APP_TITLE = "Kingdom Rush 中途存档 v9（实验版）"
CHECKPOINT_FORMAT = 9
APP_ID = "246420"
EXE_NAME = "Kingdom Rush.exe"
PATCH_MARKER = "_krq_original_main.lua"
MOD_ENTRY = "kr_quicksave.lua"
SAVE_DIR = Path(os.environ.get("APPDATA", Path.home())) / "kingdom_rush"
CHECKPOINT_PATH = SAVE_DIR / "kr_midlevel_checkpoint.json"
STATUS_PATH = SAVE_DIR / "kr_quicksave_status.txt"
MANIFEST_NAME = ".kr_quicksave_patch.json"


class PatchError(RuntimeError):
    pass


def read_love_zip(exe_data: bytes) -> tuple[int, zipfile.ZipFile]:
    try:
        archive = zipfile.ZipFile(BytesIO(exe_data), "r")
        first = next((item for item in archive.infolist() if not item.is_dir()), None)
        if first is None:
            archive.close()
            raise PatchError("游戏 exe 中没有可读取的 LÖVE 资源包。")
        return first.header_offset, archive
    except (zipfile.BadZipFile, StopIteration) as exc:
        raise PatchError("这不是可识别的 Kingdom Rush LÖVE 游戏文件。") from exc


def make_patched_exe(source: bytes, mod_source: bytes) -> bytes:
    prefix_size, archive = read_love_zip(source)
    try:
        names = set(archive.namelist())
        if "main.lua" not in names:
            raise PatchError("游戏资源包中找不到 main.lua，可能是游戏版本已更新。")
        if PATCH_MARKER in names:
            raise PatchError("所选原文件已经包含存档补丁。")

        output = BytesIO()
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as patched:
            patched.comment = archive.comment
            for item in archive.infolist():
                data = archive.read(item.filename)
                if item.filename == "main.lua":
                    patched.writestr(PATCH_MARKER, data)
                    patched.writestr(item, WRAPPER_MAIN_LUA.encode("utf-8"))
                elif item.filename == MOD_ENTRY:
                    raise PatchError(f"游戏文件已包含同名资源：{MOD_ENTRY}")
                else:
                    patched.writestr(item, data)
            patched.writestr(MOD_ENTRY, mod_source)
        return source[:prefix_size] + output.getvalue()
    finally:
        archive.close()


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def steam_roots() -> list[Path]:
    roots: list[Path] = []
    for raw in (
        os.environ.get("ProgramFiles(x86)"),
        os.environ.get("ProgramFiles"),
        os.environ.get("LOCALAPPDATA"),
    ):
        if not raw:
            continue
        base = Path(raw)
        candidates = [base / "Steam"]
        if base.name.lower() == "appdata":
            candidates.append(base / "Local" / "Steam")
        for candidate in candidates:
            if candidate.is_dir() and candidate not in roots:
                roots.append(candidate)
    return roots


def library_roots(steam_root: Path) -> list[Path]:
    libraries = [steam_root]
    config = steam_root / "steamapps" / "libraryfolders.vdf"
    try:
        contents = config.read_text(encoding="utf-8", errors="replace")
        for value in re.findall(r'"path"\s*"((?:\\.|[^"])*)"', contents):
            value = value.replace("\\\\", "\\").replace("\\\"", '"')
            library = Path(value)
            if library not in libraries:
                libraries.append(library)
    except OSError:
        pass
    return libraries


def detect_game_exe() -> Path | None:
    for root in steam_roots():
        for library in library_roots(root):
            manifest = library / "steamapps" / f"appmanifest_{APP_ID}.acf"
            try:
                contents = manifest.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            match = re.search(r'"installdir"\s*"([^"]+)"', contents)
            install_dir = match.group(1) if match else "Kingdom Rush"
            candidate = library / "steamapps" / "common" / install_dir / EXE_NAME
            if candidate.is_file():
                return candidate
    return None


def looks_patched(exe_path: Path) -> bool:
    try:
        _prefix, archive = read_love_zip(exe_path.read_bytes())
        try:
            return PATCH_MARKER in archive.namelist() and MOD_ENTRY in archive.namelist()
        finally:
            archive.close()
    except (OSError, PatchError):
        return False


def install_patch(exe_path: Path, mod_path: Path) -> Path:
    if not exe_path.is_file():
        raise PatchError("找不到 Kingdom Rush.exe。")
    if not mod_path.is_file():
        raise PatchError(f"找不到补丁文件：{mod_path}")
    if looks_patched(exe_path):
        raise PatchError("游戏已经安装了中途存档补丁。")

    original = exe_path.read_bytes()
    mod_source = mod_path.read_bytes()
    patched = make_patched_exe(original, mod_source)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup_path = exe_path.with_name(f"{exe_path.name}.krq-{stamp}.bak")
    manifest_path = exe_path.parent / MANIFEST_NAME
    if backup_path.exists():
        raise PatchError(f"备份文件已存在，已停止操作：{backup_path.name}")

    write_atomic(backup_path, original)
    try:
        write_atomic(exe_path, patched)
        manifest = {
            "format": 1,
            "exe": exe_path.name,
            "backup": backup_path.name,
            "installed_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        }
        write_atomic(manifest_path, json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8"))
    except Exception:
        write_atomic(exe_path, original)
        raise
    return backup_path


def uninstall_patch(exe_path: Path) -> Path:
    manifest_path = exe_path.parent / MANIFEST_NAME
    if not manifest_path.is_file():
        raise PatchError("没找到补丁备份记录。请在原来安装补丁的游戏目录中操作。")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        backup_path = exe_path.parent / manifest["backup"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise PatchError("补丁备份记录损坏，无法确定原版 exe。") from exc
    if not backup_path.is_file():
        raise PatchError(f"找不到原版备份：{backup_path.name}")
    if not looks_patched(exe_path):
        raise PatchError("当前 exe 未检测到补丁，未覆盖文件。")
    write_atomic(exe_path, backup_path.read_bytes())
    manifest_path.unlink(missing_ok=True)
    return backup_path


def backup_saves() -> Path:
    if not SAVE_DIR.is_dir():
        raise PatchError(f"还没有找到游戏存档目录：{SAVE_DIR}")
    files = [path for path in SAVE_DIR.iterdir() if path.is_file() and (path.name.startswith("slot") or path.name in {"global.lua", "settings.lua"})]
    if not files:
        raise PatchError(f"{SAVE_DIR} 中没有发现玩家存档文件。")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    destination = SAVE_DIR / "KRQuickSaveBackups" / stamp
    destination.mkdir(parents=True, exist_ok=False)
    for path in files:
        shutil.copy2(path, destination / path.name)
    return destination


def restore_saves(backup_dir: Path) -> None:
    if not backup_dir.is_dir():
        raise PatchError("请选择一个有效的存档备份目录。")
    files = [path for path in backup_dir.iterdir() if path.is_file() and (path.name.startswith("slot") or path.name in {"global.lua", "settings.lua"})]
    if not files:
        raise PatchError("所选目录里没有游戏存档文件。")
    SAVE_DIR.mkdir(parents=True, exist_ok=True)
    # Never restore over the user's current progress without preserving it first.
    current_files = [path for path in SAVE_DIR.iterdir() if path.is_file() and (path.name.startswith("slot") or path.name in {"global.lua", "settings.lua"})]
    if current_files:
        backup_saves()
    for path in files:
        shutil.copy2(path, SAVE_DIR / path.name)


WRAPPER_MAIN_LUA = r'''
-- KRQuickSave bootstrap. The original game entrypoint is kept intact.
local original, err = love.filesystem.load("_krq_original_main.lua")
if not original then error("KRQuickSave could not load the original game: " .. tostring(err)) end
original()

local mod_chunk, mod_err = love.filesystem.load("kr_quicksave.lua")
if not mod_chunk then error("KRQuickSave module is missing: " .. tostring(mod_err)) end
local krq = mod_chunk()

local function hook_update()
    if love._krq_update_hooked then return true end
    if love.update then
        local old_update = love.update
        love.update = function(dt)
            old_update(dt)
            krq.update(dt)
        end
        love._krq_update_hooked = true
        return true
    end
    return false
end

local function hook_draw()
    if love._krq_draw_hooked then return true end
    if love.draw then
        local old_draw = love.draw
        love.draw = function(...)
            old_draw(...)
            krq.draw()
        end
        love._krq_draw_hooked = true
        return true
    end
    return false
end

local function hook_callbacks()
    local update_ready = hook_update()
    local draw_ready = hook_draw()
    return update_ready and draw_ready
end

if not hook_callbacks() then
    local old_load = love.load
    love.load = function(...)
        if old_load then old_load(...) end
        if not hook_callbacks() then
            error("KRQuickSave could not hook the game's update and draw callbacks")
        end
    end
end
'''


class QuickSaveApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title(APP_TITLE)
        self.root.geometry("760x570")
        self.root.minsize(680, 520)
        self.game_path = tk.StringVar()
        self.status_text = tk.StringVar(value="正在查找 Steam 初代 Kingdom Rush…")
        self.checkpoint_text = tk.StringVar(value="尚无中途存档")
        self.last_status_size = -1
        self._build_ui()
        found = detect_game_exe()
        if found:
            self.game_path.set(str(found))
            self.status_text.set("已找到游戏。安装补丁前请先完全退出 Kingdom Rush。")
        else:
            self.status_text.set("未自动找到游戏，请在 Steam 中右键游戏 → 管理 → 浏览本地文件，然后选择 exe。")
        self._refresh_checkpoint()

    def _build_ui(self) -> None:
        outer = ttk.Frame(self.root, padding=18)
        outer.pack(fill="both", expand=True)
        ttk.Label(outer, text="Kingdom Rush 中途存档 v9（实验版）", font=("Microsoft YaHei UI", 18, "bold")).pack(anchor="w")
        ttk.Label(
            outer,
            text="初代 Steam 版｜F5 保存；重新进入同一关后双按 F9 恢复",
        ).pack(anchor="w", pady=(4, 16))

        game_box = ttk.LabelFrame(outer, text="游戏位置", padding=12)
        game_box.pack(fill="x")
        row = ttk.Frame(game_box)
        row.pack(fill="x")
        ttk.Entry(row, textvariable=self.game_path).pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="浏览…", command=self._browse_exe).pack(side="left", padx=(8, 0))
        ttk.Label(game_box, textvariable=self.status_text, wraplength=690).pack(anchor="w", pady=(8, 0))

        action_box = ttk.LabelFrame(outer, text="补丁", padding=12)
        action_box.pack(fill="x", pady=(14, 0))
        actions = ttk.Frame(action_box)
        actions.pack(fill="x")
        ttk.Button(actions, text="安装实验补丁", command=self._install).pack(side="left")
        ttk.Button(actions, text="恢复原版游戏文件", command=self._uninstall).pack(side="left", padx=8)
        ttk.Label(
            action_box,
            text="补丁会修改游戏 exe，并在同一目录保留原版备份。v9 会恢复游戏原生的下一波游标和波次提示；技能仍按原生按钮流程解锁，并保存剩余冷却。",
            wraplength=690,
        ).pack(anchor="w", pady=(8, 0))

        save_box = ttk.LabelFrame(outer, text="玩家进度备份", padding=12)
        save_box.pack(fill="x", pady=(14, 0))
        ttk.Label(save_box, text=f"普通关卡进度目录：{SAVE_DIR}", wraplength=690).pack(anchor="w")
        saves_actions = ttk.Frame(save_box)
        saves_actions.pack(anchor="w", pady=(8, 0))
        ttk.Button(saves_actions, text="备份普通存档", command=self._backup_saves).pack(side="left")
        ttk.Button(saves_actions, text="从备份恢复…", command=self._restore_saves).pack(side="left", padx=8)
        ttk.Button(saves_actions, text="打开存档目录", command=self._open_save_dir).pack(side="left")

        checkpoint_box = ttk.LabelFrame(outer, text="中途检查点", padding=12)
        checkpoint_box.pack(fill="x", pady=(14, 0))
        ttk.Label(checkpoint_box, textvariable=self.checkpoint_text, wraplength=690).pack(anchor="w")
        ttk.Button(checkpoint_box, text="打开检查点目录", command=self._open_save_dir).pack(anchor="w", pady=(8, 0))

        footer = ttk.Label(
            outer,
            text="使用流程：完全退出游戏并安装补丁 → 关卡内 F5 → 重进同一关、相同模式/难度且尚未出兵时，5 秒内双按 F9。",
            wraplength=710,
            justify="left",
        )
        footer.pack(anchor="w", pady=(16, 0))
        self.root.after(1200, self._poll_status)

    def _browse_exe(self) -> None:
        selected = filedialog.askopenfilename(
            title="选择初代 Kingdom Rush.exe",
            filetypes=[("游戏程序", "Kingdom Rush.exe"), ("可执行文件", "*.exe"), ("所有文件", "*.*")],
        )
        if selected:
            self.game_path.set(selected)
            self.status_text.set("已选择游戏文件。")

    def _selected_exe(self) -> Path:
        raw = self.game_path.get().strip().strip('"')
        if not raw:
            raise PatchError("请先选择 Kingdom Rush.exe。")
        return Path(raw).expanduser().resolve()

    def _install(self) -> None:
        try:
            exe = self._selected_exe()
            if not messagebox.askyesno(
                "安装中途存档补丁",
                "这是一项尚未实机验证的实验功能。将修改所选游戏 exe，并在同目录保存原版备份。请确认游戏已经完全退出。继续吗？",
            ):
                return
            backup = install_patch(exe, Path(__file__).with_name(MOD_ENTRY))
            self.status_text.set(f"补丁已安装。原版备份：{backup.name}")
            messagebox.showinfo("实验补丁已安装", "先在不重要的关卡试用。尽量在清完一波后按 F5；重进同一关、尚未出兵时，5 秒内双按 F9。敌人、英雄单位状态和飞行中的攻击不会恢复。")
        except (OSError, PatchError, zipfile.BadZipFile) as exc:
            messagebox.showerror("安装失败", str(exc))

    def _uninstall(self) -> None:
        try:
            exe = self._selected_exe()
            if not messagebox.askyesno("恢复原版", "将用备份覆盖当前游戏 exe。请确认游戏已经完全退出。继续吗？"):
                return
            backup = uninstall_patch(exe)
            self.status_text.set(f"已恢复原版。备份仍保留：{backup.name}")
            messagebox.showinfo("完成", "已恢复原版游戏文件。备份文件仍保留在游戏目录。")
        except (OSError, PatchError) as exc:
            messagebox.showerror("恢复失败", str(exc))

    def _backup_saves(self) -> None:
        try:
            if not messagebox.askyesno("备份普通存档", "将复制当前普通关卡进度到新的备份文件夹，不会修改原存档。继续吗？"):
                return
            destination = backup_saves()
            messagebox.showinfo("普通存档已备份", f"备份位置：\n{destination}")
        except (OSError, PatchError) as exc:
            messagebox.showerror("备份失败", str(exc))

    def _restore_saves(self) -> None:
        selected = filedialog.askdirectory(title="选择 KRQuickSaveBackups 下的某个备份文件夹")
        if not selected:
            return
        if not messagebox.askyesno(
            "恢复普通存档",
            "将用所选备份覆盖同名的普通存档文件。恢复前会自动备份当前存档。继续吗？",
        ):
            return
        try:
            restore_saves(Path(selected))
            messagebox.showinfo("恢复完成", "普通存档已恢复。请在游戏完全关闭时执行；当前存档副本已自动备份。")
        except (OSError, PatchError) as exc:
            messagebox.showerror("恢复失败", str(exc))

    def _open_save_dir(self) -> None:
        SAVE_DIR.mkdir(parents=True, exist_ok=True)
        try:
            os.startfile(SAVE_DIR)  # type: ignore[attr-defined]
        except OSError as exc:
            messagebox.showerror("无法打开目录", str(exc))

    def _refresh_checkpoint(self) -> None:
        try:
            raw = CHECKPOINT_PATH.read_text(encoding="utf-8")
            data = json.loads(raw)
            if data.get("format") not in (2, 3, 4, 5, 6, 7, 8, CHECKPOINT_FORMAT):
                self.checkpoint_text.set(f"这是旧版不兼容的检查点。请更新补丁后在关卡内重新按 F5 保存\n{CHECKPOINT_PATH}")
                return
            meta = data.get("metadata", {})
            saved_at = meta.get("saved_at", "未知时间")
            level = meta.get("level_name") or meta.get("level_idx", "未知关卡")
            wave = meta.get("wave", "未知波次")
            state = data.get("state", {})
            next_wave = meta.get("next_wave_group")
            wave_note = f"｜下一波 {next_wave}" if isinstance(next_wave, int) else ("｜波次已结束" if isinstance(state, dict) and state.get("waves_finished") else "")
            towers = state.get("towers", []) if isinstance(state, dict) else []
            saved_tower_count = len(towers) if isinstance(towers, list) else 0
            units = state.get("units", {}) if isinstance(state, dict) else {}
            if not isinstance(units, dict):
                units = {}
            enemy_count = len(units.get("enemies", [])) if isinstance(units.get("enemies", []), list) else 0
            hero_count = len(units.get("heroes", [])) if isinstance(units.get("heroes", []), list) else 0
            soldier_count = sum(
                len(barrack.get("soldiers", []))
                for barrack in units.get("barracks", [])
                if isinstance(barrack, dict) and isinstance(barrack.get("soldiers", []), list)
            ) if isinstance(units.get("barracks", []), list) else 0
            powers = state.get("powers", {}) if isinstance(state, dict) else {}
            if not isinstance(powers, dict):
                powers = {}
            power_labels = {"unlocked": "可用", "default": "可用", "cooldown": "冷却", "locked": "锁定"}

            def describe_power(key: str) -> str:
                record = powers.get(key)
                if not isinstance(record, dict):
                    return "未记录"
                mode = record.get("mode")
                if mode == "cooldown":
                    remaining = record.get("cooldown_remaining")
                    if isinstance(remaining, (int, float)):
                        return f"冷却约 {max(0, math.ceil(remaining))} 秒"
                    return "冷却（剩余时间未记录）"
                return power_labels.get(mode, "未知")

            power_note = "｜火雨 " + describe_power("power_1")
            power_note += "、增援 " + describe_power("power_2")
            detected_tower_count = meta.get("detected_towers", saved_tower_count)
            tower_note = f"｜记录塔 {saved_tower_count}/{detected_tower_count} 座"
            unit_note = f"｜怪物 {enemy_count} 个、英雄 {hero_count} 位、兵营士兵 {soldier_count} 名"
            if saved_tower_count != detected_tower_count:
                tower_note += "（数量不符，请重新保存）"
            if data.get("format", 0) < 5:
                tower_note += "（旧格式，单位状态需按 F5 重存）"
            elif data.get("format") < 6:
                tower_note += "（无技能快照）"
            if data.get("format", 0) < 8 and any(
                isinstance(powers.get(key), dict) and powers[key].get("mode") == "cooldown"
                for key in ("power_1", "power_2")
            ):
                power_note += "（旧格式无法恢复准确冷却剩余时间）"
            self.checkpoint_text.set(f"最近中途存档：{saved_at}｜关卡 {level}｜第 {wave} 波{wave_note}{tower_note}{unit_note}{power_note}\n{CHECKPOINT_PATH}")
        except (OSError, ValueError, AttributeError):
            self.checkpoint_text.set(f"尚无可识别的中途存档\n{CHECKPOINT_PATH}")

    def _poll_status(self) -> None:
        try:
            stat = STATUS_PATH.stat()
            if stat.st_size != self.last_status_size:
                content = STATUS_PATH.read_text(encoding="utf-8", errors="replace").strip().splitlines()
                if content:
                    self.status_text.set(content[-1])
                self.last_status_size = stat.st_size
                self._refresh_checkpoint()
        except OSError:
            pass
        self.root.after(1200, self._poll_status)


def main() -> None:
    root = tk.Tk()
    try:
        ttk.Style(root).theme_use("vista")
    except tk.TclError:
        pass
    QuickSaveApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
